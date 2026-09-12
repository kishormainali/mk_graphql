# Pagination

`mk_graphql` provides first-class, automatic pagination support. Developers never have to manually manage list concatenation (`[...oldItems, ...newItems]`) across pages.

Two mechanisms are available:
1. **`client.fetchMore` / `req.fetchMore`**: Apollo-style fetch-more that automatically deep-merges response JSON trees and updates the normalized cache.
2. **`GraphQLPaginator<TData, TVars, TItem>`**: A reactive state manager for infinite scroll with loading state, errors, cancellation, and direct list returns.

---

## 1. `client.fetchMore` & `req.fetchMore`

`fetchMore` executes a subsequent page query with `FetchPolicy.networkOnly`, automatically combines the results with previously loaded data, updates the cache under `originalRequest`, and returns the merged result.

### Automatic Deep Merging

When `updateQuery` is omitted, `autoMergeGraphQLData` automatically:
- Concatenates matching `List` fields (e.g. `items: [...]`, `countries: [...]`, `edges: [...]`).
- Recursively merges nested Maps (e.g. Relay connection patterns `{ edges: [...], pageInfo: {...} }`), appending `edges` and updating `pageInfo` metadata.
- Updates scalar page metadata.

```dart
final page1Req = GetCountriesReq(
  variables: const GetCountriesVars(offset: 0, limit: 10),
);

// 1. Initial fetch
final page1Data = await client.future(page1Req);

// 2. Fetch next page (automatically combines page 1 + page 2)
final page2Req = GetCountriesReq(
  variables: const GetCountriesVars(offset: 10, limit: 10),
);

final mergedData = await client.fetchMore(
  originalRequest: page1Req,
  nextRequest: page2Req,
);

print('Total countries: ${mergedData.countries.length}'); // 20
```

### Direct Request Extension

```dart
final mergedData = await page1Req.fetchMore(
  client,
  nextRequest: page2Req,
);
```

### Cache Synchronization

`fetchMore` writes the merged data to the cache under `originalRequest`. Any active watchers listening to `client.watchQuery(originalRequest)` or `originalRequest.watch(client)` automatically emit the updated, combined dataset:

```dart
client.watchQuery(page1Req).listen((data) {
  print('Watcher received updated count: ${data?.countries.length}');
});
```

### Custom `updateQuery` Callback

If custom merging rules or deduplication is required:

```dart
final mergedData = await client.fetchMore(
  originalRequest: page1Req,
  nextRequest: page2Req,
  updateQuery: (previousData, incomingData) {
    return previousData.copyWith(
      countries: [
        ...previousData.countries,
        ...incomingData.countries,
      ],
    );
  },
);
```

---

## 2. `GraphQLPaginator`

`GraphQLPaginator<TData, TVars, TItem>` wraps an initial request and manages pagination state, caching, and item accumulation for UI widgets.

### Factories

#### Offset / Limit Pagination

```dart
final paginator = client.paginateOffset(
  initialRequest: GetCountriesReq(variables: const GetCountriesVars(offset: 0, limit: 20)),
  getItems: (data) => data.countries,
  updateOffset: (vars, offset, limit) => vars.copyWith(offset: offset, limit: limit),
  limit: 20,
);
```
Stops when a page returns fewer than `limit` items.

#### Page Number Pagination

```dart
final paginator = client.paginatePage(
  initialRequest: GetAnimePageReq(variables: const GetAnimePageVars(page: 1, perPage: 20)),
  getItems: (data) => data.page?.media ?? [],
  updatePage: (vars, nextPage) => vars.copyWith(page: nextPage),
  initialPage: 1,
  pageSize: 20,
  getPage: (data) => data.page?.pageInfo?.currentPage,
  hasNextPage: (data) => data.page?.pageInfo?.hasNextPage ?? false,
);
```
Stops when `hasNextPage` returns `false` or a page returns fewer than `pageSize` items. Can automatically derive the next page number from `getPage(data) + 1` or accumulated item count.

#### Relay-Style Cursor Pagination

```dart
final paginator = client.paginateCursor(
  initialRequest: GetFeedReq(variables: const GetFeedVars()),
  getItems: (data) => data.feed.edges.map((e) => e.node).toList(),
  getEndCursor: (data) => data.feed.pageInfo.endCursor,
  getHasNextPage: (data) => data.feed.pageInfo.hasNextPage,
  updateCursor: (vars, cursor) => vars.copyWith(after: cursor),
);
```
Stops when `getHasNextPage` returns `false` or `getEndCursor` is null or empty.

---

## `GraphQLPaginator` API

### Methods

