import 'dart:async';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';

import '../client/client.dart';
import '../core/fetch_policy.dart';
import '../core/request.dart';
import 'pagination_state.dart';

/// Callback computing the next page's typed variables.
/// Return `null` when there are no more pages.
typedef NextVariablesCallback<TData, TVars> = TVars? Function({
  required TData lastData,
  required TVars currentVars,
  required int totalLoaded,
});

/// Extracts the list of items from a query response.
typedef ItemExtractor<TData, TItem> = List<TItem> Function(TData data);

/// Merges existing items with newly fetched items. Defaults to appending.
typedef ItemMerger<TItem> = List<TItem> Function(
  List<TItem> current,
  List<TItem> incoming,
);

/// A reactive pagination manager that executes GraphQL queries and accumulates items.
///
/// Supports offset/limit, page/pageSize, and Relay-style cursor connections.
class GraphQLPaginator<TData, TVars, TItem> {
  final GraphQLClient client;
  final GraphQLRequest<TData, TVars> initialRequest;
  late GraphQLRequest<TData, TVars> _baseRequest;
  final ItemExtractor<TData, TItem> getItems;
  final NextVariablesCallback<TData, TVars> nextVariables;
  final ItemMerger<TItem> mergeItems;

  PaginationState<TItem> _state = const PaginationState();
  final StreamController<PaginationState<TItem>> _stateController =
      StreamController<PaginationState<TItem>>.broadcast();

  GraphQLRequest<TData, TVars>? _currentRequest;
  TData? _lastData;
  TData? _accumulatedData;

  GraphQLPaginator({
    required this.client,
    required this.initialRequest,
    required this.getItems,
    required this.nextVariables,
    ItemMerger<TItem>? mergeItems,
  })  : _baseRequest = initialRequest,
        mergeItems =
            mergeItems ?? ((current, incoming) => [...current, ...incoming]);

  /// The active base request currently in use by the paginator.
  GraphQLRequest<TData, TVars> get baseRequest => _baseRequest;

  /// The active variables on the base request (reflecting any applied filters or search queries).
  TVars get currentVariables => _baseRequest.variables;

  /// Factory for standard offset/limit pagination.
  factory GraphQLPaginator.offset({
    required GraphQLClient client,
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int offset, int limit)
        updateOffset,
    int limit = 20,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator(
      client: client,
      initialRequest: initialRequest,
      getItems: getItems,
      nextVariables: ({
        required lastData,
        required currentVars,
        required totalLoaded,
      }) {
        final items = getItems(lastData);
        if (items.length < limit) return null;
        return updateOffset(currentVars, totalLoaded, limit);
      },
      mergeItems: mergeItems,
    );
  }

  /// Factory for page-number based pagination (e.g. page 1, 2, 3...).
  factory GraphQLPaginator.page({
    required GraphQLClient client,
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int nextPage) updatePage,
    int initialPage = 1,
    int pageSize = 20,
    int? Function(TData data)? getPage,
    bool Function(TData data)? hasNextPage,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator(
      client: client,
      initialRequest: initialRequest,
      getItems: getItems,
      nextVariables: ({
        required lastData,
        required currentVars,
        required totalLoaded,
      }) {
        if (hasNextPage != null) {
          if (!hasNextPage(lastData)) return null;
        } else {
          final items = getItems(lastData);
          if (items.length < pageSize) return null;
        }
        final currentPage = getPage?.call(lastData);
        final nextPage = currentPage != null
            ? currentPage + 1
            : initialPage +
                (totalLoaded <= 0 ? 1 : (totalLoaded / pageSize).ceil());
        return updatePage(currentVars, nextPage);
      },
      mergeItems: mergeItems,
    );
  }

