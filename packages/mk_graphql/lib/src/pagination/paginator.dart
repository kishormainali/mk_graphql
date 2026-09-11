import 'dart:async';
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
  final ItemExtractor<TData, TItem> getItems;
  final NextVariablesCallback<TData, TVars> nextVariables;
  final ItemMerger<TItem> mergeItems;

  PaginationState<TItem> _state = const PaginationState();
  final StreamController<PaginationState<TItem>> _stateController =
      StreamController<PaginationState<TItem>>.broadcast();

  GraphQLRequest<TData, TVars>? _currentRequest;
  TData? _lastData;

  GraphQLPaginator({
    required this.client,
    required this.initialRequest,
    required this.getItems,
    required this.nextVariables,
    ItemMerger<TItem>? mergeItems,
  }) : mergeItems =
            mergeItems ?? ((current, incoming) => [...current, ...incoming]);

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
    ItemMerger<TItem>? mergeItems,
  }) {
    var currentPage = initialPage;
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
        if (items.length < pageSize) return null;
        currentPage++;
        return updatePage(currentVars, currentPage);
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

  /// Current list of loaded items.
  List<TItem> get items => _state.items;

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

  /// Fetches the initial page of items.
  Future<void> loadInitial({CancelToken? cancelToken}) async {
    if (_state.isLoading || _state.isLoadingMore) return;
    _emit(_state.copyWith(isLoading: true, error: null));
    _currentRequest = initialRequest;

    try {
      final data =
          await client.future(initialRequest, cancelToken: cancelToken);
      _lastData = data;
      final newItems = getItems(data);
      final hasMoreNext = nextVariables(
            lastData: data,
            currentVars: initialRequest.variables,
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
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, error: e));
    }
  }

  /// Fetches the subsequent page of items and merges them into [items].
  Future<void> loadNext({CancelToken? cancelToken}) async {
    if (_state.isLoading || _state.isLoadingMore || !_state.hasMore) return;
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
      return;
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
    } catch (e) {
      _emit(_state.copyWith(isLoadingMore: false, error: e));
    }
  }

  /// Refetches from page 1 using [FetchPolicy.networkOnly], resetting the pagination state.
  Future<void> refetch({CancelToken? cancelToken}) async {
    if (_state.isLoading) return;
    _emit(_state.copyWith(isLoading: true, error: null));

    final refreshReq =
        initialRequest.copyWithFetchPolicy(FetchPolicy.networkOnly);
    _currentRequest = refreshReq;

    try {
      final data = await client.future(refreshReq, cancelToken: cancelToken);
      _lastData = data;
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
    } catch (e) {
      _emit(_state.copyWith(isLoading: false, error: e));
    }
  }

  /// Closes the underlying broadcast stream.
  void dispose() {
    _stateController.close();
  }
}
