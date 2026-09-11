# Client, Requests & Responses

## `GraphQLRequest<TData, TVars>`

Every operation — hand-written or generated — is a `GraphQLRequest<TData, TVars>`:

```dart
abstract class GraphQLRequest<TData, TVars> {
  String get document;               // raw query/mutation/subscription text
  String get operationName;
  TVars get variables;

  Map<String, dynamic> toJsonVars(TVars vars);
  TData parseData(Map<String, dynamic> json);

  final FetchPolicy? fetchPolicy;     // per-request override
  final Map<String, String>? headers; // per-request extra headers
  final TData? optimisticResponse;
  final CancelToken? cancelToken;

  GraphQLRequest<TData, TVars> copyWithRequest({ ... });
  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy);
}
```

The generator emits one concrete subclass per operation (`GetUserReq`, `CreatePostReq`, ...). You rarely implement this by hand — see [mk_graphql_generator](../mk_graphql_generator/getting-started.md).

## `GraphQLClient` API

| Method | Returns | Behavior |
|---|---|---|
| `future(req, {cancelToken})` | `Future<TData>` | Runs the request once via `request()`, throws on error. |
| `stream(req, {cancelToken})` | `Stream<TData>` | Runs the request, mapping every emission to `TData`, throws on error. |
| `refetch(req, {cancelToken})` | `Future<TData>` | Like `future`, but forces `FetchPolicy.networkOnly` and writes the result to cache. |
| `refetchStream(req, {cancelToken})` | `Stream<TData>` | Streaming variant of `refetch`. |
| `request(req, {cancelToken})` | `Stream<GraphQLResponse<TData>>` | Low-level: yields raw responses (cache/network/optimistic), never throws — errors surface via `response.hasErrors` / `response.linkException`. |
| `watchQuery(req)` | `Stream<TData?>` | Subscribes to cache updates for this request's cache key, independent of network activity. |
| `dispose()` | `Future<void>` | Clears revoke-token listeners, clears the cache, disposes the link pipeline. |

`future`/`stream` are what most call sites use. Reach for `request()` directly when you need to distinguish a cached emission from a network one (e.g. to show a "refreshing…" indicator during `cacheAndNetwork`).

### Cancellation

Pass a Dio `CancelToken` either to the call (`client.future(req, cancelToken: token)`) or bake it into the request (`req.copyWithRequest(cancelToken: token)`); the call-site token wins if both are set. Cancelling surfaces as `RequestCancelledException`.

## `FetchPolicy`

```dart
enum FetchPolicy {
  cacheFirst,      // cache if present, else network
  networkOnly,     // always network, cache is still written
  cacheOnly,       // cache only; null if absent, never hits network
  cacheAndNetwork, // emit cache immediately (if present), then always network
  noCache,         // network only; cache is neither read nor written
}
```

Set a default on the client (`GraphQLClient(defaultFetchPolicy: ...)`, defaults to `noCache`) and override per request via `req.fetchPolicy` or `req.copyWithFetchPolicy(...)`.

## `GraphQLResponse<TData>`

What `request()` yields:

```dart
class GraphQLResponse<TData> {
  final TData? data;
  final List<GraphQLError>? errors;
  final GraphQLException? linkException;
  final ResponseSource source; // cache | network | optimistic
  final bool loading;          // true for optimistic/stale emissions still awaiting network

  bool get hasErrors;
}
```

`future`/`stream` unwrap this for you and throw; use `request()` directly when you need `source`/`loading` to drive UI (e.g. showing a subtle spinner only while `loading` is true during `cacheAndNetwork`).

## Optimistic responses

Set `optimisticResponse` on a request to have the client immediately write that value into the cache and emit it (`source: ResponseSource.optimistic`, `loading: true`) before the network call resolves. The optimistic entry is removed once the real request completes (success or failure) — see [Caching](caching.md#optimistic-responses).

## Errors

All thrown errors are `GraphQLException` subclasses (which extend `gql_link`'s `LinkException`, so they still flow through `gql_link` pipelines):

| Exception | When |
|---|---|
| `UnAuthorizedException` | GraphQL error with extension code `UNAUTHORIZED`/`UNAUTHENTICATED`/`FORBIDDEN`. |
| `BadRequestException` | `BAD_USER_INPUT` / `GRAPHQL_VALIDATION_FAILED` — carries a raw `errors` list when the server provides one. |
| `NotFoundException` | `QUERY_NOT_FOUND` / `NOT_FOUND`. |
| `ParseException` | `GRAPHQL_PARSE_FAILED`, or a local JSON/deserialization failure. |
| `NetworkException` | Dio connection error (offline, DNS, etc). |
| `TimeoutException` | Request exceeded Dio's configured timeout. |
| `RequestCancelledException` | The request's `CancelToken` was cancelled. |
| `RevokeTokenException` | Internal — thrown when `onTokenRefresh` fails during an `AuthLink` refresh; triggers `onRevokeToken` and any registered revoke listeners instead of propagating to callers. |
| `AppServerException` | Fallback for anything else (with an optional HTTP `code`). |

Every exception carries `message`, and optionally `originalException`/`originalStackTrace` for logging. Catch `GraphQLException` for a catch-all, or a specific subtype to branch behavior (e.g. redirect to login on `UnAuthorizedException`).

### Global token-revocation listeners

Independent of any single client instance, you can react to a revoked token anywhere in the app:

```dart
GraphQLClient.registerRevokeTokenListener(() {
  // e.g. clear stored credentials and navigate to the login screen
});
```

Use `GraphQLClient.removeRevokeTokenListener(...)` / `clearRevokeTokenListeners()` to manage the registry (also cleared automatically by `client.dispose()`).
