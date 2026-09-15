import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';

import '../auth/token_pair.dart';
import '../auth/token_storage.dart';
import '../cache/cache.dart';
import '../cache/in_memory_cache.dart';
import '../core/document_cache.dart' as doc_cache;
import '../core/error.dart';
import '../core/error_policy.dart';
import '../core/graphql_error_mapper.dart';
import '../core/fetch_policy.dart';
import '../core/request.dart';
import '../core/response.dart';
import '../link/auth/auth_link.dart';
import '../link/logging/logger_link.dart';
import '../link/logging/logger_options.dart';
import '../link/transform/typename_link.dart';
import '../link/transport/dio_link.dart';
import '../link/transport/sse_link.dart';
import '../link/transport/websocket_link.dart';

/// Central GraphQL Client managing cache, links, and operation requests.
///
/// Combines an in-memory normalized cache, an extensible [Link] pipeline,
/// proactive auth token management, automatic `__typename` injection,
/// rich logging, and typed request execution.
class GraphQLClient {
  final Link _pipeline;
  final Cache cache;
  final FetchPolicy defaultFetchPolicy;
  final ErrorPolicy defaultErrorPolicy;
  final LoggerOptions loggerOptions;

  /// The [Dio] instance this client created for itself (no `dio:` argument
  /// was supplied to the factory) — closed by [dispose]. Null when the
  /// caller supplied their own [Dio] (theirs to close) or this client was
  /// built via [GraphQLClient.fromLink] (no Dio involved at all).
  final Dio? _ownedDio;

  /// Returns the cached [DocumentNode] AST for [document], parsing it only on
  /// first access. Shared with the default [GraphQLRequest.documentNode].
  static DocumentNode getParsedDocument(String document) =>
      doc_cache.getParsedDocument(document);

  // ---------------------------------------------------------------------------
  // Static revoke-token listener delegates
  // ---------------------------------------------------------------------------

  static void registerRevokeTokenListener(void Function() listener) =>
      AuthLink.registerRevokeTokenListener(listener);

  static void removeRevokeTokenListener(void Function() listener) =>
      AuthLink.removeRevokeTokenListener(listener);

  static void clearRevokeTokenListeners() =>
      AuthLink.clearRevokeTokenListeners();

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  factory GraphQLClient({
    /// The GraphQL HTTP endpoint URL.
    required String url,

    /// Optional WebSocket endpoint URL for GraphQL subscriptions.
    String? wsUrl,

    /// Optional Server-Sent Events (SSE) endpoint URL for GraphQL subscriptions.
    String? sseUrl,

    /// Custom subscription [Link] override (takes precedence over wsUrl and sseUrl).
    Link? subscriptionLink,

    /// Optional pre-configured [Dio] instance. When omitted a default one is created.
    Dio? dio,

    /// Default headers merged into every HTTP request at the transport level.
    Map<String, String>? defaultHeaders,

    /// Callback that supplies the current auth headers built from the access
    /// token (e.g. `Authorization`). Not needed alongside [refreshCallback] —
    /// the client reads the access token from [TokenStorage.i] itself. Only
    /// for static/custom headers that don't come from [TokenStorage.i]
    /// (rare); takes precedence over it when also provided.
    AccessTokenCallback? accessTokenHeader,

    /// Callback that supplies headers built from the refresh token (e.g.
    /// `Authorization`) — when provided, attached to the internal
    /// token-refresh HTTP request instead of [accessTokenHeader].
    AccessTokenCallback? refreshTokenHeader,

    /// Returns whether the current token is expired. Triggers proactive refresh.
    IsTokenExpiredCallback? isTokenExpired,

    /// Overrides how an unauthorized response is recognized. Lets a custom
    /// API tell the client exactly which requests actually need a token
    /// refresh (a non-standard error code, message, or status field) instead
    /// of relying on the built-in default (`extensions.code` of
    /// `UNAUTHORIZED`/`UNAUTHENTICATED`/`FORBIDDEN`, or an `extensions.status`/
    /// HTTP status of 401/403).
    IsUnauthorizedCallback? isUnauthorized,

    /// Called when the token is revoked, in addition to clearing [TokenStorage.i]
    /// (when configured via [refreshCallback]).
    OnRevokeTokenCallback? onRevokeToken,

    /// The single source of truth for token refresh: performs the refresh
    /// using the currently stored refresh token and returns the new
    /// [TokenPair] to persist (or `null`/throws to revoke). The client
    /// manages [TokenStorage.i] and the `Authorization` header on its own —
    /// no app-side storage or header plumbing needed. Skipped (no refresh
    /// attempted, straight to revoke) when there's no stored refresh token
    /// yet.
    RefreshCallback? refreshCallback,

    /// Whether to inject `__typename` into every selection set. Defaults to `true`.
    bool addTypename = true,
    Cache? cache,
    FetchPolicy defaultFetchPolicy = FetchPolicy.noCache,
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,
    LoggerOptions loggerOptions = const LoggerOptions(),
  }) {
    // Resolved once, here, and threaded through as a single non-null Dio —
    // AuthLink's own refresh requests must share this exact instance (same
    // defaultHeaders, same interceptors) rather than each independently
    // falling back to a second, unconfigured `Dio()`.
    final dioInstance = dio ?? Dio();
    if (defaultHeaders != null && defaultHeaders.isNotEmpty) {
      dioInstance.options.headers.addAll(defaultHeaders);
    }

    final resolvedCallbacks = _resolveAuthCallbacks(
      accessTokenHeader: accessTokenHeader,
      onRevokeToken: onRevokeToken,
      refreshCallback: refreshCallback,
    );

    return GraphQLClient._(
      cache: cache ?? InMemoryCache(),
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      loggerOptions: loggerOptions,
      ownedDio: dio == null ? dioInstance : null,
      pipeline: _buildPipeline(
        url: url,
        wsUrl: wsUrl,
        sseUrl: sseUrl,
        subscriptionLink: subscriptionLink,
        dio: dioInstance,
        defaultHeaders: defaultHeaders,
        loggerOptions: loggerOptions,
        accessTokenHeader: resolvedCallbacks.accessTokenHeader,
        refreshTokenHeader: refreshTokenHeader,
        isTokenExpired: isTokenExpired,
        isUnauthorized: isUnauthorized,
        onTokenRefresh: resolvedCallbacks.onTokenRefresh,
        onRevokeToken: resolvedCallbacks.onRevokeToken,
        addTypename: addTypename,
      ),
    );
  }