  /// Factory for Relay-style cursor-based connection pagination.
  factory GraphQLPaginator.cursor({
    required GraphQLClient client,
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required String? Function(TData data) getEndCursor,
    required bool Function(TData data) getHasNextPage,
    required TVars Function(TVars currentVars, String cursor) updateCursor,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator(
      client: client,
      initialRequest: initialRequest,
      getItems: getItems,
      nextVariables: ({
        required lastData,
        required currentVars,
        required totalLoaded,
      }) {
        if (!getHasNextPage(lastData)) return null;
        final cursor = getEndCursor(lastData);
        if (cursor == null || cursor.isEmpty) return null;
        return updateCursor(currentVars, cursor);
      },
      mergeItems: mergeItems,
    );
  }

  /// Current snapshot of the paginated state.
  PaginationState<TItem> get state => _state;

  /// Broadcast stream emitting state updates on loading, success, or error.
  Stream<PaginationState<TItem>> get stream => _stateController.stream;

  /// Stream emitting only the accumulated items list whenever it changes.
  Stream<List<TItem>> get itemsStream =>
      _stateController.stream.map((s) => s.items).distinct(
            const ListEquality<dynamic>().equals,
          );

  /// Current list of loaded items.
  List<TItem> get items => _state.items;

  /// Accumulated query data containing merged pages.
  TData? get accumulatedData => _accumulatedData;

  /// True when the first page or a refetch is in progress.
  bool get isLoading => _state.isLoading;

  /// True when loading the next page.
  bool get isLoadingMore => _state.isLoadingMore;

  /// True when more pages can be requested.
  bool get hasMore => _state.hasMore;

  void _emit(PaginationState<TItem> newState) {
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  /// Fetches the initial page of items and returns the accumulated [items].
  Future<List<TItem>> loadInitial({CancelToken? cancelToken}) async {
    if (_state.isLoading || _state.isLoadingMore) return _state.items;
    _emit(_state.copyWith(isLoading: true, error: null));
    _currentRequest = _baseRequest;

    try {
      final data = await client.future(_baseRequest, cancelToken: cancelToken);
      _lastData = data;
      _accumulatedData = data;
      final newItems = getItems(data);
      final hasMoreNext = nextVariables(
            lastData: data,
            currentVars: _baseRequest.variables,
            totalLoaded: newItems.length,
          ) !=
          null;

      _emit(PaginationState<TItem>(
        items: newItems,
        isLoading: false,
        isLoadingMore: false,
        hasMore: hasMoreNext,
        error: null,
      ));
      return newItems;
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, error: e));
      return _state.items;
    }
  }

  /// Fetches the subsequent page of items, automatically merges them into [items],
  /// updates [accumulatedData] and the cache under [baseRequest],
  /// and returns the updated accumulated [items].
  Future<List<TItem>> loadNext({CancelToken? cancelToken}) async {
    if (_state.isLoading || _state.isLoadingMore || !_state.hasMore) {
      return _state.items;
    }
    if (_lastData == null || _currentRequest == null) {
      return loadInitial(cancelToken: cancelToken);
    }

    final nextVars = nextVariables(
      lastData: _lastData!,
      currentVars: _currentRequest!.variables,
      totalLoaded: _state.items.length,
    );

    if (nextVars == null) {
      _emit(_state.copyWith(hasMore: false));
      return _state.items;
    }

    _emit(_state.copyWith(isLoadingMore: true, error: null));

    final nextReq = _currentRequest!.copyWithRequest(
      variables: nextVars,
      fetchPolicy: FetchPolicy.networkOnly,
    );
    _currentRequest = nextReq;

    try {
      final data = await client.future(nextReq, cancelToken: cancelToken);
      _lastData = data;
      if (_accumulatedData != null) {
        _accumulatedData = autoMergeGraphQLData(
          _baseRequest,
          _accumulatedData as TData,
          data,
        );
        client.cache.writeQuery(_baseRequest, _accumulatedData as TData);
      } else {
        _accumulatedData = data;
      }

      final incoming = getItems(data);
      final merged = mergeItems(_state.items, incoming);
      final hasMoreNext = incoming.isNotEmpty &&
          nextVariables(
                lastData: data,
                currentVars: nextVars,
                totalLoaded: merged.length,
              ) !=
              null;

      _emit(PaginationState<TItem>(
        items: merged,
        isLoading: false,
        isLoadingMore: false,
        hasMore: hasMoreNext,
        error: null,
      ));
      return merged;
    } catch (e) {
      _emit(_state.copyWith(isLoadingMore: false, error: e));
      return _state.items;
    }
  }

