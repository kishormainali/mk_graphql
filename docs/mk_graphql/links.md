# Link Pipeline

`mk_graphql` builds on [`gql_link`](https://pub.dev/packages/gql_link)'s `Link` abstraction: each link is a middleware stage that can inspect/transform a request, forward it, and inspect/transform the response stream. `GraphQLClient` assembles a pipeline for you; you only need this page if you want to customize it or use a link standalone.

## The default pipeline

``` dart
AuthLink?  →  TypenameLink?  →  LoggerLink  →  split(is-subscription?, WebSocketLink|SseLink, DioLink)
```

- `AuthLink` is included only if you pass `accessTokenHeader` and/or `onTokenRefresh`.
- `TypenameLink` is included unless you pass `addTypename: false`.
- The subscription branch is chosen by inspecting the parsed document for an `OperationType.subscription`; it only exists if you pass `wsUrl`, `sseUrl`, or `subscriptionLink`.
- Everything else (queries/mutations) always terminates in `DioLink`.

## `AuthLink`

Injects auth headers into every request and handles 401-driven refresh:

```dart
AuthLink(
  url: endpoint,               // also used for the refresh request
  accessTokenHeader: (token) async => {'Authorization': 'Bearer $token'},
  refreshTokenHeader: (refreshToken) async =>
      {'Authorization': 'Bearer $refreshToken'}, // optional
  isTokenExpired: () async => tokenIsExpired, // optional: proactive refresh
  isUnauthorized: (context) {
    // optional: override how a failure is classified
    if (context.errorCode == 'TOKEN_EXPIRED') return AuthFailure.refresh;
    if (context.errorCode == 'ACCOUNT_SUSPENDED') return AuthFailure.revoke;
    return AuthFailure.none;
  },
  onTokenRefresh: (refreshClient) async {
    // refreshClient is a plain GraphQLClient (no AuthLink attached) —
    // perform the refresh call via its normal typed API.
    final result = await refreshClient.future(refreshMutation);
    return {'Authorization': 'Bearer ${result.accessToken}'};
  },
  onRevokeToken: () => logOut(),
);
```

Behavior:

- **`accessTokenHeader`/`refreshTokenHeader`/`tokenHeader`** (`TokenHeaderCallback`) each receive the current token as their argument, read from `TokenStorage.i` — they're only invoked when a token is actually stored (skipped entirely otherwise, so the callback never has to null-check it).
- **Proactive refresh**: if `isTokenExpired` is supplied and returns `true`, the token is refreshed *before* the request is sent.
- **`refreshTokenHeader`**: has no default — the refresh token normally reaches your refresh endpoint as `onTokenRefresh`'s own mechanism (a body/variable). Pass this only if your refresh endpoint *also*/*instead* expects the refresh token as a header; when provided, it's attached to every request sent through the internal refresh client instead of `accessTokenHeader`.
- **Reactive refresh**: every response/thrown `ServerException` is classified into an `AuthFailure` (`none`, `refresh`, or `revoke`). By default, `extensions.code`/HTTP status of `UNAUTHORIZED`/`UNAUTHENTICATED`/401 classifies as `AuthFailure.refresh` (the request is retried once with the refreshed headers), and `FORBIDDEN`/403 classifies as `AuthFailure.revoke` — a valid token that simply lacks permission, so refreshing it wouldn't help; the token is revoked immediately without attempting a refresh at all. Pass `isUnauthorized` to classify your own API's convention instead — it receives a normalized `UnauthorizedContext` (built the same way whether the failure came from a streamed `Response` or a thrown `ServerException`, exposing `errors`, `statusCode`, `errorCode`, and the raw `response`/`exception`) and fully replaces the default classification when provided.
- **Concurrent refresh de-duplication**: multiple requests hitting a refreshable failure simultaneously share a single in-flight refresh call rather than each triggering their own.
- **Revocation**: `onRevokeToken` is called — and every listener registered via `GraphQLClient.registerRevokeTokenListener` fires — whenever `onTokenRefresh` throws *or* a failure classifies as `AuthFailure.revoke`. Either way, the real cause still reaches `future()`/`stream()` as a thrown exception (the original `FORBIDDEN` error, the original 401 if the refresh attempt itself failed with no more specific cause, or a `RevokeTokenException` describing why the refresh failed) — see [Errors](client-and-requests.md#errors--validation).

## `TypenameLink`

Rewrites the outgoing document to add `__typename` to every selection set. Needed for the normalized cache to key entities correctly. Disable with `GraphQLClient(addTypename: false)` only if you have a reason to (e.g. a server that rejects the extra field).

## `LoggerLink`

Pretty-prints requests/responses to the console. Configure via `LoggerOptions`:

```dart
GraphQLClient(
  url: endpoint,
  loggerOptions: const LoggerOptions(
    requestBody: true,
    responseBody: true,
    requestHeader: false,
    responseHeader: false,
    authHeader: false,   // keep tokens out of logs by default
    error: true,
    redact: true,        // masks sensitive-looking keys (password, token, ...)
    useAnsiColors: false,
  ),
);
```

It sits *after* `AuthLink`/`TypenameLink` so it logs the final document (with `__typename`) and final headers (with `Authorization`), including 401 → refresh → retry sequences.

## Transport links

Exactly one of these terminates the pipeline for a given request:

- **`DioLink(endpoint, {client, defaultHeaders, useGETForQueries})`** — the default HTTP transport, built on Dio. Handles multipart uploads automatically when a variable contains a Dio `MultipartFile` (GraphQL `Upload` scalar). Supports cancellation via `DioLinkCancelTokenContextEntry` (wired up automatically by `GraphQLClient.future/stream` when you pass a `CancelToken`).
- **`HttpLink(endpoint, {client, defaultHeaders})`** — a lightweight Dio-based alternative to `DioLink` (no proactive GET-for-queries, no response-context headers), for when you want a simpler terminating link. Also supports multipart uploads via `Upload`/`dio.MultipartFile`.
- **`SseLink(url, {defaultHeaders, tokenHeader, onTokenRefresh, useGetForQueries})`** — Server-Sent Events transport for subscriptions, with the same auth-header/refresh semantics as `AuthLink` built in (useful since SSE connections are long-lived and can outlast a token).
- **`WebSocketLink(url, {initialPayload, subprotocols, reconnectInterval, maxReconnectInterval, reconnectBackoffMultiplier, reconnectJitter, autoReconnect})`** — `graphql-ws`/`graphql-transport-ws` subscriptions over WebSocket, with automatic reconnect. Reconnect delay backs off exponentially from `reconnectInterval` (default 3s) by `reconnectBackoffMultiplier` (default 1.5) per consecutive failed attempt, capped at `maxReconnectInterval` (default 30s) — a dead server or absent network settles into a bounded retry cadence instead of hammering the connection at a fixed interval forever. `reconnectJitter` (default `0.2`) randomizes each delay by up to that fraction so many clients dropped by the same event don't all reconnect in lockstep. The attempt counter resets on every successful `connection_ack`.
- **`BatchLink(endpoint, {client, defaultHeaders, batchTimeout, maxBatchSize})`** — batches multiple queries/mutations issued within `batchTimeout` (default 10ms) into a single HTTP request, up to `maxBatchSize` (default 10) per batch. Use it as a terminating link in place of `DioLink` when your server supports batched GraphQL requests.

Pick the subscription transport by passing exactly one of `wsUrl`, `sseUrl`, or a custom `subscriptionLink` to `GraphQLClient(...)`.

## Customizing beyond the constructor

`GraphQLClient`'s constructor covers the common cases (auth, typename injection, logging, HTTP/SSE/WebSocket transports) by building the pipeline internally from the arguments you pass — there is currently no way to hand it a fully custom, pre-assembled `Link` chain (e.g. to swap in `BatchLink` or insert your own middleware). The one exception is the subscription branch: pass `subscriptionLink` to use any `Link` you like in place of the built-in `WebSocketLink`/`SseLink` selection.

If you need a link this constructor doesn't expose (like `BatchLink` as the terminating transport), use that link directly with `gql_link`'s lower-level APIs instead of going through `GraphQLClient`, or open an issue describing the use case.