  GraphQLClient._({
    required this.cache,
    required this.defaultFetchPolicy,
    required this.defaultErrorPolicy,
    required this.loggerOptions,
    required Dio? ownedDio,
    required Link pipeline,
  })  : _ownedDio = ownedDio,
        _pipeline = pipeline;

  /// Creates a [GraphQLClient] using a custom [Link] pipeline directly.
  GraphQLClient.fromLink(
    Link link, {
    Cache? cache,
    this.defaultFetchPolicy = FetchPolicy.noCache,
    this.defaultErrorPolicy = ErrorPolicy.none,
    this.loggerOptions = const LoggerOptions(),
  })  : cache = cache ?? InMemoryCache(),
        _ownedDio = null,
        _pipeline = link;

  /// Derives [accessTokenHeader]/`onTokenRefresh`/[onRevokeToken] from
  /// [refreshCallback] so [GraphQLClient] can manage its own auth session via
  /// [TokenStorage.i] — [refreshCallback] is the sole source of truth for
  /// refresh; an explicit [accessTokenHeader] only overrides the header
  /// supplier.
  ///
  /// The resulting `onTokenRefresh` is what [AuthLink] dedupes concurrent
  /// 401s against (a shared in-flight [Future] — see `AuthLink._refreshToken`),
  /// so however many requests fail at once, [refreshCallback] runs at most
  /// once per refresh cycle and every one of them retries once it resolves.
  static ({
    AccessTokenCallback? accessTokenHeader,
    OnRefreshCallback? onTokenRefresh,
    OnRevokeTokenCallback? onRevokeToken,
  }) _resolveAuthCallbacks({
    required AccessTokenCallback? accessTokenHeader,
    required OnRevokeTokenCallback? onRevokeToken,
    required RefreshCallback? refreshCallback,
  }) {
    if (refreshCallback == null) {
      return (
        accessTokenHeader: accessTokenHeader,
        onTokenRefresh: null,
        onRevokeToken: onRevokeToken,
      );
    }

    return (
      accessTokenHeader: accessTokenHeader ??
          () async {
            final token = await TokenStorage.i.accessToken;
            return token != null ? {'Authorization': 'Bearer $token'} : null;
          },
      onTokenRefresh: (refreshClient) async {
        final currentRefreshToken = await TokenStorage.i.refreshToken;
        // No refresh token to call the API with — revoke straight away
        // instead of calling refreshCallback with one.
        if (currentRefreshToken == null) return null;
        final newToken =
            await refreshCallback(refreshClient, currentRefreshToken);
        if (newToken == null) return null;
        await TokenStorage.i.saveToken(newToken);
        return {'Authorization': 'Bearer ${newToken.accessToken}'};
      },
      onRevokeToken: () {
        onRevokeToken?.call();
        TokenStorage.i.deleteToken();
      },
    );
  }

