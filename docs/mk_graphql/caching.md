# Caching

`GraphQLClient` delegates all cache reads/writes to a `Cache` implementation:

```dart
abstract class Cache {
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);
  void writeQuery<TData, TVars>(GraphQLRequest<TData, TVars> request, TData data);

  Map<String, dynamic>? readFragment({required String id, required String fragmentName});
  void writeFragment({required String id, required Map<String, dynamic> data});

  void evict(String key);
  void clear();

  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void recordOptimistic<TData, TVars>(GraphQLRequest<TData, TVars> request, TData data);
  void removeOptimistic(String requestId);

  /// When [request]'s result was last written to cache, or `null` if it has
  /// never been written (or was evicted since).
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request);

  /// Query keys whose operation name is in [operationNames] and/or whose
  /// cached result touched a `__typename` in [types].
  Iterable<String> matchingQueryKeys({List<String>? operationNames, List<String>? types});
}
```

`GraphQLClient(cache: ...)` accepts any implementation; omit it and an `InMemoryCache` is created for you.

## How `FetchPolicy` drives the cache

`request()` (and therefore `future`/`stream`) branches on the effective `FetchPolicy` (see [Client, Requests & Responses](client-and-requests.md#fetchpolicy)):

- `cacheOnly` → `cache.readQuery(req)`, nothing else.
- `cacheFirst` → `readQuery`; on a miss, fetch from network and `writeQuery` the result.
- `cacheAndNetwork` → emit `readQuery` immediately (if present, `loading: true`), then always fetch from network and `writeQuery`.
- `networkOnly` → fetch from network, `writeQuery` the result.
- `noCache` → fetch from network; cache is never read or written.

A successful network response is written to cache under all policies except `noCache`.

## Watching the cache

`client.watchQuery(req)` returns a `Stream<TData?>` that emits whenever the entry backing `req` changes in the cache — independent of whether *this* client call triggered the write. Use it to keep a widget in sync with writes made elsewhere (e.g. a mutation's response, or a subscription payload landing via `writeQuery`).

## Optimistic responses

Set `optimisticResponse` on a request:

```dart
final req = UpdatePostReq(
  variables: UpdatePostVars(id: postId, title: newTitle),
  optimisticResponse: UpdatePostModel(post: PostModel(id: postId, title: newTitle)),
);

await client.future(req);
```

Sequence:

1. `cache.recordOptimistic(req, req.optimisticResponse)` runs immediately, and a `GraphQLResponse` with `source: ResponseSource.optimistic, loading: true` is emitted synchronously — any `watchQuery` observers see it right away.
2. The real network request proceeds per the request's `FetchPolicy`.
3. Once the network call settles (success *or* failure), `cache.removeOptimistic(req.requestId)` runs, clearing the temporary entry.

`requestId` defaults to the request instance's identity hash, so distinct request *instances* get distinct optimistic slots even for the same operation+variables — pass an explicit `requestId` to `GraphQLRequest` if you need cross-instance coalescing.

## How `InMemoryCache` normalizes data

`InMemoryCache` is a genuinely normalized store, similar in spirit to Apollo Client's `InMemoryCache`:

- Each operation's result is written under a `ROOT_QUERY:<operationName>:<documentHash>:<variables>` record.
- Any nested object that looks like an entity — has `__typename` plus `id` or `_id` — is extracted into its own record keyed `Type:id` and replaced in its parent with a `{"__ref": "Type:id"}` reference. This extraction recurses through nested objects and lists.
- Reading denormalizes: refs are resolved back into their current record on every read, so **a write to one operation's result that touches a shared entity is immediately visible when reading or watching any other operation whose cached result references that same entity** — no manual invalidation needed for the common "mutation updates a field also shown elsewhere" case.
- Entity extraction depends on `__typename` being present in the response, which is why `TypenameLink` is enabled by default (`GraphQLClient(addTypename: true)`).
- Provide a custom `keyGetter` to `InMemoryCache(keyGetter: ...)` if your schema's identity field isn't `id`/`_id`, or if you need composite keys.

What it does *not* do: merge partial selections of the same entity into a superset (a record write replaces/merges shallowly at the top level via `RecordSource.set`, not a deep field-by-field reconciliation across differently-shaped selections), and it does not garbage-collect orphaned entity records — `evict(key)`/`clear()` are manual.

## Stale-while-revalidate

`GraphQLClient` tracks when each query was last written to cache (`Cache.writtenAt`) and uses it to decide whether a cache hit is still "fresh" or needs a background revalidation:

- `GraphQLClient(defaultStaleTime: ...)` — how long a cached entry is considered fresh. Defaults to `Duration.zero`.
- `GraphQLRequest.staleTime` — overrides `defaultStaleTime` for this request.
- `GraphQLClient(defaultCacheTime: ...)` / `GraphQLRequest.cacheTime` — how long a query's cache entry survives after its last active `watchQuery` subscriber cancels before being garbage-collected. Defaults to `null` (never GC — matches the pre-existing behavior).

**Default-is-stale (breaking behavior change):** because `defaultStaleTime` defaults to `Duration.zero`, every `FetchPolicy.cacheFirst` cache hit is considered stale as soon as it's read. The cached value is still returned instantly with no UI-visible delay, but the client *also* immediately kicks off a background network refetch to revalidate it — the same emission shape `cacheAndNetwork` has always had. An active `watchQuery` subscriber gets the same treatment: if the cached value is already stale when it attaches, a background refetch fires right away.

If your app relied on `cacheFirst` serving the cache forever and never re-hitting the network, set an explicit `staleTime` to opt back into that behavior:

```dart
// Never auto-revalidate this query once cached:
final req = GetUserReq(
  variables: GetUserVars(id: userId),
  staleTime: const Duration(days: 36500), // effectively "forever"
);

// Or set a client-wide default that's fresh for a reasonable window:
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  defaultStaleTime: const Duration(minutes: 5),
);
```

`cacheAndNetwork` is unchanged by this — it has always emitted the cache value then always fetched from network regardless of staleness; `staleTime` only affects whether `cacheFirst` short-circuits.

**GC (`cacheTime`)** only runs when set. With `cacheTime` unset (the default, on both the client and the request), a query's cache entry lives forever until explicitly evicted or invalidated — nothing changes there. Set `cacheTime` (client-wide via `defaultCacheTime`, or per-request) to have the entry evicted `cacheTime` after the last `watchQuery` subscriber cancels (canceled if a new subscriber attaches before the timer fires):

```dart
final client = GraphQLClient(
  url: 'https://api.example.com/graphql',
  defaultCacheTime: const Duration(minutes: 10),
);
```

## Query invalidation

`client.invalidateQueries({operationNames, types, refetchActive})` evicts cached queries matching an operation name and/or a `__typename` that appeared in their cached result, and — by default — refetches any of those queries that currently have an active `watchQuery` subscriber:

```dart
Future<void> invalidateQueries({
  List<String>? operationNames,
  List<String>? types,
  bool refetchActive = true,
});
```

A common use: after a mutation that adds/removes an item, invalidate the list query that displays that type so it picks up the change without manually threading a refetch through the UI:

```dart
await client.future(CreatePostReq(variables: CreatePostVars(title: title)));

// Any cached query whose result touched a `Post` gets evicted; a currently
// watched list query (e.g. GetPostsReq) is background-refetched in place.
await client.invalidateQueries(types: ['Post']);
```

Pass `operationNames: ['GetPosts']` instead (or in addition) to target by operation name rather than by type. A match with no active subscriber is simply evicted and refetched lazily on its next read — no wasted network call. Pass `refetchActive: false` to only evict, never background-refetch.

## Refetch triggers

Three ways to tell the client "re-run whatever's currently being watched":

- `client.notifyReconnected()` — call from your connectivity listener (e.g. [`connectivity_plus`](https://pub.dev/packages/connectivity_plus)) when the device regains network connectivity.
- `client.notifyAppResumed()` — call from your app-lifecycle observer when the app comes back to the foreground.
- `GraphQLRequest.refetchInterval` — a `Duration?` (default `null`) that, while the request has an active `watchQuery` subscriber, triggers a periodic background refetch; the timer is canceled once the last subscriber cancels.

Both `notifyReconnected`/`notifyAppResumed` only refetch queries that currently have at least one active `watchQuery` subscriber — nothing fires for queries nobody's watching.

```dart
class ConnectivityGraphQLBridge with WidgetsBindingObserver {
  ConnectivityGraphQLBridge(this._client) {
    WidgetsBinding.instance.addObserver(this);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        _client.notifyReconnected();
      }
    });
  }

  final GraphQLClient _client;
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _client.notifyAppResumed();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub.cancel();
  }
}
```

Poll a specific query every 30 seconds while it's on screen:

```dart
final req = GetLiveScoreReq(
  variables: GetLiveScoreVars(matchId: matchId),
  refetchInterval: const Duration(seconds: 30),
);

client.watchQuery(req).listen((data) => print(data));
```

## Persistent cache: `HiveCache`

`HiveCache` is a `Cache` implementation backed by [`hive_ce`](https://pub.dev/packages/hive_ce) that persists the normalized record store to disk, so it survives app restarts. It's a drop-in — every read/write still goes through a delegate `InMemoryCache` for speed; the Hive `Box` is only a durable mirror updated in the background after each mutation.

Hive must already be initialized by your app before calling `HiveCache.open(...)` — `mk_graphql` stays storage-path-agnostic, so it never calls `Hive.initFlutter()`/`Hive.init(path)` itself:

```dart
import 'package:hive_ce_flutter/hive_ce_flutter.dart'; // or plain hive_ce on non-Flutter targets

await Hive.initFlutter(); // or Hive.init(path) outside Flutter

final client = await GraphQLClient.create(
  url: 'https://api.example.com/graphql',
  cache: HiveCache.open(boxName: 'gql_cache'),
);
```

`HiveCache.open` requires `boxName`, hydrating a fresh in-memory cache from whatever the box already holds; `keyGetter` and `onPersistError` are optional, same roles as on `InMemoryCache`/elsewhere — `onPersistError` is called (never thrown) whenever a background write to the box fails, defaulting to a silent no-op so a disk error degrades to "cache is in-memory-only for this session" instead of crashing.

Write-through semantics: every mutating `Cache` call (`writeQuery`, `writeFragment`, `evict`, `evictQuery`, `clear`) updates the in-memory delegate synchronously, then schedules a debounced background export of the full record store to the box (multiple synchronous mutations in the same tick coalesce into a single disk write). Reads (`readQuery`, `watchQuery`, etc.) never touch the box directly.

**Optimistic writes are never persisted** — `recordOptimistic`/`removeOptimistic` only touch the in-memory delegate, by design, since an optimistic value is inherently temporary and shouldn't survive a restart.

Since `HiveCache.open` is asynchronous, build the client with the async `GraphQLClient.create({...})` factory instead of the synchronous `GraphQLClient(...)` constructor — see [Client, Requests & Responses](client-and-requests.md#graphqlclientcreate). `create` accepts `HiveCache.open(...)`'s `Future` directly, so there's no separate `await` needed for the cache itself.

`close()` is an instance method on the opened cache, not a static — so when you need to close the box, hold on to the `HiveCache` instead of letting `create` await it inline, and close it alongside `client.dispose()`:

```dart
final cache = await HiveCache.open(boxName: 'gql_cache');
final client = await GraphQLClient.create(
  url: 'https://api.example.com/graphql',
  cache: cache,
);

// ...later, e.g. in a widget's dispose():
await client.dispose();
await cache.close();
```