  /// Refetches from page 1 using [FetchPolicy.networkOnly], resetting pagination
  /// back to [initialRequest] (clearing temporary search/filters) and returning the refreshed [items].
  Future<List<TItem>> refetch({CancelToken? cancelToken}) async {
    if (_state.isLoading) return _state.items;
    _emit(_state.copyWith(isLoading: true, error: null));

    final refreshReq =
        initialRequest.copyWithFetchPolicy(FetchPolicy.networkOnly);
    _baseRequest = initialRequest;
    _currentRequest = refreshReq;

    try {
      final data = await client.future(refreshReq, cancelToken: cancelToken);
      _lastData = data;
      _accumulatedData = data;
      final newItems = getItems(data);
      final hasMoreNext = nextVariables(
            lastData: data,
            currentVars: refreshReq.variables,
            totalLoaded: newItems.length,
          ) !=
          null;

      _emit(PaginationState<TItem>(
        items: newItems,
        isLoading: false,
        isLoadingMore: false,
        hasMore: hasMoreNext,
        error: null,
      ));
      return newItems;
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, error: e));
      return _state.items;
    }
  }

  /// Updates the base request (e.g. for searching or filtering), resets pagination
  /// back to page 1, and fetches the new results.
  ///
  /// By default [clearItems] is true to immediately clear the list while loading the new results.
  /// If set to false, previous items remain visible with [isLoading: true] until new data arrives.
  Future<List<TItem>> updateRequest(
    GraphQLRequest<TData, TVars> newRequest, {
    bool clearItems = true,
    CancelToken? cancelToken,
  }) async {
    _baseRequest = newRequest;
    _currentRequest = newRequest;
    _lastData = null;
    _accumulatedData = null;

    _emit(PaginationState<TItem>(
      items: clearItems ? [] : _state.items,
      isLoading: true,
      isLoadingMore: false,
      hasMore: false,
      error: null,
    ));

    try {
      final data = await client.future(newRequest, cancelToken: cancelToken);
      _lastData = data;
      _accumulatedData = data;
      final newItems = getItems(data);
      final hasMoreNext = nextVariables(
            lastData: data,
            currentVars: newRequest.variables,
            totalLoaded: newItems.length,
          ) !=
          null;

      _emit(PaginationState<TItem>(
        items: newItems,
        isLoading: false,
        isLoadingMore: false,
        hasMore: hasMoreNext,
        error: null,
      ));
      return newItems;
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, error: e));
      return _state.items;
    }
  }

  /// Updates the variables on the base request (for searching, sorting, or filtering)
  /// and fetches page 1 with the new variables applied.
  Future<List<TItem>> updateVariables(
    TVars Function(TVars currentVars) update, {
    bool clearItems = true,
    FetchPolicy? fetchPolicy,
    CancelToken? cancelToken,
  }) {
    final newVars = update(_baseRequest.variables);
    final newReq = _baseRequest.copyWithRequest(
      variables: newVars,
      fetchPolicy: fetchPolicy ?? _baseRequest.fetchPolicy,
    );
    return updateRequest(newReq,
        clearItems: clearItems, cancelToken: cancelToken);
  }

  /// Sets new variables on the base request and fetches page 1 with the new variables.
  Future<List<TItem>> applyVariables(
    TVars newVariables, {
    bool clearItems = true,
    FetchPolicy? fetchPolicy,
    CancelToken? cancelToken,
  }) {
    final newReq = _baseRequest.copyWithRequest(
      variables: newVariables,
      fetchPolicy: fetchPolicy ?? _baseRequest.fetchPolicy,
    );
    return updateRequest(newReq,
        clearItems: clearItems, cancelToken: cancelToken);
  }

  /// Fetches all remaining pages until [hasMore] is false or [maxPages] is reached.
  ///
  /// Returns the complete accumulated list of [items].
  Future<List<TItem>> loadAll({
    int maxPages = 100,
    CancelToken? cancelToken,
  }) async {
    if (_state.items.isEmpty && !_state.isLoading) {
      await loadInitial(cancelToken: cancelToken);
    }
    var pagesCount = 1;
    while (hasMore && pagesCount < maxPages && !_state.hasError) {
      final prevCount = _state.items.length;
      await loadNext(cancelToken: cancelToken);
      if (_state.items.length == prevCount) {
        break; // Guard against infinite loop if page yields 0 new items
      }
      pagesCount++;
    }
    return items;
  }

  /// Closes the underlying broadcast stream.
  void dispose() {
    _stateController.close();
  }
}