  static Link _buildPipeline({
    required String url,
    String? wsUrl,
    String? sseUrl,
    Link? subscriptionLink,
    required Dio dio,
    Map<String, String>? defaultHeaders,
    LoggerOptions loggerOptions = const LoggerOptions(),
    AccessTokenCallback? accessTokenHeader,
    AccessTokenCallback? refreshTokenHeader,
    IsTokenExpiredCallback? isTokenExpired,
    IsUnauthorizedCallback? isUnauthorized,
    OnRefreshCallback? onTokenRefresh,
    OnRevokeTokenCallback? onRevokeToken,
    bool addTypename = true,
  }) {
    final dioInstance = dio;
    final links = <Link>[];

    // 1. AuthLink at the top of the chain (handles auth context & 401 refresh/retry)
    final hasAuth = accessTokenHeader != null || onTokenRefresh != null;
    if (hasAuth) {
      links.add(AuthLink(
        url: url,
        dio: dioInstance,
        accessTokenHeader: accessTokenHeader,
        refreshTokenHeader: refreshTokenHeader,
        isTokenExpired: isTokenExpired,
        isUnauthorized: isUnauthorized,
        onTokenRefresh: onTokenRefresh,
        onRevokeToken: onRevokeToken,
      ));
    }

    // 2. TypenameLink (injects __typename into query/mutation/subscription AST)
    if (addTypename) {
      links.add(const TypenameLink());
    }

    // 3. LoggerLink placed AFTER AuthLink and TypenameLink:
    //    - logs exact document with __typename
    //    - logs headers with Authorization
    //    - logs 401 responses and subsequent token refresh retries
    links.add(LoggerLink(options: loggerOptions));

    // 4. Terminating links
    final dioLink = DioLink(url, client: dioInstance);

    final subLink = subscriptionLink ??
        (wsUrl != null
            ? WebSocketLink(
                wsUrl,
                initialPayload: accessTokenHeader != null
                    ? () async => await accessTokenHeader() ?? const {}
                    : null,
              )
            : sseUrl != null
                ? SseLink(
                    sseUrl,
                    client: dioInstance,
                    defaultHeaders: defaultHeaders ?? const {},
                    tokenHeader: accessTokenHeader,
                  )
                : null);

    if (subLink != null) {
      links.add(Link.split(_isSubscription, subLink, dioLink));
    } else {
      links.add(dioLink);
    }

    return Link.from(links);
  }

  static bool _isSubscription(gql.Request req) {
    final defs =
        req.operation.document.definitions.whereType<OperationDefinitionNode>();
    if (req.operation.operationName != null) {
      final match =
          defs.where((d) => d.name?.value == req.operation.operationName);
      if (match.isNotEmpty) {
        return match.first.type == OperationType.subscription;
      }
    }
    return defs.any((d) => d.type == OperationType.subscription);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Executes a request and resolves to [TData], throwing on any error.
  ///
  /// Supports cancellation via [cancelToken] or [req.cancelToken].
  Future<TData> future<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) async {
    try {
      final effectiveErrorPolicy = req.errorPolicy ?? defaultErrorPolicy;
      final response = await request(req, cancelToken: cancelToken).firstWhere(
        (r) => !r.loading || r.data != null || r.hasErrors,
        orElse: () => throw const AppServerException(
            message: 'No response received from GraphQL server.'),
      );
      if (response.data == null ||
          (response.hasErrors && effectiveErrorPolicy == ErrorPolicy.none)) {
        _throwFromResponse(response);
      }
      return response.data!;
    } on GraphQLException {
      rethrow;
    } catch (e, st) {
      throw GraphQLExceptionExtension.fromException(e, st);
    }
  }

