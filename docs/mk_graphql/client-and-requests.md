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

  GraphQLRequest<TData, TVars> copyWithRequest({ ... });
  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy);
}
```

The generator emits concrete subclasses per operation (`GetUserReq`, `CreatePostReq`, ...).

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
| `RevokeTokenException` | Internal — thrown when `onTokenRefresh` fails during `AuthLink` refresh. |
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
