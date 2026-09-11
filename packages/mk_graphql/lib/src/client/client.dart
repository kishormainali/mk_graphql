import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';

import '../link/logging/logger_link.dart';
import '../link/logging/logger_options.dart';

import '../cache/cache.dart';
import '../cache/in_memory_cache.dart';
import '../core/error.dart';
import '../core/fetch_policy.dart';
import '../core/request.dart';
import '../core/response.dart';
import '../link/auth/auth_link.dart';
import '../link/transport/dio_link.dart';
import '../link/transport/sse_link.dart';
import '../link/transform/typename_link.dart';
import '../link/transport/websocket_link.dart';

/// Central GraphQL Client managing cache, links, and operation requests.
///
/// Internally builds a composable [Link] pipeline:
///
///   [AuthLink]? → [TypenameLink]? → [LoggerLink] → (SubscriptionSplit: [WebSocketLink] / [SseLink] vs [DioLink])
class GraphQLClient {
  final Link _pipeline;
  final Cache cache;
  final FetchPolicy defaultFetchPolicy;
  final LoggerOptions loggerOptions;

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

  GraphQLClient({
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

    /// Callback that supplies the current auth headers (e.g. `Authorization`).
    AccessTokenCallback? tokenHeader,

    /// Returns whether the current token is expired. Triggers proactive refresh.
    IsTokenExpiredCallback? isTokenExpired,

    /// Performs token refresh. Receives the refresh [DioLink], returns new headers.
    OnRefreshCallback? onTokenRefresh,

    /// Called when the token is revoked.
    OnRevokeTokenCallback? onRevokeToken,

    /// Whether to inject `__typename` into every selection set. Defaults to `true`.
    bool addTypename = true,
    Cache? cache,
    this.defaultFetchPolicy = FetchPolicy.noCache,
    this.loggerOptions = const LoggerOptions(),
  })  : cache = cache ?? InMemoryCache(),
        _pipeline = _buildPipeline(
          url: url,
          wsUrl: wsUrl,
          sseUrl: sseUrl,
          subscriptionLink: subscriptionLink,
          dio: dio,
          defaultHeaders: defaultHeaders,
          loggerOptions: loggerOptions,
          tokenHeader: tokenHeader,
          isTokenExpired: isTokenExpired,
          onTokenRefresh: onTokenRefresh,
          onRevokeToken: onRevokeToken,
          addTypename: addTypename,
        );

  static Link _buildPipeline({
    required String url,
    String? wsUrl,
    String? sseUrl,
    Link? subscriptionLink,
    Dio? dio,
    Map<String, String>? defaultHeaders,
    LoggerOptions loggerOptions = const LoggerOptions(),
    AccessTokenCallback? tokenHeader,
    IsTokenExpiredCallback? isTokenExpired,
    OnRefreshCallback? onTokenRefresh,
    OnRevokeTokenCallback? onRevokeToken,
    bool addTypename = true,
  }) {
    final dioInstance = dio ?? Dio();
    if (defaultHeaders != null && defaultHeaders.isNotEmpty) {
      dioInstance.options.headers.addAll(defaultHeaders);
    }

    final links = <Link>[];

    // 1. AuthLink at the top of the chain (handles auth context & 401 refresh/retry)
    final hasAuth = tokenHeader != null || onTokenRefresh != null;
    if (hasAuth) {
      links.add(AuthLink(
        url: url,
        dio: dio,
        tokenHeader: tokenHeader,
        isTokenExpired: isTokenExpired,
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
                initialPayload: tokenHeader != null
                    ? () async => await tokenHeader() ?? const {}
                    : null,
              )
            : sseUrl != null
                ? SseLink(
                    sseUrl,
                    client: dioInstance,
                    defaultHeaders: defaultHeaders ?? const {},
                    tokenHeader: tokenHeader,
                    onTokenRefresh: onTokenRefresh,
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
      final response = await request(req, cancelToken: cancelToken).firstWhere(
        (r) => !r.loading || r.data != null || r.hasErrors,
        orElse: () => throw const AppServerException(
            message: 'No response received from GraphQL server.'),
      );
      if (response.hasErrors || response.data == null) {
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
    return request(req, cancelToken: cancelToken).map((response) {
      if (response.hasErrors || response.data == null) {
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

  /// Disposes client resources and all child links.
  Future<void> dispose() async {
    AuthLink.clearRevokeTokenListeners();
    cache.clear();
    await _pipeline.dispose();
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
          document: parseString(req.document),
          operationName: req.operationName,
        ),
        variables:
            req.variables != null ? req.toJsonVars(req.variables) : const {},
        context: context,
      );

      await for (final res in _pipeline.request(gqlReq)) {
        yield GraphQLResponse<TData>(
          data: res.data != null ? req.parseData(res.data!) : null,
          errors: res.errors
              ?.map((e) => GraphQLError(
                    message: e.message,
                    locations: e.locations
                        ?.map((l) => GraphQLErrorLocation(
                              line: l.line,
                              column: l.column,
                            ))
                        .toList(),
                    path: e.path?.cast<Object>(),
                    extensions: e.extensions,
                  ))
              .toList(),
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
