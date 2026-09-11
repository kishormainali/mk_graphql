# mk_graphql — Getting Started

`mk_graphql` is the runtime GraphQL client. It executes typed `GraphQLRequest`s (normally produced by [`mk_graphql_generator`](../mk_graphql_generator/getting-started.md)), manages a normalized cache, and composes a link pipeline for auth, logging, HTTP, SSE, and WebSocket transports.

## Install

```yaml
dependencies:
  mk_graphql: ^1.0.0
```

```bash
flutter pub get
```

You'll almost always pair this with the generator, so also see [mk_graphql_generator: Getting Started](../mk_graphql_generator/getting-started.md) unless you intend to hand-write `GraphQLRequest` subclasses.

## Create a client

```dart
import 'package:mk_graphql/mk_graphql.dart';

final client = GraphQLClient(
  url: 'https://api.example.com/graphql',

  // Optional: WebSocket or SSE endpoint for subscriptions.
  wsUrl: 'wss://api.example.com/graphql',
  // sseUrl: 'https://api.example.com/graphql/sse',

  // Optional: auth headers attached to every request.
  tokenHeader: () async {
    final token = await getStoredToken();
    return token != null ? {'Authorization': 'Bearer $token'} : {};
  },

  // Optional: called on a 401 to refresh and retry once.
  onTokenRefresh: (refreshLink) async {
    final newToken = await refreshUserToken();
    return newToken != null ? {'Authorization': 'Bearer $newToken'} : null;
  },

  // Optional: default policy applied when a request doesn't set its own.
  defaultFetchPolicy: FetchPolicy.cacheFirst,
);
```

`GraphQLClient` internally builds this pipeline (skipping any stage whose inputs weren't provided):

```
AuthLink?  →  TypenameLink?  →  LoggerLink  →  split(subscription?, WebSocketLink|SseLink, DioLink)
```

See [Link Pipeline](links.md) for what each stage does and how to replace pieces of it.

## Run a query

Given a generated request (see the generator docs for how `GetUserReq`/`GetUserVars` come to exist):

```dart
final user = await client.future(
  GetUserReq(variables: const GetUserVars(id: '123')),
);
```

`future` throws a typed `GraphQLException` subclass on any error — see [Error Handling](client-and-requests.md#errors) — so a plain `try`/`catch` is all you need:

```dart
try {
  final user = await client.future(GetUserReq(variables: const GetUserVars(id: '123')));
} on UnAuthorizedException {
  // redirect to login
} on GraphQLException catch (e) {
  showError(e.message);
}
```

## Stream a query or subscription

```dart
client.stream(mySubscriptionRequest).listen((data) {
  print('Real-time event: $data');
});
```

`stream` is also how you observe policy-driven emissions (e.g. `FetchPolicy.cacheAndNetwork` emits the cached value first, then the network value).

## Next

- [Client, Requests & Responses](client-and-requests.md) — the full API surface, `FetchPolicy`, cancellation, optimistic responses.
- [Caching](caching.md) — how `readQuery`/`writeQuery`/`watchQuery` work.
- [Pagination](pagination.md) — `GraphQLPaginator` for infinite lists.
- [Link Pipeline](links.md) — auth refresh, logging, uploads, batching.
