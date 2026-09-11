# Pagination

`GraphQLPaginator<TData, TVars, TItem>` wraps an initial `GraphQLRequest` and repeatedly fetches subsequent pages, accumulating items and exposing a reactive `PaginationState<TItem>`.

## Creating a paginator

Three factories cover the common pagination styles; there's also a fully generic constructor.

### Offset / limit

```dart
final paginator = client.paginateOffset(
  initialRequest: GetPostsReq(variables: GetPostsVars(offset: 0, limit: 20)),
  getItems: (data) => data.posts,
  updateOffset: (vars, offset, limit) => vars.copyWith(offset: offset, limit: limit),
  limit: 20,
);
```

Stops when a page returns fewer than `limit` items.

### Page number

```dart
final paginator = client.paginatePage(
  initialRequest: GetPostsReq(variables: GetPostsVars(page: 1, pageSize: 20)),
  getItems: (data) => data.posts,
  updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
  initialPage: 1,
  pageSize: 20,
);
```

Stops when a page returns fewer than `pageSize` items.

### Relay-style cursor

```dart
final paginator = client.paginateCursor(
  initialRequest: GetPostsReq(variables: const GetPostsVars()),
  getItems: (data) => data.posts.edges.map((e) => e.node).toList(),
  getEndCursor: (data) => data.posts.pageInfo.endCursor,
  getHasNextPage: (data) => data.posts.pageInfo.hasNextPage,
  updateCursor: (vars, cursor) => vars.copyWith(after: cursor),
);
```

Stops when `getHasNextPage` returns `false` or `getEndCursor` returns null/empty.

### Fully custom

```dart
final paginator = client.paginate(
  initialRequest: myRequest,
  getItems: (data) => data.items,
  nextVariables: ({required lastData, required currentVars, required totalLoaded}) {
    // return null to signal "no more pages"
    return hasMore(lastData) ? currentVars.copyWith(cursor: nextCursor(lastData)) : null;
  },
);
```

These are also available as extensions directly on a `GraphQLRequest`: `request.paginateOffset(client: client, ...)`, etc. — see `GraphQLRequestExecutionExtension` in `pagination_extensions.dart`.

### Custom merge strategy

By default new items are appended (`[...current, ...incoming]`). Override with `mergeItems` — e.g. to de-duplicate by id:

```dart
client.paginateOffset(
  ...,
  mergeItems: (current, incoming) => {
    for (final item in [...current, ...incoming]) item.id: item,
  }.values.toList(),
);
```

## Driving the UI

```dart
final paginator = client.paginateOffset(...);

paginator.stream.listen((state) {
  setState(() {}); // or feed a Bloc/Riverpod notifier
});

await paginator.loadInitial();

// On scroll-to-bottom:
if (paginator.hasMore && !paginator.isLoadingMore) {
  await paginator.loadNext();
}
```

`PaginationState<TItem>`:

| Field | Meaning |
|---|---|
| `items` | Accumulated items across all loaded pages. |
| `isLoading` | Initial load or `refetch()` in flight. |
| `isLoadingMore` | A `loadNext()` call in flight. |
| `hasMore` | Whether another `loadNext()` call would fetch anything. |
| `error` / `hasError` | The error from the last failed fetch, if any. |
| `isEmpty` / `isNotEmpty` / `count` | Convenience derived getters. |

`GraphQLPaginator` also exposes `state`, `items`, `isLoading`, `isLoadingMore`, `hasMore` directly as shorthand for `stream`'s latest value, so simple UIs don't need to hold their own copy of the state.

## Methods

| Method | Behavior |
|---|---|
| `loadInitial({cancelToken})` | Fetches the first page. No-op if already loading. |
| `loadNext({cancelToken})` | Fetches the next page using `nextVariables`/the relevant factory's update callback, and merges via `mergeItems`. Falls back to `loadInitial` if called before any page has loaded. No-op if `hasMore` is false or a fetch is already in flight. |
| `refetch({cancelToken})` | Re-fetches the *first* page with `FetchPolicy.networkOnly`, resetting accumulated state (not an in-place merge). |
| `dispose()` | Closes the internal state stream. Call this when the paginator is no longer needed (e.g. in a widget's `dispose()`). |

Every fetch uses `client.future(...)` under the hood — `loadNext`/`refetch` force `FetchPolicy.networkOnly` so paging never silently serves stale cached pages.