| Method | Returns | Behavior |
|---|---|---|
| `loadInitial({cancelToken})` | `Future<List<TItem>>` | Fetches the first page and returns items. |
| `loadNext({cancelToken})` | `Future<List<TItem>>` | Fetches the next page, persists active filter/query variables, merges items, syncs cache under `initialRequest`, and returns the complete accumulated list. |
| `applyVariables(updateFn, {cancelToken})` | `Future<List<TItem>>` | Dynamically updates variables (e.g. search, filters, sorting), updates the base request on page 1, and fetches the new results without tearing down streams or resetting other active criteria. |
| `updateVariables(newVariables, {cancelToken})` | `Future<List<TItem>>` | Replaces variables on page 1 and fetches new results. |
| `refetch({cancelToken})` | `Future<List<TItem>>` | Restores the query back to `initialRequest` (resetting applied search/filters to default), fetches page 1 with `FetchPolicy.networkOnly`, and resets pagination state. |
| `loadAll({maxPages = 100})` | `Future<List<TItem>>` | Continuously fetches subsequent pages until `hasMore` is `false` or `maxPages` is reached. |
| `dispose()` | `void` | Closes internal streams and controllers. |

### Filter & Search Lifecycle: Reset vs Persistence
- **`applyVariables(...)` / `updateVariables(...)`**: Use when users type into a search bar or toggle a filter chip. Only the modified fields change; existing filter values and sort selections are preserved. Page is reset to 1 to show the new query results.
- **`loadNext(...)` (Infinite Scroll)**: Persists all current filter, search, and sort variables, requesting `page + 1` and accumulating newly loaded items into `items`.
- **`refetch(...)` (Pull to Refresh)**: Restores `_baseRequest = initialRequest`, clearing transient filters and search queries to restore the default initial view.


### Properties & Streams

| Property / Getter | Type | Description |
|---|---|---|
| `items` | `List<TItem>` | Current list of accumulated items across all loaded pages. |
| `accumulatedData` | `TData?` | Typed `TData` response containing merged pages. |
| `itemsStream` | `Stream<List<TItem>>` | Stream emitting only the accumulated items list whenever it changes, filtered via `ListEquality`. |
| `state` | `PaginationState<TItem>` | Current immutable snapshot (`items`, `isLoading`, `isLoadingMore`, `hasMore`, `error`). |
| `stream` | `Stream<PaginationState<TItem>>` | Stream emitting `PaginationState` updates. |
| `isLoading` | `bool` | True when initial page or refetch is in flight. |
| `isLoadingMore` | `bool` | True when a subsequent page is loading. |
| `hasMore` | `bool` | True if more pages can be requested. |

---

## Flutter UI Integration Example

```dart
class CountriesListView extends StatefulWidget {
  final GraphQLClient client;
  const CountriesListView({super.key, required this.client});

  @override
  State<CountriesListView> createState() => _CountriesListViewState();
}

class _CountriesListViewState extends State<CountriesListView> {
  late final GraphQLPaginator<GetCountriesModel, GetCountriesVars, CountryPartialModel> _paginator;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _paginator = widget.client.paginateOffset(
      initialRequest: GetCountriesReq(
        variables: const GetCountriesVars(offset: 0, limit: 20),
      ),
      getItems: (data) => data.countries,
      updateOffset: (vars, offset, limit) => vars.copyWith(offset: offset, limit: limit),
      limit: 20,
    );

    _scrollController.addListener(_onScroll);
    _paginator.loadInitial();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (_paginator.hasMore && !_paginator.isLoadingMore) {
        _paginator.loadNext();
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _paginator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PaginationState<CountryPartialModel>>(
      stream: _paginator.stream,
      initialData: _paginator.state,
      builder: (context, snapshot) {
        final state = snapshot.data!;

        if (state.isLoading && state.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (state.hasError && state.isEmpty) {
          return Center(child: Text('Error: ${state.error}'));
        }

        return RefreshIndicator(
          onRefresh: () => _paginator.refetch(),
          child: ListView.builder(
            controller: _scrollController,
            itemCount: state.count + (state.hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index == state.count) {
                return const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final country = state.items[index];
              return ListTile(
                leading: Text(country.emoji),
                title: Text(country.name),
                subtitle: Text(country.capital ?? 'No capital'),
              );
            },
          ),
        );
      },
    );
  }
}
```

---

## Flutter BLoC Integration (`emit.forEach`)

The recommended pattern for `flutter_bloc` is connecting the paginator's stream directly via `emit.forEach<PaginationState<TItem>>`. This automatically handles stream subscription lifecycle, cancellation, and updates without manual listener disposal:

```dart
class AnimeListBloc extends Bloc<AnimeListEvent, AnimeListState> {
  final GraphQLPaginator<GetAnimePageModel, GetAnimePageVars, MediaPartialModel> _paginator;

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
      _paginator.applyVariables((vars) => vars.copyWith(search: event.query));
    });

    on<GenreChanged>((event, emit) {
      _paginator.applyVariables((vars) => vars.copyWith(genre: event.genre));
    });

    on<FetchNextPage>((event, emit) => _paginator.loadNext());
    on<Refreshed>((event, emit) => _paginator.refetch());
  }

  @override
  Future<void> close() {
    _paginator.dispose();
    return super.close();
  }
}
```

