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
  final ErrorPolicy? errorPolicy;     // per-request override (none | ignore | all)
  final Map<String, String>? headers; // per-request extra headers
  final TData? optimisticResponse;
  final CancelToken? cancelToken;
  final Duration? staleTime;          // overrides GraphQLClient.defaultStaleTime
  final Duration? cacheTime;          // overrides GraphQLClient.defaultCacheTime
  final RetryOptions? retry;          // overrides GraphQLClient.defaultRetry
  final Duration? refetchInterval;    // periodic background refetch while watched

  GraphQLRequest<TData, TVars> copyWithRequest({ ... });
  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy);
}
```

The generator emits concrete subclasses per operation (`GetUserReq`, `CreatePostReq`, ...) and already forwards `staleTime`/`cacheTime`/`retry`/`refetchInterval` correctly. If you hand-write a `GraphQLRequest` subclass yourself and set any of these four fields, forward them in your own `copyWithRequest` override too (e.g. `staleTime: staleTime, cacheTime: cacheTime, retry: retry, refetchInterval: refetchInterval,` reading from `this`) — they aren't parameters of `copyWithRequest` itself (same as `requestId`), so an override that doesn't explicitly preserve them will silently drop them on every `copyWithFetchPolicy`/`refetch`/background-refetch call.

---

## `GraphQLClient` API

| Method | Returns | Behavior |
|---|---|---|
| `future(req, {cancelToken})` | `Future<TData>` | Runs request once via `request()`, throws on error. |
| `stream(req, {cancelToken})` | `Stream<TData>` | Runs request, mapping emissions to `TData`, throws on error. |
| `refetch(req, {cancelToken})` | `Future<TData>` | Like `future`, but forces `FetchPolicy.networkOnly` and writes result to cache. |
| `refetchStream(req, {cancelToken})` | `Stream<TData>` | Streaming variant of `refetch`. |
| `fetchMore(...)` | `Future<TData>` | Fetches next page, auto-merges lists/connections, writes to cache under `originalRequest`. |
| `request(req, {cancelToken})` | `Stream<GraphQLResponse<TData>>` | Low-level: yields raw responses (cache/network/optimistic), never throws. |
| `watchQuery(req)` | `Stream<TData?>` | Subscribes to cache updates for this request's cache key, independent of network activity. |
| `dispose()` | `Future<void>` | Clears revoke-token listeners, clears cache, disposes link pipeline. |

---

## `GraphQLClient.create`

`GraphQLClient(...)` is a synchronous factory — it needs a `Cache` instance up front. `GraphQLClient.create({...})` is the async counterpart: it takes every same named parameter, but `cache` accepts a `FutureOr<Cache>?`, so an async cache constructor like `HiveCache.open(...)` can be passed directly without a separate `await` statement:

```dart
final client = await GraphQLClient.create(
  url: 'https://api.example.com/graphql',
  cache: HiveCache.open(boxName: 'gql_cache'),
);
```

Use the sync constructor for `InMemoryCache` (the default when `cache` is omitted) or a `HiveCache`/other cache you've already opened/awaited yourself — `GraphQLClient.create` only exists to avoid an extra `await` line when the cache itself is async. See [Caching: Persistent cache `HiveCache`](caching.md#persistent-cache-hivecache).

---

## Request Execution Extensions

`GraphQLRequestExecutionExtension` allows direct execution on request instances:

```dart
// Execute directly:
final data = await req.execute(client);

// Refetch directly:
final freshData = await req.refetch(client);

// Fetch more directly:
final merged = await req.fetchMore(client, nextRequest: nextReq);

// Stream directly:
req.stream(client).listen((data) => print(data));

// Watch cache directly:
req.watch(client).listen((cachedData) => print(cachedData));
```

---

## `FetchPolicy`

```dart
enum FetchPolicy {
  cacheFirst,      // Cache if present, else network
  networkOnly,     // Always network, writes result to cache
  cacheOnly,       // Cache only; null if absent, never hits network
  cacheAndNetwork, // Emit cache immediately (if present), then always network
  noCache,         // Network only; cache is neither read nor written
}
```

Set a default on the client (`GraphQLClient(defaultFetchPolicy: ...)`) and override per request via `req.fetchPolicy` or `req.copyWithFetchPolicy(...)`.

---

## Request deduplication

Concurrent identical **queries** — same operation, same document, same variables — automatically share a single in-flight network call instead of each starting its own. Two widgets both doing `client.stream(getUserReq)` (or `future`) on the same query in the same frame only hit the network once; both callers still get their own response.

Deduplication applies to queries only. Mutations never dedup (each call is expected to run exactly once); subscriptions never dedup either (they're long-lived multi-emission streams with their own reconnect logic in the transport links, `WebSocketLink`/`SseLink`); and neither does any request carrying an explicit `CancelToken` (a caller who wants to cancel *their own* call shouldn't be silently attached to someone else's in-flight request). No configuration is needed — this is always on.

---

## Retry with backoff

`GraphQLClient` can automatically retry a failed query with exponential backoff:

```dart
class RetryOptions {
  final int maxAttempts;                        // default 3, total attempts including the first
  final Duration initialDelay;                  // default 200ms, delay before the first retry
  final double backoffMultiplier;                // default 2.0
  final bool Function(Object error)? retryIf;    // default: transient network errors only

