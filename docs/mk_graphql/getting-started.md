# mk_graphql — Getting Started

`mk_graphql` is the runtime GraphQL client for Dart & Flutter. It executes typed `GraphQLRequest`s (produced by [`mk_graphql_generator`](../mk_graphql_generator/getting-started.md)), manages a normalized cache with canonical key ordering, composes a link pipeline for auth, logging, HTTP, SSE, and WebSocket transports, and provides automatic pagination and validation error handling.

---

## Step 1: Install Dependencies

In your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  mk_graphql: ^1.2.2
```


Run:
```bash
flutter pub get
```

---

## Step 2: Create a `GraphQLClient`

```dart
import 'package:mk_graphql/mk_graphql.dart';

final client = GraphQLClient(
  url: 'https://api.example.com/graphql',

  // Optional: WebSocket or SSE endpoint for subscriptions
  sseUrl: 'https://api.example.com/graphql/sse',
  // wsUrl: 'wss://api.example.com/graphql',

  // Optional: the sole source of truth for token refresh. The client manages
  // TokenStorage.i and the `Authorization` header on its own — no app-side
  // storage or header plumbing needed.
  refreshCallback: (refreshClient, refreshToken) async {
    final newToken = await refreshUserToken(refreshClient, refreshToken);
    return newToken; // a TokenPair, or null/throw to revoke
  },

  // Optional: default fetch policy (defaults to FetchPolicy.noCache)
  defaultFetchPolicy: FetchPolicy.cacheFirst,

  // Optional: default error policy (defaults to ErrorPolicy.none)
  defaultErrorPolicy: ErrorPolicy.none,
);
```

### Internal Link Pipeline

`GraphQLClient` automatically composes the following link pipeline:

```
AuthLink?  →  TypenameLink?  →  LoggerLink  →  split(subscription?, WebSocketLink|SseLink, DioLink)
```

See [Link Pipeline](links.md) for details on customizing links or using `GraphQLClient.fromLink(...)`.

`GraphQLClient` reads and writes tokens through the `TokenStorage.i` singleton
(from [`token_storage`](https://pub.dev/packages/token_storage), re-exported by
`mk_graphql`; call `await TokenStorage.init()` once at startup) — it never needs app-side storage plumbing when `refreshCallback` is
configured. On explicit logout, call `TokenStorage.i.clearToken()` and
`AuthLink.notifyRevokeToken()` to drive app-wide auth state (e.g. navigate to
the login screen) via `GraphQLClient.registerRevokeTokenListener(...)`.

`TokenStorage.i.setTokenListener(...)` fires when a session is saved
(`saveToken`, e.g. on login) and when it is cleared (`clearToken`, with
`null`) — but **not** when `refreshCallback` refreshes the tokens. A refresh is
written silently via `TokenStorage.i.updateToken(...)`, so app routing driven by
the listener isn't rebuilt; the next request just picks up the new tokens from
storage. `TokenPair.createdAt`/`updatedAt` (from `TokenStorage.i.token`)
record when the session started and when it was last refreshed. See
[Authentication & Token Storage](authentication.md) for the full picture.

---

## Step 3: Run Queries & Mutations

### Using `client.future`
```dart
final user = await client.future(
  GetUserReq(variables: const GetUserVars(id: '123')),
);
print(user.name);
```

### Direct Request Extension
```dart
final req = GetUserReq(variables: const GetUserVars(id: '123'));
final user = await req.execute(client);
```

---

## Step 4: Handle Errors & Validation

`client.future` and `req.execute` throw a typed `GraphQLException` subclass on error:

```dart
try {
  final user = await client.future(myReq);
} on ValidationException catch (e) {
  // Field-level validation errors from Apollo, Laravel Lighthouse, NestJS, Spring DGS
  print('Errors: ${e.validationErrors}');
  if (e.hasError('email')) {
    showFieldError('email', e.getFirstError('email')!);
  }
} on UnAuthorizedException {
  redirectToLogin();
} on NetworkException {
  showOfflineBanner();
} on GraphQLException catch (e) {
  showToast(e.message);
}
```

See [Client, Requests & Responses](client-and-requests.md#errors) for all exception types.

---

## Step 5: Refetching Queries

To bypass cache and fetch fresh network data (updating the cache in-place):

```dart
// Client API
final freshData = await client.refetch(myReq);

// Request API
final freshData2 = await myReq.refetch(client);
```

---

## Step 6: Automatic Pagination (No Manual Append Needed)

### Using `client.fetchMore` / `req.fetchMore`
Automatically merges response lists and Relay connections, updating the cache under the initial query:

```dart
final mergedData = await client.fetchMore(
  originalRequest: page1Req,
  nextRequest: page2Req,
);

// Any active watchers on page1Req immediately receive the combined dataset
```

### Using `GraphQLPaginator`
```dart
final paginator = client.paginatePage(
  initialRequest: getItemsReq,
  getItems: (data) => data.items,
  updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
  pageSize: 20,
);

// 1. Initial page
final initialItems = await paginator.loadInitial();

// 2. Next page (returns complete accumulated list)
final allLoadedItems = await paginator.loadNext();

// 3. Dynamically apply filters / search (restarts page 1 without tearing down streams)
paginator.applyVariables((vars) => vars.copyWith(search: 'keyword'));

// 4. Reactively stream items
paginator.itemsStream.listen((items) {
  print('Items count: ${items.length}');
});
```

See [Pagination Guide](pagination.md) for Relay cursor, offset/limit patterns, and `flutter_bloc` integration (`emit.forEach`).


---

## Step 7: Stream Subscriptions

```dart
client.stream(mySubscriptionRequest).listen((data) {
  print('Real-time event: $data');
});
```

---

## Next

- [Client, Requests & Responses](client-and-requests.md) — the full API surface, `FetchPolicy`, `ErrorPolicy`, cancellation, optimistic responses.
- [Caching](caching.md) — how `readQuery`/`writeQuery`/`watchQuery` work.
- [Pagination](pagination.md) — `GraphQLPaginator` and `fetchMore` in depth.
- [Link Pipeline](links.md) — auth refresh, logging, uploads, batching.
