# mk_graphql

[![pub package](https://img.shields.io/pub/v/mk_graphql.svg)](https://pub.dev/packages/mk_graphql)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A clean, modern, simplified GraphQL client for Dart and Flutter with normalized caching, composable links, typed operation execution, file uploads, SSE, WebSockets, automatic pagination, refetch, and granular validation error handling.

📖 **[Full documentation](../../docs/README.md)** — client API, link pipeline, caching internals, and pagination guides.

---

## ✨ Features

- 🚀 **Composable Link Architecture**: Chain `AuthLink`, `DioLink`, `SseLink`, `WebSocketLink`, `HttpLink`, `BatchLink`, and `TypenameLink`.
- 🔐 **First-Class Authentication**: Automatic 401 handling, thread-safe asynchronous token refreshing, token queueing, and revocation hooks.
- 📡 **Multiple Transports**:
  - **HTTP/REST**: Built-in `DioLink` and standard `HttpLink`.
  - **Server-Sent Events (SSE)**: `SseLink` with live subscription streaming, dynamic auth headers, and 401 refresh retries.
  - **WebSockets**: `WebSocketLink` supporting modern subscriptions.
- 📁 **Multipart File Uploads**: Seamless GraphQL Multipart Request specification compliance for `Upload` / `MultipartFile`.
- 🛑 **Request Cancellation**: Direct integration with Dio's `CancelToken`.
- 💾 **Normalized Caching**: Fast in-memory cache with canonical JSON key ordering, optimistic responses, and configurable fetch policies (`cacheFirst`, `networkOnly`, `cacheAndNetwork`, `cacheOnly`, `noCache`).
- ⚡ **Stream & Future APIs**: Single-shot `client.future()` or reactive `client.stream()`.
- 🔄 **Direct Refetching**: `client.refetch(req)` and `req.refetch(client)` with immediate cache synchronization.
- 📑 **Automatic Pagination (Zero Manual Append)**: `client.fetchMore` and `req.fetchMore` automatically merge lists and Relay connections; `GraphQLPaginator` manages reactive infinite scroll.
- 🛡️ **Validation Errors**: Specialized `ValidationException` extracting field-level validation messages across Apollo, Laravel/Lighthouse, NestJS, and Spring DGS.
- 🪵 **Built-in Logging**: Pretty console logging with custom options and privacy masking.
- ⚡ **Smart Query Optimizations**: Automatic in-flight request deduplication, opt-out-of stale-while-revalidate caching with GC, `invalidateQueries`, retry-with-backoff, reconnect/interval refetch triggers, and battery-friendly `notifyAppPaused()`/`notifyAppResumed()` pausing of background refetches — TanStack-Query-style client behavior.
- 💽 **Optional Persistent Cache**: `HiveCache` (backed by `hive_ce`) persists the normalized cache across app restarts as a drop-in `Cache` implementation.

---

## 📦 Installation

Add `mk_graphql` to your `pubspec.yaml`:

```yaml
dependencies:
  mk_graphql: ^1.1.0
```

Then run:

```bash
flutter pub get
```

---

## 🚀 Step-by-Step Integration

### 1. Initialize `GraphQLClient`

```dart
import 'package:mk_graphql/mk_graphql.dart';

final client = GraphQLClient(
  url: 'https://api.example.com/graphql',

  // Optional: SSE or WebSocket URL for subscriptions
  sseUrl: 'https://api.example.com/graphql/sse',
  // wsUrl: 'wss://api.example.com/graphql',

  // The client reads/writes tokens itself via the `TokenStorage.i` singleton
  // (backed by flutter_secure_storage) and attaches the Authorization header
  // to every request automatically. Just tell it how to perform a refresh —
  // no header/storage plumbing needed.
  refreshCallback: (refreshClient, refreshToken) async {
    final refreshed = await refreshClient.future(RefreshTokenRequest(refreshToken));
    return TokenPair(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken,
    );
  },

  // Default caching policy: cacheFirst, networkOnly, cacheAndNetwork, cacheOnly, noCache
  defaultFetchPolicy: FetchPolicy.cacheFirst,

  // Default error policy: none (throw if errors), ignore (return partial data), all (return data with errors)
  defaultErrorPolicy: ErrorPolicy.none,

  // Also available: defaultStaleTime/defaultCacheTime (stale-while-revalidate
  // caching + GC — note cacheFirst now background-revalidates on every cache
  // hit by default) and defaultRetry (retry-with-backoff for queries). See
  // the full caching and client docs linked below.
);
```

`refreshCallback` is the single source of truth for refresh — it receives the currently stored refresh token (always non-null: with nothing stored yet, the client revokes immediately without calling it) and a plain `GraphQLClient` (no auth link attached) to run the refresh request via its normal typed API. Return the new `TokenPair` to persist, or `null`/throw to revoke — `AuthLink.registerRevokeTokenListener(...)` fires either way so you can navigate to a login screen.

A successful refresh is written with `TokenStorage.i.updateToken(...)`, which is **silent**: `TokenStorage.i.setTokenListener(...)` only fires on `saveToken` (login, with the access token) and `deleteToken` (logout/revoke, with `null`), so a refresh never rebuilds app routing. `TokenPair` carries `createdAt` (session start, kept across refreshes) and `updatedAt` (last refresh). Full details in [Authentication & Token Storage](../../docs/mk_graphql/authentication.md).

However many requests fail at once, only one `refreshCallback` call is made — `AuthLink` queues the rest behind the in-flight refresh and retries all of them once it resolves.

The access-token header defaults to `Authorization: Bearer <token>`, built from whatever `TokenStorage.i` has stored (only invoked when a token is actually present). If your API expects a different header format, pass `accessTokenHeader` yourself — it receives the token as its argument, so you don't need to touch `TokenStorage.i` directly. There's no equivalent default for the refresh token, since it already reaches your refresh endpoint as the `refreshCallback` parameter above (for a body/variable) — pass `refreshTokenHeader` only if your refresh endpoint additionally/instead expects it as a header on requests made through `refreshClient`, attached instead of `accessTokenHeader`.

By default, a response/exception is classified as `AuthFailure.refresh` when `extensions.code`/HTTP status is `UNAUTHORIZED`/`UNAUTHENTICATED`/401 (the request is retried once refreshed), and as `AuthFailure.revoke` when it's `FORBIDDEN`/403 — a valid token simply lacking permission, so a refresh wouldn't help; the token is revoked immediately instead. If your API signals either case differently, pass `isUnauthorized: (context) => ...` — it receives a normalized `UnauthorizedContext` (same shape whether the failure came from a response or a thrown exception) and fully replaces the built-in classification.

---

### 2. Execute Queries & Mutations

`client.future(req)` executes the operation once, handles caching according to `fetchPolicy`, and returns typed `TData` directly (or throws a typed `GraphQLException`):

```dart
try {
  // Using a generated or custom GraphQLRequest
  final data = await client.future(getUserReq);
  print('User: ${data.user.name}');
} on ValidationException catch (e) {
  // Field-specific validation failures
  print('Field errors: ${e.validationErrors}');
  if (e.hasError('email')) {
    print('Email error: ${e.getFirstError('email')}');
  }
} on UnAuthorizedException {
  // Session expired or unauthenticated
  navigateToLogin();
} on GraphQLException catch (e) {
  // Network, server, or execution error
  print('GraphQL Error: ${e.message}');
}
```

Or execute directly on the request object:

```dart
final data = await getUserReq.execute(client);
```

---

### 3. Reactive Streams & Cache Watching

Watch cache updates reactively:

```dart
// Stream network emissions according to FetchPolicy (e.g. cacheAndNetwork emits cache then network)
final subscription = client.stream(getUserReq).listen((data) {
  print('Received data: ${data.user.name}');
});

// Or watch normalized cache directly whenever any operation updates it
client.watchQuery(getUserReq).listen((cachedData) {
  print('Cache updated: ${cachedData?.user.name}');
});
```

---

### 4. Refetching Queries

Bypass cache with `FetchPolicy.networkOnly`, retrieve fresh network data, and update the cache in-place:

```dart
// Using client:
final freshData = await client.refetch(getUserReq);

// Using request extension:
final freshData2 = await getUserReq.refetch(client);
```

---

### 5. Automatic Pagination (Zero Manual Append Required)

You do not need to manually concatenate lists (`[...previous, ...incoming]`).

#### Option A: `client.fetchMore` / `req.fetchMore`

Automatically merges response JSON trees (concatenating list fields and merging Relay connections) and updates the cache under the initial request:

```dart
// Fetch next page and merge automatically:
final mergedData = await client.fetchMore(
  originalRequest: page1Req,
  nextRequest: page2Req,
);

// Or via request extension:
final mergedData2 = await page1Req.fetchMore(client, nextRequest: page2Req);

// Active listeners on page1Req automatically emit the accumulated data!
```

#### Option B: `GraphQLPaginator`

For infinite scroll lists with reactive state management:

```dart
// 1. Create a paginator (page-number, offset/limit, or Relay cursor):
final paginator = client.paginatePage(
  initialRequest: GetAnimePageReq(
    variables: const GetAnimePageVars(page: 1, perPage: 20),
  ),
  getItems: (data) => data.page?.media ?? [],
  updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
  pageSize: 20,
  getPage: (data) => data.page?.pageInfo?.currentPage,
  hasNextPage: (data) => data.page?.pageInfo?.hasNextPage ?? false,
);

// 2. Load initial page (returns List<TItem> directly)
final firstPageItems = await paginator.loadInitial();

// 3. Load next page (automatically accumulates and returns complete list)
final accumulatedItems = await paginator.loadNext();

// 4. Dynamically apply search queries or filters (restarts page 1 without wiping other criteria):
paginator.applyVariables((currentVars) => currentVars.copyWith(
  search: 'Naruto',
  genre: 'Action',
));

// 5. Pull-to-refresh (resets query back to initialRequest):
await paginator.refetch();

// 6. Reactive State Stream:
paginator.stream.listen((state) {
  print('Items: ${state.items.length}, LoadingMore: ${state.isLoadingMore}');
});
```

##### Flutter BLoC Integration (`emit.forEach`)

Pipe `paginator.stream` directly into BLoC state without manual subscriptions:

```dart
class AnimeListBloc extends Bloc<AnimeListEvent, AnimeListState> {
  final GraphQLPaginator _paginator;

  AnimeListBloc(this._paginator) : super(const AnimeListState()) {
    on<AnimeListStarted>((event, emit) async {
      await emit.forEach<PaginationState<MediaPartialModel>>(
        _paginator.stream,
        onData: (pState) => state.copyWith(
          items: pState.items,
          isLoading: pState.isLoading,
          isLoadingMore: pState.isLoadingMore,
          hasMore: pState.hasMore,
          error: pState.error,
        ),
      );
    });

    on<SearchChanged>((event, emit) {
      _paginator.applyVariables((v) => v.copyWith(search: event.query));
    });

    on<FetchNextPage>((event, emit) => _paginator.loadNext());
    on<Refreshed>((event, emit) => _paginator.refetch());
  }
}
```

---

### 6. Subscriptions (SSE or WebSockets)

```dart
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  sseUrl: 'https://api.example.com/graphql/sse',
  accessTokenHeader: (token) async => {'Authorization': 'Bearer $token'},
);

client.stream(mySubscriptionRequest).listen((data) {
  print('Real-time event: $data');
});
```

---

### 7. Multipart File Uploads

Conforms to the standard GraphQL Multipart Request specification:

```dart
import 'package:dio/dio.dart';
import 'package:mk_graphql/mk_graphql.dart';

final file = MultipartFile.fromFileSync(
  '/path/to/avatar.png',
  filename: 'avatar.png',
);

final uploadReq = UploadAvatarReq(
  variables: UploadAvatarVars(file: file),
);

final result = await client.future(uploadReq);
```

---

### 8. Request Cancellation with `CancelToken`

```dart
final cancelToken = CancelToken();

// Cancel request when user navigates away
void onDispose() {
  cancelToken.cancel('User navigated away');
}

try {
  final data = await client.future(myRequest, cancelToken: cancelToken);
} on RequestCancelledException catch (e) {
  print('Request cancelled: ${e.message}');
}
```

---

## 📚 Full Documentation

- [Client, Requests & ErrorPolicy](../../docs/mk_graphql/client-and-requests.md)
- [Normalized Cache & Optimistic UI](../../docs/mk_graphql/caching.md)
- [Link Pipeline (Auth, SSE, WS, Uploads)](../../docs/mk_graphql/links.md)
- [Pagination Guide](../../docs/mk_graphql/pagination.md)
- [Code Generator (`mk_graphql_generator`)](../../docs/mk_graphql_generator/getting-started.md)

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