  const RetryOptions({...});

  /// A single attempt, no retry.
  static const RetryOptions none = RetryOptions(maxAttempts: 1);
}
```

- `GraphQLClient(defaultRetry: ...)` — applied automatically to **queries only**; `null` (the default) disables auto-retry. **Neither mutations nor subscriptions use this** — they retry only if the request sets its own `GraphQLRequest.retry` (subscriptions already reconnect on their own, via `WebSocketLink`/`SseLink`).
- `GraphQLRequest.retry` — overrides `defaultRetry` for this request. Pass `RetryOptions.none` to disable retry for an otherwise-retrying query, or any `RetryOptions` to opt a mutation into retry.
- The default `retryIf` retries connection errors and timeouts (`NetworkException`, `TimeoutException`) — never 4xx/validation errors, since those won't succeed on retry regardless of attempts.

```dart
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  defaultRetry: const RetryOptions(maxAttempts: 4, initialDelay: Duration(milliseconds: 300)),
);

// Opt this one query out of the client default:
final req = GetUserReq(variables: GetUserVars(id: userId), retry: RetryOptions.none);

// Opt this mutation into retry (mutations don't retry by default):
final createReq = CreatePostReq(
  variables: CreatePostVars(title: title),
  retry: const RetryOptions(maxAttempts: 2),
);
```

---

## `ErrorPolicy`

Controls how the client handles GraphQL errors in responses:

```dart
enum ErrorPolicy {
  none,   // (Default) Throws GraphQLException if any errors exist, even if partial data exists
  ignore, // Ignores GraphQL errors and returns partial data when present
  all,    // Returns partial data without throwing, while preserving errors on GraphQLResponse
}
```

Set a default on the client (`GraphQLClient(defaultErrorPolicy: ...)`) and override per request via `req.copyWithRequest(errorPolicy: ErrorPolicy.ignore)`.

---

## `GraphQLResponse<TData>`

What `request()` yields:

```dart
class GraphQLResponse<TData> {
  final TData? data;
  final List<GraphQLError>? errors;
  final GraphQLException? linkException;
  final ResponseSource source; // cache | network | optimistic
  final bool loading;          // true for optimistic/stale emissions awaiting network

  bool get hasErrors;
  bool get hasValidationErrors;
  Map<String, List<String>> get validationErrors;
  ValidationException? get validationException;
}
```

---

## Errors & Validation

All thrown errors are `GraphQLException` subclasses (which extend `gql_link`'s `LinkException`):

| Exception | When |
|---|---|
| `ValidationException` | Backend field validation failure (`BAD_USER_INPUT`, `GRAPHQL_VALIDATION_FAILED`, Laravel/Lighthouse, NestJS, Spring DGS). Extends `BadRequestException`. |
| `UnAuthorizedException` | GraphQL error with extension code `UNAUTHORIZED`/`UNAUTHENTICATED`/`FORBIDDEN`. |
| `BadRequestException` | Generic bad request or user input error. |
| `NotFoundException` | `QUERY_NOT_FOUND` / `NOT_FOUND`. |
| `ParseException` | `GRAPHQL_PARSE_FAILED`, or a local JSON/deserialization failure. |
| `NetworkException` | Dio connection error (offline, DNS, etc). |
| `TimeoutException` | Request exceeded Dio's configured timeout. |
| `RequestCancelledException` | The request's `CancelToken` was cancelled. |
| `RevokeTokenException` | Thrown when a token refresh attempt itself fails (its message wraps the real cause) and there's no more specific original error to surface instead — see [Links: `AuthLink`](links.md#authlink). |
| `AppServerException` | Fallback for anything else (with an optional HTTP `code`). |

### Handling Validation Errors

```dart
try {
  await client.future(myReq);
} on ValidationException catch (e) {
  // Map of field names to error lists:
  final errors = e.validationErrors; // {'email': ['Email already taken']}

  // Helper methods:
  if (e.hasError('email')) {
    final firstMsg = e.getFirstError('email'); // 'Email already taken'
  }
  final allFields = e.fields;         // ['email']
  final allMessages = e.allMessages; // ['Email already taken']
}
```

---

## Global Token-Revocation Listeners

Independent of any single client instance, you can react to a revoked token anywhere in the app:

```dart
GraphQLClient.registerRevokeTokenListener(() {
  // Clear stored credentials and navigate to login screen
});
```