  /// Executes a request and returns a [Stream] of [TData], throwing on errors.
  ///
  /// Supports cancellation via [cancelToken] or [req.cancelToken].
  Stream<TData> stream<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) {
    final effectiveErrorPolicy = req.errorPolicy ?? defaultErrorPolicy;
    return request(req, cancelToken: cancelToken).map((response) {
      if (response.data == null ||
          (response.hasErrors && effectiveErrorPolicy == ErrorPolicy.none)) {
        _throwFromResponse(response);
      }
      return response.data!;
    }).handleError((Object e, StackTrace st) {
      if (e is GraphQLException) throw e;
      throw GraphQLExceptionExtension.fromException(e, st);
    });
  }

  /// Refetches [req] bypassing cache with [FetchPolicy.networkOnly],
  /// writes the fresh data to cache, and returns the resolved [TData].
  Future<TData> refetch<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) {
    final refetchReq = req.copyWithFetchPolicy(FetchPolicy.networkOnly);
    return future(refetchReq, cancelToken: cancelToken);
  }

  /// Refetches [req] bypassing cache with [FetchPolicy.networkOnly] and streams the result.
  Stream<TData> refetchStream<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) {
    final refetchReq = req.copyWithFetchPolicy(FetchPolicy.networkOnly);
    return stream(refetchReq, cancelToken: cancelToken);
  }

  /// Fetches the next page of results for a query, automatically merging the results
  /// with [previousData] (or the cached data for [originalRequest] if [previousData] is omitted),
  /// updating the cache under [originalRequest], and returning the merged data.
  ///
  /// By default, lists in the response are automatically concatenated without manual intervention.
  /// A custom [updateQuery] function may be provided to customize merging logic.
  Future<TData> fetchMore<TData, TVars>({
    required GraphQLRequest<TData, TVars> originalRequest,
    required GraphQLRequest<TData, TVars> nextRequest,
    TData? previousData,
    TData Function(TData previousData, TData incomingData)? updateQuery,
    CancelToken? cancelToken,
  }) async {
    final prev = previousData ?? cache.readQuery(originalRequest);
    final incoming = await future(
      nextRequest.copyWithFetchPolicy(FetchPolicy.networkOnly),
      cancelToken: cancelToken,
    );

    if (prev == null) {
      cache.writeQuery(originalRequest, incoming);
      return incoming;
    }

    final merged = updateQuery != null
        ? updateQuery(prev, incoming)
        : autoMergeGraphQLData(originalRequest, prev, incoming);

    cache.writeQuery(originalRequest, merged);
    return merged;
  }

  /// Low-level: returns a [Stream] of raw [GraphQLResponse] for this request.
  ///
  /// Supports cancellation via [cancelToken] or [req.cancelToken].
  Stream<GraphQLResponse<TData>> request<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) async* {
    final policy = req.fetchPolicy ?? defaultFetchPolicy;

    if (req.optimisticResponse != null) {
      cache.recordOptimistic(req, req.optimisticResponse as TData);
      yield GraphQLResponse<TData>(
        data: req.optimisticResponse,
        source: ResponseSource.optimistic,
        loading: true,
      );
    }

    switch (policy) {
      case FetchPolicy.cacheOnly:
        yield GraphQLResponse<TData>(
          data: cache.readQuery(req),
          source: ResponseSource.cache,
        );
        break;

      case FetchPolicy.cacheFirst:
        final cached = cache.readQuery(req);
        if (cached != null) {
          yield GraphQLResponse<TData>(
              data: cached, source: ResponseSource.cache);
        } else {
          yield* _fetchFromNetwork(req, cancelToken: cancelToken);
        }
        break;

      case FetchPolicy.cacheAndNetwork:
        final cached = cache.readQuery(req);
        if (cached != null) {
          yield GraphQLResponse<TData>(
              data: cached, source: ResponseSource.cache, loading: true);
        }
        yield* _fetchFromNetwork(req, cancelToken: cancelToken);
        break;

      case FetchPolicy.networkOnly:
        yield* _fetchFromNetwork(req, cancelToken: cancelToken);
        break;

      case FetchPolicy.noCache:
        yield* _executeNetworkRequest(req, cancelToken: cancelToken);
        break;
    }

    if (req.optimisticResponse != null) {
      cache.removeOptimistic(req.requestId);
    }
  }

  /// Watches query cache reactively.
  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> req) =>
      cache.watchQuery(req);

  /// Whether a persisted access token exists in [TokenStorage.i].
  Future<bool> get isAuthenticated async =>
      await TokenStorage.i.accessToken != null;

  /// Disposes client resources and all child links.
  ///
  /// Closes the [Dio] client only when this [GraphQLClient] created it
  /// itself (no `dio:` argument was passed to the factory) — a caller-
  /// supplied [Dio] is theirs to close, since they may still hold a
  /// reference to it elsewhere.
  Future<void> dispose() async {
    AuthLink.clearRevokeTokenListeners();
    cache.clear();
    await _pipeline.dispose();
    _ownedDio?.close();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Never _throwFromResponse<TData>(GraphQLResponse<TData> response) {
    if (response.errors != null && response.errors!.isNotEmpty) {
      throw GraphQLExceptionExtension.fromGraphQLErrors(response.errors!);
    }
    if (response.linkException != null) throw response.linkException!;
    throw const AppServerException(
        message: 'Something went wrong, please try again later.');
  }

  Stream<GraphQLResponse<TData>> _fetchFromNetwork<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) async* {
    await for (final response
        in _executeNetworkRequest(req, cancelToken: cancelToken)) {
      if (response.data != null && !response.hasErrors) {
        cache.writeQuery(req, response.data as TData);
      }
      yield response;
    }
  }

  /// Translates [GraphQLRequest] → [gql.Request], runs through [_pipeline],
  /// and maps [gql.Response] → [GraphQLResponse].
  Stream<GraphQLResponse<TData>> _executeNetworkRequest<TData, TVars>(
    GraphQLRequest<TData, TVars> req, {
    CancelToken? cancelToken,
  }) async* {
    try {
      final effectiveCancelToken = cancelToken ?? req.cancelToken;
      var context = gql.Context().withEntry(
        gql.HttpLinkHeaders(headers: req.headers ?? {}),
      );
      if (effectiveCancelToken != null) {
        context = context.withEntry(
          DioLinkCancelTokenContextEntry(effectiveCancelToken),
        );
      }

      final gqlReq = gql.Request(
        operation: gql.Operation(
          document: req.documentNode,
          operationName: req.operationName,
        ),
        variables:
            req.variables != null ? req.toJsonVars(req.variables) : const {},
        context: context,
      );

      await for (final res in _pipeline.request(gqlReq)) {
        yield GraphQLResponse<TData>(
          data: res.data != null ? req.parseData(res.data!) : null,
          errors: mapGraphQLErrors(res.errors),
          source: ResponseSource.network,
        );
      }
    } catch (e) {
      yield GraphQLResponse<TData>(
        linkException: GraphQLExceptionExtension.fromLinkException(e),
        source: ResponseSource.network,
      );
    }
  }
}

