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

