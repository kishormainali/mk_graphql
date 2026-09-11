# Link Pipeline

`mk_graphql` builds on [`gql_link`](https://pub.dev/packages/gql_link)'s `Link` abstraction: each link is a middleware stage that can inspect/transform a request, forward it, and inspect/transform the response stream. `GraphQLClient` assembles a pipeline for you; you only need this page if you want to customize it or use a link standalone.

## The default pipeline

```
AuthLink?  →  TypenameLink?  →  LoggerLink  →  split(is-subscription?, WebSocketLink|SseLink, DioLink)
```

- `AuthLink` is included only if you pass `tokenHeader` and/or `onTokenRefresh`.
- `TypenameLink` is included unless you pass `addTypename: false`.
- The subscription branch is chosen by inspecting the parsed document for an `OperationType.subscription`; it only exists if you pass `wsUrl`, `sseUrl`, or `subscriptionLink`.
- Everything else (queries/mutations) always terminates in `DioLink`.

## `AuthLink`

Injects auth headers into every request and handles 401-driven refresh:

```dart
AuthLink(
  url: endpoint,               // also used for the refresh request
  tokenHeader: () async => {'Authorization': 'Bearer $token'},
  isTokenExpired: () async => tokenIsExpired, // optional: proactive refresh
  onTokenRefresh: (refreshDioLink) async {
    // perform the refresh call using refreshDioLink or your own client
    return {'Authorization': 'Bearer $newToken'};
  },
  onRevokeToken: () => logOut(),
);
```

Behavior:

- **Proactive refresh**: if `isTokenExpired` is supplied and returns `true`, the token is refreshed *before* the request is sent.
- **Reactive refresh**: if a response comes back unauthorized (`extensions.code` is `UNAUTHORIZED`/`UNAUTHENTICATED`/`FORBIDDEN`) and `onTokenRefresh` is set, the request is retried exactly once with the new headers.
- **Concurrent refresh de-duplication**: multiple requests hitting a 401 simultaneously share a single in-flight refresh call rather than each triggering their own.
- **Revocation**: if `onTokenRefresh` throws, `onRevokeToken` is called and every listener registered via `GraphQLClient.registerRevokeTokenListener` fires — see [Errors](client-and-requests.md#errors).

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
- **`HttpLink(endpoint, {defaultHeaders})`** — a plain `package:http`-based alternative when you don't want a Dio dependency for the terminating link.
- **`SseLink(url, {defaultHeaders, tokenHeader, onTokenRefresh, useGetForQueries})`** — Server-Sent Events transport for subscriptions, with the same auth-header/refresh semantics as `AuthLink` built in (useful since SSE connections are long-lived and can outlast a token).
- **`WebSocketLink(url, {initialPayload, subprotocols, reconnectInterval, autoReconnect})`** — `graphql-ws`/`graphql-transport-ws` subscriptions over WebSocket, with automatic reconnect.
- **`BatchLink(endpoint, {defaultHeaders, batchTimeout, maxBatchSize})`** — batches multiple queries/mutations issued within `batchTimeout` (default 10ms) into a single HTTP request, up to `maxBatchSize` (default 10) per batch. Use it as a terminating link in place of `DioLink` when your server supports batched GraphQL requests.

Pick the subscription transport by passing exactly one of `wsUrl`, `sseUrl`, or a custom `subscriptionLink` to `GraphQLClient(...)`.

## Customizing beyond the constructor

`GraphQLClient`'s constructor covers the common cases (auth, typename injection, logging, HTTP/SSE/WebSocket transports) by building the pipeline internally from the arguments you pass — there is currently no way to hand it a fully custom, pre-assembled `Link` chain (e.g. to swap in `BatchLink` or insert your own middleware). The one exception is the subscription branch: pass `subscriptionLink` to use any `Link` you like in place of the built-in `WebSocketLink`/`SseLink` selection.

If you need a link this constructor doesn't expose (like `BatchLink` as the terminating transport), use that link directly with `gql_link`'s lower-level APIs instead of going through `GraphQLClient`, or open an issue describing the use case.
