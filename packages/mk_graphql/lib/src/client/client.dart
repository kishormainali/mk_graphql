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
import '../core/request_key.dart';
import '../core/retry_options.dart';
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
///
/// ## Authentication
///
/// Pass `refreshCallback` and the client owns the session: it reads the
/// access token from [TokenStorage.i] for every request's `Authorization`
/// header, and on an unauthorized response calls `refreshCallback` once (no
/// matter how many requests failed at the same time), silently persists the
/// returned [TokenPair] with [TokenStorage.updateToken] — so
/// [TokenStorage.setTokenListener] listeners are *not* notified — and retries
/// the failed requests. If the refresh fails (or no refresh token is stored)
/// the session is revoked: [TokenStorage.deleteToken] runs (notifying
/// listeners with `null`), `onRevokeToken` is called, and every listener
/// added with [registerRevokeTokenListener] fires. Log in with
/// [TokenStorage.saveToken]; see also [isAuthenticated].
class GraphQLClient {
  final Link _pipeline;

  /// The normalized cache backing [FetchPolicy]s and [watchQuery].
  final Cache cache;

  /// [FetchPolicy] used by a request that doesn't set its own.
  final FetchPolicy defaultFetchPolicy;

  /// [ErrorPolicy] used by a request that doesn't set its own.
  final ErrorPolicy defaultErrorPolicy;

  /// What the [LoggerLink] prints.
  final LoggerOptions loggerOptions;

  /// How long a cached entry counts as fresh before a `cacheFirst` hit
  /// background-revalidates it; a request's own `staleTime` overrides it.
  final Duration defaultStaleTime;

  /// How long an entry with no active [watchQuery] subscriber is kept before
  /// being evicted; `null` (the default) never evicts. A request's own
  /// `cacheTime` overrides it.
  final Duration? defaultCacheTime;

  /// [RetryOptions] applied to queries/subscriptions without their own
  /// `retry`; `null` disables auto-retry. Mutations never auto-retry.
  final RetryOptions? defaultRetry;

  /// Caps how many of [_refetchActiveQueries]/[invalidateQueries]'s
  /// background `networkOnly` refetches run concurrently. `null` (the
  /// default) runs them all at once, preserving prior behavior. Set this if
  /// your app can have many simultaneously active [watchQuery] subscribers,
  /// so [notifyReconnected]/[notifyAppResumed]/[invalidateQueries] don't
  /// fire an unbounded burst of concurrent requests at the server.
  final int? maxConcurrentBackgroundRefetches;

  /// In-flight *query* network calls keyed by [computeRequestKey] —
  /// concurrent identical calls share one entry instead of each starting a
  /// separate pipeline request. Mutations, subscriptions, and any request
  /// with an explicit [CancelToken] are never entered here (see
  /// [_requestThroughPipeline]).
  ///
  /// The shared value is a [Future] of the *buffered* response list, not a
  /// live broadcast stream: a broadcast stream drops events emitted before a
  /// given listener attaches, so a second caller that reached dedup after the
  /// pipeline already emitted (routine — `cacheFirst`/`cacheAndNetwork`
  /// callers await a cache read first, so identical calls arrive at different
  /// microtask depths) would receive nothing at all. A [Future] replays its
  /// resolved value — or its error — to every listener regardless of attach
  /// timing. Buffering the whole sequence is safe here because subscriptions,
  /// the only genuinely multi-emission operation kind, are excluded from
  /// dedup entirely.
  final Map<String, Future<List<gql.Response>>> _inFlight = {};

  /// Tracks queries with at least one active [watchQuery] subscriber —
  /// shared by staleness-on-attach, `cacheTime` GC, `refetchInterval`
  /// polling, [invalidateQueries], and [notifyReconnected]/
  /// [notifyAppResumed].
  final Map<String, _ActiveQuery> _activeQueries = {};