/// Helper to convert a typed data object (e.g. Freezed / JsonSerializable / Map) into a JSON map.
Map<String, dynamic>? dataToMap(dynamic data) {
  if (data == null) return null;
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  try {
    final dynamic res = (data as dynamic).toJson();
    if (res is Map<String, dynamic>) return res;
    if (res is Map) return Map<String, dynamic>.from(res);
  } catch (_) {}
  return null;
}

/// Recursively merges two JSON maps, automatically concatenating any matching List fields
/// and merging nested Maps, while updating new page metadata (e.g. pageInfo, cursors).
Map<String, dynamic> deepMergeJson(
  Map<String, dynamic> prev,
  Map<String, dynamic> incoming,
) {
  final result = Map<String, dynamic>.from(prev);
  for (final entry in incoming.entries) {
    final key = entry.key;
    final nextVal = entry.value;
    final prevVal = result[key];

    if (prevVal == null) {
      result[key] = nextVal;
    } else if (prevVal is List && nextVal is List) {
      result[key] = [...prevVal, ...nextVal];
    } else if (prevVal is Map && nextVal is Map) {
      result[key] = deepMergeJson(
        Map<String, dynamic>.from(prevVal),
        Map<String, dynamic>.from(nextVal),
      );
    } else {
      result[key] = nextVal;
    }
  }
  return result;
}

/// Automatically merges [previous] and [incoming] GraphQL query data objects by converting them
/// to JSON, deeply concatenating list fields, and parsing back using [request.parseData].
///
/// If merging or parsing fails, [incoming] is returned as fallback.
TData autoMergeGraphQLData<TData>(
  GraphQLRequest<TData, dynamic> request,
  TData previous,
  TData incoming,
) {
  final prevMap = dataToMap(previous);
  final nextMap = dataToMap(incoming);
  if (prevMap == null || nextMap == null) {
    return incoming;
  }
  try {
    final mergedMap = deepMergeJson(prevMap, nextMap);
    return request.parseData(mergedMap);
  } catch (_) {
    return incoming;
  }
}
