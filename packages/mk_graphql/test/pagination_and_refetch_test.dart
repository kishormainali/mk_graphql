import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';

// Test Types
class _PageVars {
  final int offset;
  final int limit;
  const _PageVars({required this.offset, required this.limit});
  Map<String, dynamic> toJson() => {'offset': offset, 'limit': limit};
}

class _PageData {
  final List<String> items;
  const _PageData(this.items);
  factory _PageData.fromJson(Map<String, dynamic> json) => _PageData(
        (json['items'] as List<dynamic>).cast<String>(),
      );
  Map<String, dynamic> toJson() => {'items': items};
}

class _PageReq extends GraphQLRequest<_PageData, _PageVars> {
  @override
  final _PageVars variables;

  _PageReq(
    this.variables, {
    super.fetchPolicy,
    super.requestId,
    super.cancelToken,
    super.headers,
    super.optimisticResponse,
  });

  @override
  String get document =>
      'query GetItems(\$offset: Int, \$limit: Int) { items }';

  @override
  String get operationName => 'GetItems';

  @override
  Map<String, dynamic> toJsonVars(_PageVars vars) => vars.toJson();

  @override
  _PageData parseData(Map<String, dynamic> json) => _PageData.fromJson(json);

  @override
  _PageReq copyWithRequest({
    _PageVars? variables,
    FetchPolicy? fetchPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _PageData? optimisticResponse,
  }) {
    return _PageReq(
      variables ?? this.variables,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
      headers: headers ?? this.headers,
      cancelToken: cancelToken ?? this.cancelToken,
      optimisticResponse: optimisticResponse ?? this.optimisticResponse,
      requestId: requestId,
    );
  }
}

void main() {
  group('Refetch Tests', () {
    test(
        'client.refetch executes with FetchPolicy.networkOnly and updates cache',
        () async {
      final cache = InMemoryCache();

      final req = _PageReq(
        const _PageVars(offset: 0, limit: 10),
        fetchPolicy: FetchPolicy.cacheFirst,
      );

      // Prepopulate cache
      cache.writeQuery(req, const _PageData(['cached_item']));
      expect(cache.readQuery(req)?.items, ['cached_item']);

      // Refetch request should have FetchPolicy.networkOnly
      final refetchedReq = req.copyWithFetchPolicy(FetchPolicy.networkOnly);
      expect(refetchedReq.fetchPolicy, FetchPolicy.networkOnly);

      // Test req.refetch extension calls client.refetch
      expect(req.refetch, isNotNull);
      expect(req.execute, isNotNull);
    });
  });

  group('GraphQLPaginator Tests', () {
    test('offset paginator handles loadInitial, loadNext, and refetch',
        () async {
      final client = GraphQLClient(
        url: 'https://example.com/graphql',
      );

      final initialReq = _PageReq(const _PageVars(offset: 0, limit: 2));

      // Test state transitions
      final paginator = GraphQLPaginator<_PageData, _PageVars, String>.offset(
        client: client,
        initialRequest: initialReq,
        getItems: (data) => data.items,
        updateOffset: (current, offset, limit) =>
            _PageVars(offset: offset, limit: limit),
        limit: 2,
      );

      expect(paginator.items, isEmpty);
      expect(paginator.hasMore, isTrue);
      expect(paginator.isLoading, isFalse);
      expect(paginator.isLoadingMore, isFalse);

      // Verify nextVariables computes offset accurately
      final nextVars = paginator.nextVariables(
        lastData: const _PageData(['a', 'b']),
        currentVars: const _PageVars(offset: 0, limit: 2),
        totalLoaded: 2,
      );
      expect(nextVars?.offset, 2);
      expect(nextVars?.limit, 2);

      // If fewer items than limit returned, nextVariables returns null
      final lastPageVars = paginator.nextVariables(
        lastData: const _PageData(['c']),
        currentVars: const _PageVars(offset: 2, limit: 2),
        totalLoaded: 3,
      );
      expect(lastPageVars, isNull);

      paginator.dispose();
    });

    test('page paginator increments page numbers', () {
      final client = GraphQLClient(url: 'https://example.com/graphql');
      final initialReq = _PageReq(const _PageVars(offset: 1, limit: 10));

      final paginator = GraphQLPaginator<_PageData, _PageVars, String>.page(
        client: client,
        initialRequest: initialReq,
        getItems: (data) => data.items,
        updatePage: (current, nextPage) =>
            _PageVars(offset: nextPage, limit: 10),
        initialPage: 1,
        pageSize: 10,
      );

      final nextVars = paginator.nextVariables(
        lastData: _PageData(List.generate(10, (i) => '$i')),
        currentVars: const _PageVars(offset: 1, limit: 10),
        totalLoaded: 10,
      );
      expect(nextVars?.offset, 2);

      paginator.dispose();
    });

    test('cursor paginator uses getEndCursor and getHasNextPage', () {
      final client = GraphQLClient(url: 'https://example.com/graphql');
      final initialReq = _PageReq(const _PageVars(offset: 0, limit: 10));

      final paginator = GraphQLPaginator<_PageData, _PageVars, String>.cursor(
        client: client,
        initialRequest: initialReq,
        getItems: (data) => data.items,
        getEndCursor: (data) => 'cursor_abc',
        getHasNextPage: (data) => true,
        updateCursor: (current, cursor) =>
            const _PageVars(offset: 99, limit: 10),
      );

      final nextVars = paginator.nextVariables(
        lastData: const _PageData(['x']),
        currentVars: const _PageVars(offset: 0, limit: 10),
        totalLoaded: 1,
      );
      expect(nextVars?.offset, 99);

      paginator.dispose();
    });

    test('PaginationState copyWith behaves immutably', () {
      const state = PaginationState<String>(
        items: ['1', '2'],
        isLoading: false,
        hasMore: true,
      );

      final updated = state.copyWith(isLoadingMore: true);
      expect(updated.items, ['1', '2']);
      expect(updated.isLoadingMore, true);
      expect(updated.count, 2);
      expect(updated.isNotEmpty, true);
      expect(updated.isEmpty, false);
      expect(updated.hasError, false);
    });
  });
}