  /// Set by [notifyAppPaused], cleared by [notifyAppResumed]. While `true`,
  /// every opportunistic background refetch (staleness-on-attach,
  /// `refetchInterval` polling, [invalidateQueries], [notifyReconnected])
  /// is skipped — see [_backgroundRefetch]. `refetchInterval`'s `Timer`s
  /// keep ticking (cheap; no network involved) so their schedule survives a
  /// pause unmodified, but the network call — and the battery/radio cost of
  /// making one — is what actually gets skipped for a screen nobody's
  /// looking at.
  bool _pollingPaused = false;

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

  /// Registers an app-wide [listener] called whenever a session is revoked —
  /// a refresh failed, no refresh token was stored, or the server answered
  /// with a failure classified as `AuthFailure.revoke` (e.g. HTTP 403). Use it
  /// to navigate to login. Shared by every [GraphQLClient]; not called on a
  /// successful (silent) refresh.
  static void registerRevokeTokenListener(void Function() listener) =>
      AuthLink.registerRevokeTokenListener(listener);

  /// Removes a [listener] added with [registerRevokeTokenListener].
  static void removeRevokeTokenListener(void Function() listener) =>
      AuthLink.removeRevokeTokenListener(listener);

  /// Removes every listener added with [registerRevokeTokenListener].
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

    /// Default headers sent on every HTTP request this client makes — queries,
    /// mutations, uploads, SSE subscriptions and the token-refresh request.
    /// Not applied to WebSocket connections.
    ///
    /// They override the transport's built-in `Accept`/`Content-Type` (except
    /// on multipart uploads, where the boundary `Content-Type` always wins),
    /// and are themselves overridden by a request's own `headers` and by the
    /// stored access token's `Authorization`, so a default `Authorization` is
    /// only a fallback while logged out. A caller-supplied [dio] is never
    /// modified.
    Map<String, String>? defaultHeaders,

    /// Callback that builds the current auth headers (e.g. `Authorization`)
    /// from the access token stored in [TokenStorage.i] — only invoked when
    /// one is actually stored, so [TokenHeaderCallback]'s `token` argument is
    /// never null in practice. Defaults to `Authorization: Bearer <token>`;
    /// pass this only if your API expects a different header format (rare).
    TokenHeaderCallback? accessTokenHeader,

    /// Callback that builds headers from the refresh token stored in
    /// [TokenStorage.i] — when provided, attached to every request sent
    /// through the internal refresh client instead of [accessTokenHeader].
    /// Only invoked when a refresh token is actually stored. No default: the
    /// refresh token normally reaches your refresh endpoint as the
    /// [refreshCallback] parameter (for a body/variable) — pass this only if
    /// your refresh endpoint additionally/instead expects it as a header.
    TokenHeaderCallback? refreshTokenHeader,

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

    /// Bounds how long a single [refreshCallback] call may take before it's
    /// treated as a failed refresh (revokes the session, same as it
    /// throwing). `null` (the default) waits indefinitely. Set this when
    /// your refresh endpoint can hang, so a stuck refresh doesn't block
    /// every request queued behind it forever.
    Duration? refreshTimeout,

    /// Whether to inject `__typename` into every selection set. Defaults to `true`.
    bool addTypename = true,

    /// Cache for the queries
    Cache? cache,

    /// Fetch policy for the client
    FetchPolicy defaultFetchPolicy = FetchPolicy.noCache,

    /// Error policy for the client
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,

    /// How long cached data is considered fresh before FetchPolicy.cacheFirst
    /// triggers a background revalidation, and before an active watchQuery
    /// subscription revalidates on attach. Defaults to Duration.zero (always
    /// stale — every cacheFirst hit background-refetches, matching TanStack
    /// Query's default). Override per-request via GraphQLRequest.staleTime.
    Duration defaultStaleTime = Duration.zero,

    /// How long a query's cache entry survives after its last active
    /// watchQuery subscriber cancels before being garbage-collected. Null
    /// (the default) disables GC entirely — matches today's behavior.
    /// Override per-request via GraphQLRequest.cacheTime.
    Duration? defaultCacheTime,

    /// Automatic retry-with-backoff for queries only, on transient network
    /// failures. Null (the default) disables auto-retry. Neither mutations
    /// nor subscriptions use this — they retry only if the request sets its
    /// own GraphQLRequest.retry (subscriptions already reconnect via their
    /// own transport link).
    RetryOptions? defaultRetry,

