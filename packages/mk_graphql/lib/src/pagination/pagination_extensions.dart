import 'package:dio/dio.dart';

import '../client/client.dart';
import '../core/request.dart';
import 'paginator.dart';

/// Extension adding pagination factories to [GraphQLClient].
extension GraphQLClientPaginationExtension on GraphQLClient {
  /// Creates a reactive [GraphQLPaginator] for [initialRequest].
  GraphQLPaginator<TData, TVars, TItem> paginate<TData, TVars, TItem>({
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required NextVariablesCallback<TData, TVars> nextVariables,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator(
      client: this,
      initialRequest: initialRequest,
      getItems: getItems,
      nextVariables: nextVariables,
      mergeItems: mergeItems,
    );
  }

  /// Creates a reactive [GraphQLPaginator] using offset/limit pagination.
  GraphQLPaginator<TData, TVars, TItem> paginateOffset<TData, TVars, TItem>({
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int offset, int limit)
        updateOffset,
    int limit = 20,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator.offset(
      client: this,
      initialRequest: initialRequest,
      getItems: getItems,
      updateOffset: updateOffset,
      limit: limit,
      mergeItems: mergeItems,
    );
  }

  /// Creates a reactive [GraphQLPaginator] using page-number pagination.
  GraphQLPaginator<TData, TVars, TItem> paginatePage<TData, TVars, TItem>({
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int nextPage) updatePage,
    int initialPage = 1,
    int pageSize = 20,
    int? Function(TData data)? getPage,
    bool Function(TData data)? hasNextPage,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator.page(
      client: this,
      initialRequest: initialRequest,
      getItems: getItems,
      updatePage: updatePage,
      initialPage: initialPage,
      pageSize: pageSize,
      getPage: getPage,
      hasNextPage: hasNextPage,
      mergeItems: mergeItems,
    );
  }

  /// Creates a reactive [GraphQLPaginator] using Relay-style cursor pagination.
  GraphQLPaginator<TData, TVars, TItem> paginateCursor<TData, TVars, TItem>({
    required GraphQLRequest<TData, TVars> initialRequest,
    required ItemExtractor<TData, TItem> getItems,
    required String? Function(TData data) getEndCursor,
    required bool Function(TData data) getHasNextPage,
    required TVars Function(TVars currentVars, String cursor) updateCursor,
    ItemMerger<TItem>? mergeItems,
  }) {
    return GraphQLPaginator.cursor(
      client: this,
      initialRequest: initialRequest,
      getItems: getItems,
      getEndCursor: getEndCursor,
      getHasNextPage: getHasNextPage,
      updateCursor: updateCursor,
      mergeItems: mergeItems,
    );
  }
}

/// Extension adding direct execution, refetch, and pagination methods on [GraphQLRequest].
extension GraphQLRequestExecutionExtension<TData, TVars>
    on GraphQLRequest<TData, TVars> {
  /// Executes this request on [client] and returns a [Future] of [TData].
  Future<TData> execute(
    GraphQLClient client, {
    CancelToken? cancelToken,
  }) =>
      client.future(this, cancelToken: cancelToken);

  /// Refetches this request on [client] with [FetchPolicy.networkOnly].
  Future<TData> refetch(
    GraphQLClient client, {
    CancelToken? cancelToken,
  }) =>
      client.refetch(this, cancelToken: cancelToken);

  /// Fetches the next page of results for this request, automatically merging
  /// the items and updating the client cache under this request.
  Future<TData> fetchMore(
    GraphQLClient client, {
    required GraphQLRequest<TData, TVars> nextRequest,
    TData? previousData,
    TData Function(TData previousData, TData incomingData)? updateQuery,
    CancelToken? cancelToken,
  }) =>
      client.fetchMore(
        originalRequest: this,
        nextRequest: nextRequest,
        previousData: previousData,
        updateQuery: updateQuery,
        cancelToken: cancelToken,
      );

  /// Streams this request's responses on [client].
  Stream<TData> stream(
    GraphQLClient client, {
    CancelToken? cancelToken,
  }) =>
      client.stream(this, cancelToken: cancelToken);

  /// Watches this request in the client's cache.
  Stream<TData?> watch(GraphQLClient client) => client.watchQuery(this);

  /// Creates a paginator for this request.
  GraphQLPaginator<TData, TVars, TItem> paginate<TItem>({
    required GraphQLClient client,
    required ItemExtractor<TData, TItem> getItems,
    required NextVariablesCallback<TData, TVars> nextVariables,
    ItemMerger<TItem>? mergeItems,
  }) =>
      client.paginate(
        initialRequest: this,
        getItems: getItems,
        nextVariables: nextVariables,
        mergeItems: mergeItems,
      );

  /// Creates an offset/limit paginator for this request.
  GraphQLPaginator<TData, TVars, TItem> paginateOffset<TItem>({
    required GraphQLClient client,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int offset, int limit)
        updateOffset,
    int limit = 20,
    ItemMerger<TItem>? mergeItems,
  }) =>
      client.paginateOffset(
        initialRequest: this,
        getItems: getItems,
        updateOffset: updateOffset,
        limit: limit,
        mergeItems: mergeItems,
      );

  /// Creates a page-number paginator for this request.
  GraphQLPaginator<TData, TVars, TItem> paginatePage<TItem>({
    required GraphQLClient client,
    required ItemExtractor<TData, TItem> getItems,
    required TVars Function(TVars currentVars, int nextPage) updatePage,
    int initialPage = 1,
    int pageSize = 20,
    int? Function(TData data)? getPage,
    bool Function(TData data)? hasNextPage,
    ItemMerger<TItem>? mergeItems,
  }) =>
      client.paginatePage(
        initialRequest: this,
        getItems: getItems,
        updatePage: updatePage,
        initialPage: initialPage,
        pageSize: pageSize,
        getPage: getPage,
        hasNextPage: hasNextPage,
        mergeItems: mergeItems,
      );

  /// Creates a Relay cursor paginator for this request.
  GraphQLPaginator<TData, TVars, TItem> paginateCursor<TItem>({
    required GraphQLClient client,
    required ItemExtractor<TData, TItem> getItems,
    required String? Function(TData data) getEndCursor,
    required bool Function(TData data) getHasNextPage,
    required TVars Function(TVars currentVars, String cursor) updateCursor,
    ItemMerger<TItem>? mergeItems,
  }) =>
      client.paginateCursor(
        initialRequest: this,
        getItems: getItems,
        getEndCursor: getEndCursor,
        getHasNextPage: getHasNextPage,
        updateCursor: updateCursor,
        mergeItems: mergeItems,
      );
}