    /// Caps concurrent background `networkOnly` refetches from
    /// [GraphQLClient.notifyReconnected]/[GraphQLClient.notifyAppResumed]/
    /// [GraphQLClient.invalidateQueries]. `null` (the default) runs them
    /// all at once.
    int? maxConcurrentBackgroundRefetches,

    /// Logger Options
    LoggerOptions loggerOptions = const LoggerOptions(),
  }) {
    // Resolved once, here, and threaded through as a single non-null Dio —
    // AuthLink's own refresh requests must share this exact instance (same
    // interceptors, adapter) rather than each independently falling back to a
    // second, unconfigured `Dio()`.
    //
    // defaultHeaders are deliberately NOT written into this Dio's
    // `options.headers`: a caller-supplied Dio would be permanently modified
    // (overwriting its own same-named headers and leaking ours into the
    // caller's other requests), and base options lose to the transport's
    // built-in Accept/Content-Type so they couldn't override those. They are
    // passed to each link that sends requests instead.
    final dioInstance = dio ?? Dio();

    final resolvedCallbacks = _resolveAuthCallbacks(
      accessTokenHeader: accessTokenHeader,
      refreshTokenHeader: refreshTokenHeader,
      onRevokeToken: onRevokeToken,
      refreshCallback: refreshCallback,
    );

    return GraphQLClient._(
      cache: cache ?? InMemoryCache(),
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      defaultStaleTime: defaultStaleTime,
      defaultCacheTime: defaultCacheTime,
      defaultRetry: defaultRetry,
      maxConcurrentBackgroundRefetches: maxConcurrentBackgroundRefetches,
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
        refreshTokenHeader: resolvedCallbacks.refreshTokenHeader,
        isTokenExpired: isTokenExpired,
        isUnauthorized: isUnauthorized,
        onTokenRefresh: resolvedCallbacks.onTokenRefresh,
        onRevokeToken: resolvedCallbacks.onRevokeToken,
        refreshTimeout: refreshTimeout,
        addTypename: addTypename,
      ),
    );
  }

  /// Async counterpart to the default [GraphQLClient] factory — awaits
  /// [cache] (so `cache: HiveCache.open(boxName: '...')` can be passed
  /// directly, without a separate `await` statement) before building the
  /// client. Every other parameter is identical to the sync factory.
  static Future<GraphQLClient> create({
    required String url,
    String? wsUrl,
    String? sseUrl,
    Link? subscriptionLink,
    Dio? dio,
    Map<String, String>? defaultHeaders,
    TokenHeaderCallback? accessTokenHeader,
    TokenHeaderCallback? refreshTokenHeader,
    IsTokenExpiredCallback? isTokenExpired,
    IsUnauthorizedCallback? isUnauthorized,
    OnRevokeTokenCallback? onRevokeToken,
    RefreshCallback? refreshCallback,
    Duration? refreshTimeout,
    bool addTypename = true,
    FutureOr<Cache>? cache,
    FetchPolicy defaultFetchPolicy = FetchPolicy.noCache,
    ErrorPolicy defaultErrorPolicy = ErrorPolicy.none,
    Duration defaultStaleTime = Duration.zero,
    Duration? defaultCacheTime,
    RetryOptions? defaultRetry,
    int? maxConcurrentBackgroundRefetches,
    LoggerOptions loggerOptions = const LoggerOptions(),
  }) async {
    final resolvedCache = await (cache ?? InMemoryCache());
    return GraphQLClient(
      url: url,
      wsUrl: wsUrl,
      sseUrl: sseUrl,
      subscriptionLink: subscriptionLink,
      dio: dio,
      defaultHeaders: defaultHeaders,
      accessTokenHeader: accessTokenHeader,
      refreshTokenHeader: refreshTokenHeader,
      isTokenExpired: isTokenExpired,
      isUnauthorized: isUnauthorized,
      onRevokeToken: onRevokeToken,
      refreshCallback: refreshCallback,
      refreshTimeout: refreshTimeout,
      addTypename: addTypename,
      cache: resolvedCache,
      defaultFetchPolicy: defaultFetchPolicy,
      defaultErrorPolicy: defaultErrorPolicy,
      defaultStaleTime: defaultStaleTime,
      defaultCacheTime: defaultCacheTime,
      defaultRetry: defaultRetry,
      maxConcurrentBackgroundRefetches: maxConcurrentBackgroundRefetches,
      loggerOptions: loggerOptions,
    );
  }

  GraphQLClient._({
    required this.cache,
    required this.defaultFetchPolicy,
    required this.defaultErrorPolicy,
    required this.loggerOptions,
    required this.defaultStaleTime,
    required this.defaultCacheTime,
    required this.defaultRetry,
    this.maxConcurrentBackgroundRefetches,
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
    this.defaultStaleTime = Duration.zero,
    this.defaultCacheTime,
    this.defaultRetry,
    this.maxConcurrentBackgroundRefetches,
  })  : cache = cache ?? InMemoryCache(),
        _ownedDio = null,
        _pipeline = link;

  /// Derives [accessTokenHeader]/`onTokenRefresh`/[onRevokeToken] from
  /// [refreshCallback] so [GraphQLClient] can manage its own auth session via
  /// [TokenStorage.i] — [refreshCallback] is the sole source of truth for
  /// refresh; an explicit [accessTokenHeader] only overrides the header
  /// supplier. [refreshTokenHeader] is passed through unchanged — it has no
  /// default and is only attached when the app explicitly supplies one.
  ///
  /// The resulting `onTokenRefresh` is what [AuthLink] dedupes concurrent
  /// 401s against (a shared in-flight [Future] — see `AuthLink._refreshToken`),
  /// so however many requests fail at once, [refreshCallback] runs at most
  /// once per refresh cycle and every one of them retries once it resolves.
  static ({
    TokenHeaderCallback? accessTokenHeader,
    TokenHeaderCallback? refreshTokenHeader,
    OnRefreshCallback? onTokenRefresh,
    OnRevokeTokenCallback? onRevokeToken,
  }) _resolveAuthCallbacks({
    required TokenHeaderCallback? accessTokenHeader,
    required TokenHeaderCallback? refreshTokenHeader,
    required OnRevokeTokenCallback? onRevokeToken,
    required RefreshCallback? refreshCallback,
  }) {
    if (refreshCallback == null) {
      return (
        accessTokenHeader: accessTokenHeader,
        refreshTokenHeader: refreshTokenHeader,
        onTokenRefresh: null,
        onRevokeToken: onRevokeToken,
      );
    }

    return (
      accessTokenHeader: accessTokenHeader ??
          (token) async => {'Authorization': 'Bearer $token'},
      // No default: refreshCallback already receives the refresh token
      // directly as a parameter (for a body/variable), so a header is only
      // attached when the app explicitly opts in via refreshTokenHeader.
      refreshTokenHeader: refreshTokenHeader,
      onTokenRefresh: (refreshClient) async {
        final currentRefreshToken = await TokenStorage.i.refreshToken;
        // No refresh token to call the API with — revoke straight away
        // instead of calling refreshCallback with one.
        if (currentRefreshToken == null) return null;
        final newToken =
            await refreshCallback(refreshClient, currentRefreshToken);
        if (newToken == null) return null;
        // Silent: a refresh must not fire TokenStorage listeners (they drive
        // app routing). The next request reads the new token from storage.
        await TokenStorage.i.updateToken(newToken);
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
    TokenHeaderCallback? accessTokenHeader,
    TokenHeaderCallback? refreshTokenHeader,
    IsTokenExpiredCallback? isTokenExpired,
    IsUnauthorizedCallback? isUnauthorized,
    OnRefreshCallback? onTokenRefresh,
    OnRevokeTokenCallback? onRevokeToken,
    Duration? refreshTimeout,
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
        defaultHeaders: defaultHeaders ?? const {},
        accessTokenHeader: accessTokenHeader,
        refreshTokenHeader: refreshTokenHeader,
        isTokenExpired: isTokenExpired,
        isUnauthorized: isUnauthorized,
        onTokenRefresh: onTokenRefresh,
        onRevokeToken: onRevokeToken,
        refreshTimeout: refreshTimeout,
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
    final dioLink = DioLink(
      url,
      client: dioInstance,
      defaultHeaders: defaultHeaders ?? const {},
    );

    final subLink = subscriptionLink ??
        (wsUrl != null
            ? WebSocketLink(
                wsUrl,
                initialPayload: accessTokenHeader != null
                    ? () async {
                        final token = await TokenStorage.i.accessToken;
                        return token != null
                            ? await accessTokenHeader(token)
                            : const {};
                      }
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

  static bool _isSubscription(gql.Request req) => _operationIs(
        req.operation.document,
        req.operation.operationName,
        OperationType.subscription,
      );

  static bool _isMutation(gql.Request req) => _operationIs(
        req.operation.document,
        req.operation.operationName,
        OperationType.mutation,
      );

  /// Whether the operation named [operationName] in [document] (or, absent a
  /// name, any operation in it) is of [type] — shared by [_isMutation]/
  /// [_isSubscription] (checked against the wire-level [gql.Request]) and
  /// [_forcedNoCachePolicy] (checked directly against a [GraphQLRequest],
  /// before a [gql.Request] even exists).
  static bool _operationIs(
    DocumentNode document,
    String? operationName,
    OperationType type,
  ) {
    final defs = document.definitions.whereType<OperationDefinitionNode>();
    if (operationName != null) {
      final match = defs.where((d) => d.name?.value == operationName);
      if (match.isNotEmpty) {
        return match.first.type == type;
      }
    }
    return defs.any((d) => d.type == type);
  }

  /// Forces [FetchPolicy.noCache] for a mutation or subscription, regardless
  /// of the request's own [GraphQLRequest.fetchPolicy] or
  /// [defaultFetchPolicy] — reading or writing the normalized cache under a
  /// mutation/subscription's own operation key never makes sense (there is
  /// no "cached mutation result" to serve), and a mistaken override (e.g. a
  /// hand-built request or a future generator default) must not be able to
  /// make one happen. [GraphQLRequest.optimisticResponse] is unaffected —
  /// it writes to the optimistic layer other *queries* read from, which is
  /// how mutations opt into optimistic UI updates, and stays available no
  /// matter the resolved policy.
  static FetchPolicy _resolveFetchPolicy(GraphQLRequest req, FetchPolicy fallback) {
    final policy = req.fetchPolicy ?? fallback;
    if (policy == FetchPolicy.noCache) return policy;
    final isMutationOrSubscription =
        _operationIs(req.documentNode, req.operationName, OperationType.mutation) ||
            _operationIs(req.documentNode, req.operationName, OperationType.subscription);
    return isMutationOrSubscription ? FetchPolicy.noCache : policy;
  }

  /// Routes [gqlReq] through [_pipeline], deduplicating concurrent identical
  /// **queries only** — never mutations, never subscriptions (which have
  /// their own reconnect semantics in [WebSocketLink]/[SseLink] and are
  /// long-lived multi-emission streams), and never a request carrying an
  /// explicit [CancelToken] (see [_inFlight]'s doc comment).
  Stream<gql.Response> _requestThroughPipeline(
    GraphQLRequest req,
    gql.Request gqlReq, {
    required bool skipDedup,
  }) async* {
    if (skipDedup || _isMutation(gqlReq) || _isSubscription(gqlReq)) {
      yield* _pipeline.request(gqlReq);
      return;
    }

    final key = computeRequestKey(req);
    var future = _inFlight[key];
    final isOwner = future == null;
    if (isOwner) {
      // `.toList()` buffers the full response sequence and completes with
      // the stream's error if it fails. Awaiting the same [Future] from
      // every caller (below) — rather than sharing a live broadcast stream —
      // means a late caller reliably receives the buffered result or error
      // regardless of when it attaches: a broadcast stream drops events
      // emitted before a given listener attaches, which a live
      // (non-buffered) design here would have hit routinely, since
      // `cacheFirst`/`cacheAndNetwork` callers reach this after a real await
      // gap (a cache read), so identical calls land at different microtask
      // depths, not synchronously together.
      future = _pipeline.request(gqlReq).toList();
      _inFlight[key] = future;
    }

    try {
      // Awaiting here (rather than deriving a new Stream from the Future)
      // lets any error surface as a normal exception on *this* generator, so
      // the caller's own try/catch around its `await for` sees it directly —
      // and cleanup below runs via a plain `finally`, with no separate
      // derived-future side-channel that could itself go unhandled.
      final responses = await future;
      for (final response in responses) {
        yield response;
      }
    } finally {
      if (isOwner) _inFlight.remove(key);
    }
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
    final policy = _resolveFetchPolicy(req, defaultFetchPolicy);

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
        if (cached == null) {
          yield* _fetchFromNetwork(req, cancelToken: cancelToken);
          break;
        }
        final staleTime = req.staleTime ?? defaultStaleTime;
        final writtenAt = cache.writtenAt(req);
        final isFresh = writtenAt != null &&
            DateTime.now().difference(writtenAt) < staleTime;
        yield GraphQLResponse<TData>(
          data: cached,
          source: ResponseSource.cache,
          loading: !isFresh,
        );
        if (isFresh) break;
        yield* _fetchFromNetwork(req, cancelToken: cancelToken);
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

  /// Watches query cache reactively. Also orchestrates the client-driven
  /// behaviors that only make sense for an *active* subscriber: a
  /// background revalidation on attach when the cached value is already
  /// stale, `refetchInterval` polling while subscribed, and `cacheTime`
  /// garbage collection once the last subscriber cancels.
  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> req) {
    final key = computeRequestKey(req);

    StreamSubscription<TData?>? cacheSub;
    Timer? myIntervalTimer;
    late StreamController<TData?> controller;

    controller = StreamController<TData?>.broadcast(
      onListen: () {
        // All registry mutation happens here, inside onListen, and nowhere
        // at watchQuery() call time — a caller may call watchQuery() long
        // before listening (e.g. in a widget's build()), and touching the
        // registry earlier would race a pending gcTimer from a just-
        // cancelled prior watcher on the same key.
        final active = _activeQueries.putIfAbsent(key, () => _ActiveQuery(req));
        active.latestRequest = req;
        active.refCount++;
        active.gcTimer?.cancel();
        active.gcTimer = null;

        // Cache.watchQuery's own "emit initial value" add() happens before
        // its returned stream has a listener (broadcast streams drop events
        // with no subscribers), so it never reaches us. Seed the outer
        // controller with the current cached value ourselves — add() here,
        // inside onListen, *is* delivered to the caller synchronously.
        controller.add(cache.readQuery(req));
        cacheSub = cache.watchQuery(req).listen(controller.add);

        final staleTime = req.staleTime ?? defaultStaleTime;
        final writtenAt = cache.writtenAt(req);
        final isStale = writtenAt == null ||
            DateTime.now().difference(writtenAt) >= staleTime;
        if (isStale) {
          unawaited(_backgroundRefetch(req));
        }

        final interval = req.refetchInterval;
        if (interval != null) {
          myIntervalTimer = Timer.periodic(
              interval, (_) => unawaited(_backgroundRefetch(req)));
          active.refetchIntervalTimers.add(myIntervalTimer!);
        }
      },
      onCancel: () async {
        await cacheSub?.cancel();

        // Cancel only this call's own interval timer — a shared single
        // Timer? field would let concurrent watchers on the same key
        // stomp on each other's timers (leaking one, killing the other's
        // polling early).
        final timer = myIntervalTimer;
        if (timer != null) {
          timer.cancel();
          _activeQueries[key]?.refetchIntervalTimers.remove(timer);
          myIntervalTimer = null;
        }

        final active = _activeQueries[key];
        if (active == null) return;
        active.refCount--;

        if (active.refCount <= 0) {
          final cacheTime = req.cacheTime ?? defaultCacheTime;
          if (cacheTime != null) {
            active.gcTimer = Timer(cacheTime, () {
              _activeQueries.remove(key);
              cache.evictQuery(active.latestRequest);
            });
          } else {
            _activeQueries.remove(key);
          }
        }
      },
    );

    return controller.stream;
  }

  /// Triggers a background `networkOnly` refetch for every currently
  /// active [watchQuery] subscription — call this from your app's
  /// connectivity listener (e.g. `connectivity_plus`) when the device
  /// regains network connectivity.
  Future<void> notifyReconnected() => _refetchActiveQueries();

  /// Call from your app's lifecycle observer when the app moves to the
  /// background (e.g.
  /// `WidgetsBindingObserver.didChangeAppLifecycleState(paused)`) to pause
  /// every opportunistic background refetch — staleness-on-attach,
  /// `refetchInterval` polling, [invalidateQueries], [notifyReconnected] —
  /// until [notifyAppResumed] is called. Nothing refetches data for a
  /// screen the user can't see; on most platforms a backgrounded app's
  /// network requests are cheap to make but pointless, so skipping them
  /// outright is a straightforward battery and data-usage win. A request
  /// made directly (`future`/`stream`/`refetch`, e.g. from a foreground
  /// service) is unaffected — only the client's own opportunistic
  /// background refetches are paused.
  void notifyAppPaused() => _pollingPaused = true;

  /// Call from your app's lifecycle observer when the app returns to the
  /// foreground (e.g.
  /// `WidgetsBindingObserver.didChangeAppLifecycleState(resumed)`). Clears
  /// any pause set by [notifyAppPaused], then triggers a background
  /// `networkOnly` refetch for every currently active [watchQuery]
  /// subscription, so data that went stale — or that a paused
  /// `refetchInterval`/[invalidateQueries]/[notifyReconnected] skipped
  /// refetching — catches up immediately instead of waiting for its next
  /// scheduled tick.
  Future<void> notifyAppResumed() {
    _pollingPaused = false;
    return _refetchActiveQueries();
  }

  /// Evicts every cached query matching [operationNames] and/or [types]
  /// (a query matches if its operation name is in [operationNames], or if
  /// its cached result touched a `__typename` in [types]). When
  /// [refetchActive] (default `true`), a matching query with at least one
  /// active [watchQuery] subscriber is immediately background-refetched so
  /// that subscriber's stream updates in place; a match with no active
  /// subscriber is simply evicted and refetched lazily on next read. The
  /// background refetch (not the eviction) is skipped while
  /// [notifyAppPaused] is in effect — the subscriber still gets fresh data,
  /// just on [notifyAppResumed] instead of immediately.
  Future<void> invalidateQueries({
    List<String>? operationNames,
    List<String>? types,
    bool refetchActive = true,
  }) async {
    final keys = cache.matchingQueryKeys(
      operationNames: operationNames,
      types: types,
    );

    final toRefetch = <GraphQLRequest>[];
    for (final key in keys) {
      cache.evict('ROOT_QUERY:$key');
      final active = _activeQueries[key];
      if (refetchActive && active != null && active.refCount > 0) {
        toRefetch.add(active.latestRequest);
      }
    }
    await _backgroundRefetchAll(toRefetch);
  }

  Future<void> _refetchActiveQueries() => _backgroundRefetchAll([
        for (final active in _activeQueries.values)
          if (active.refCount > 0) active.latestRequest,
      ]);

  /// Runs [_backgroundRefetch] for every request in [requests], honoring
  /// [maxConcurrentBackgroundRefetches] when set. Each request only starts
  /// once a free slot is available — unlike a plain `Future.wait` over an
  /// eagerly-built list, which would already have started every one of them
  /// before this ever got a chance to limit anything.
  Future<void> _backgroundRefetchAll(List<GraphQLRequest> requests) async {
    final limit = maxConcurrentBackgroundRefetches;
    if (limit == null || requests.length <= limit) {
      await Future.wait(requests.map(_backgroundRefetch));
      return;
    }

    final inFlight = <Future<void>>{};
    for (final req in requests) {
      late final Future<void> future;
      future = _backgroundRefetch(req).whenComplete(() {
        inFlight.remove(future);
      });
      inFlight.add(future);
      if (inFlight.length >= limit) {
        await Future.any(inFlight);
      }
    }
    await Future.wait(inFlight);
  }

  /// Runs [req] as a `networkOnly` fetch purely to refresh the cache — used
  /// by staleness-on-attach, `refetchInterval`, [invalidateQueries], and
  /// [notifyReconnected]/[notifyAppResumed]. Failures are swallowed: none
  /// of those callers initiated this fetch directly, so there is no
  /// `Future` of theirs to fail — the cache simply keeps its last-good
  /// value and any active `watchQuery` stream doesn't update.
  ///
  /// A no-op while [_pollingPaused] (see [notifyAppPaused]) — every caller
  /// above is an *opportunistic* refetch nothing is waiting on, so skipping
  /// it for a backgrounded app is free. [notifyAppResumed] clears the pause
  /// and re-runs this for everything currently active, so nothing is lost,
  /// only deferred.
  Future<void> _backgroundRefetch<TData, TVars>(
    GraphQLRequest<TData, TVars> req,
  ) async {
    if (_pollingPaused) return;
    try {
      await for (final _ in _fetchFromNetwork(
        req.copyWithFetchPolicy(FetchPolicy.networkOnly),
      )) {}
    } catch (_) {
      // Swallowed by design — see doc comment above.
    }
  }

  /// Whether a persisted access token exists in [TokenStorage.i] — i.e.
  /// whether a session is stored, not whether the server still accepts it.
  Future<bool> get isAuthenticated async =>
      await TokenStorage.i.accessToken != null;

  /// Disposes client resources and all child links.
  ///
  /// Closes the [Dio] client only when this [GraphQLClient] created it
  /// itself (no `dio:` argument was passed to the factory) — a caller-
  /// supplied [Dio] is theirs to close, since they may still hold a
  /// reference to it elsewhere.
  Future<void> dispose() async {
    for (final active in _activeQueries.values) {
      active.gcTimer?.cancel();
      for (final t in active.refetchIntervalTimers) {
        t.cancel();
      }
    }
    _activeQueries.clear();
    _inFlight.clear();

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

    // defaultRetry applies to queries only. Mutations (not idempotent) and
    // subscriptions (long-lived; they reconnect via their own transport link)
    // opt out of the default and retry only when the request sets its own.
    final retryOptions = req.retry ??
        (_isMutation(gqlReq) || _isSubscription(gqlReq) ? null : defaultRetry);

    var attempt = 1;
    while (true) {
      try {
        await for (final res in _requestThroughPipeline(
          req,
          gqlReq,
          skipDedup: effectiveCancelToken != null,
        )) {
          yield GraphQLResponse<TData>(
            data: res.data != null ? req.parseData(res.data!) : null,
            errors: mapGraphQLErrors(res.errors),
            source: ResponseSource.network,
          );
        }
        return;
      } catch (e) {
        final mapped = GraphQLExceptionExtension.fromLinkException(e);
        final canRetry = retryOptions != null &&
            attempt < retryOptions.maxAttempts &&
            retryOptions.shouldRetry(mapped);
        if (!canRetry) {
          yield GraphQLResponse<TData>(
            linkException: mapped,
            source: ResponseSource.network,
          );
          return;
        }
        await Future<void>.delayed(retryOptions.delayForAttempt(attempt));
        attempt++;
      }
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

/// Per-query-key bookkeeping for [GraphQLClient._activeQueries]: how many
/// [GraphQLClient.watchQuery] subscribers are currently attached, plus the
/// pending `cacheTime` GC / `refetchInterval` polling timers driven by that
/// refcount.
class _ActiveQuery {
  _ActiveQuery(this.latestRequest);
  GraphQLRequest latestRequest;
  int refCount = 0;
  Timer? gcTimer;

  /// One entry per concurrent [GraphQLClient.watchQuery] call on this key
  /// that has `refetchInterval` set — each call owns and cancels only its
  /// own timer (tracked locally in its `watchQuery` closure), so N
  /// concurrent watchers poll independently of one another. This set lets
  /// [GraphQLClient.dispose] still reach and cancel every live one.
  final Set<Timer> refetchIntervalTimers = {};
}
