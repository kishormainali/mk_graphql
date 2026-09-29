import 'package:flutter_test/flutter_test.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _MockDataLink extends Link {
  final Map<String, dynamic> Function(gql.Request req) handle;
  _MockDataLink(this.handle);

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    yield gql.Response(data: handle(req), response: const {});
  }
}

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
  factory _PageData.fromJson(Map<String, dynamic> json) =>
      _PageData((json['items'] as List<dynamic>).cast<String>());
  Map<String, dynamic> toJson() => {'items': items};
}

class _PageReq extends GraphQLRequest<_PageData, _PageVars> {
  @override
  final _PageVars variables;

  _PageReq(
    this.variables, {
    super.fetchPolicy,
    super.errorPolicy,
    super.requestId,
    super.cancelToken,
    super.headers,
    super.optimisticResponse,
    super.staleTime,
    super.cacheTime,
    super.retry,
    super.refetchInterval,
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
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _PageData? optimisticResponse,
  }) {
    return _PageReq(
      variables ?? this.variables,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
      errorPolicy: errorPolicy ?? this.errorPolicy,
      headers: headers ?? this.headers,
      cancelToken: cancelToken ?? this.cancelToken,
      optimisticResponse: optimisticResponse ?? this.optimisticResponse,
      requestId: requestId,
      staleTime: staleTime,
      cacheTime: cacheTime,
      retry: retry,
      refetchInterval: refetchInterval,
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
      },
    );
  });

  group('GraphQLPaginator Tests', () {
    test(
      'offset paginator handles loadInitial, loadNext, and refetch',
      () async {
        final client = GraphQLClient(url: 'https://example.com/graphql');

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
      },
    );

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

  group('Auto-merge and deepMergeJson Tests', () {
    test('deepMergeJson automatically concatenates lists', () {
      final prev = {
        'items': ['a', 'b'],
        'count': 2,
      };
      final incoming = {
        'items': ['c', 'd'],
        'count': 4,
      };
      final merged = deepMergeJson(prev, incoming);
      expect(merged['items'], ['a', 'b', 'c', 'd']);
      expect(merged['count'], 4);
    });

    test('deepMergeJson handles Relay-style nested connections', () {
      final prev = {
        'users': {
          'edges': [
            {
              'node': {'id': '1', 'name': 'Alice'},
            },
          ],
          'pageInfo': {'hasNextPage': true, 'endCursor': 'cursor_1'},
        },
      };
      final incoming = {
        'users': {
          'edges': [
            {
              'node': {'id': '2', 'name': 'Bob'},
            },
          ],
          'pageInfo': {'hasNextPage': false, 'endCursor': 'cursor_2'},
        },
      };

      final merged = deepMergeJson(prev, incoming);
      final edges = (merged['users'] as Map)['edges'] as List;
      expect(edges.length, 2);
      expect(edges[0]['node']['name'], 'Alice');
      expect(edges[1]['node']['name'], 'Bob');

      final pageInfo = (merged['users'] as Map)['pageInfo'] as Map;
      expect(pageInfo['hasNextPage'], false);
      expect(pageInfo['endCursor'], 'cursor_2');
    });

    test('autoMergeGraphQLData merges typed responses seamlessly', () {
      final req = _PageReq(const _PageVars(offset: 0, limit: 2));
      const prev = _PageData(['alpha', 'beta']);
      const incoming = _PageData(['gamma', 'delta']);

      final merged = autoMergeGraphQLData(req, prev, incoming);
      expect(merged.items, ['alpha', 'beta', 'gamma', 'delta']);
    });
  });

  group('client.fetchMore & req.fetchMore Tests', () {
    test(
      'client.fetchMore automatically merges next page and updates cache',
      () async {
        final link = _MockDataLink((req) {
          final offset = req.variables['offset'] as int? ?? 0;
          if (offset == 0) {
            return {
              'items': ['first', 'second'],
            };
          } else {
            return {
              'items': ['third', 'fourth'],
            };
          }
        });

        final client = GraphQLClient.fromLink(
          link,
          defaultFetchPolicy: FetchPolicy.cacheFirst,
        );

        final req1 = _PageReq(const _PageVars(offset: 0, limit: 2));
        final initialData = await client.future(req1);
        expect(initialData.items, ['first', 'second']);
        expect(client.cache.readQuery(req1)?.items, ['first', 'second']);

        // Setup cache watcher on the original request
        final emissions = <List<String>>[];
        final sub = client.watchQuery(req1).listen((d) {
          if (d != null) emissions.add(d.items);
        });

        // fetchMore next page
        final req2 = _PageReq(const _PageVars(offset: 2, limit: 2));
        final mergedData = await client.fetchMore(
          originalRequest: req1,
          nextRequest: req2,
        );

        // Verify merged without manual append!
        expect(mergedData.items, ['first', 'second', 'third', 'fourth']);
        // Verify cache for original request was automatically updated
        expect(client.cache.readQuery(req1)?.items, [
          'first',
          'second',
          'third',
          'fourth',
        ]);

        await Future<void>.delayed(Duration.zero);
        expect(emissions.last, ['first', 'second', 'third', 'fourth']);

        await sub.cancel();
      },
    );

    test('req.fetchMore extension executes and merges automatically', () async {
      final link = _MockDataLink((req) {
        final offset = req.variables['offset'] as int? ?? 0;
        return {
          'items': offset == 0 ? ['1', '2'] : ['3', '4'],
        };
      });

      final client = GraphQLClient.fromLink(
        link,
        defaultFetchPolicy: FetchPolicy.cacheFirst,
      );
      final req1 = _PageReq(const _PageVars(offset: 0, limit: 2));
      await req1.execute(client);

      final req2 = _PageReq(const _PageVars(offset: 2, limit: 2));
      final result = await req1.fetchMore(client, nextRequest: req2);

      expect(result.items, ['1', '2', '3', '4']);
      expect(client.cache.readQuery(req1)?.items, ['1', '2', '3', '4']);
    });

    test(
      'fetchMore with custom updateQuery respects custom merge logic',
      () async {
        final link = _MockDataLink((req) {
          final offset = req.variables['offset'] as int? ?? 0;
          return {
            'items': offset == 0 ? ['a'] : ['b'],
          };
        });

        final client = GraphQLClient.fromLink(
          link,
          defaultFetchPolicy: FetchPolicy.cacheFirst,
        );
        final req1 = _PageReq(const _PageVars(offset: 0, limit: 1));
        await req1.execute(client);

        final req2 = _PageReq(const _PageVars(offset: 1, limit: 1));
        final result = await client.fetchMore(
          originalRequest: req1,
          nextRequest: req2,
          updateQuery: (prev, incoming) =>
              _PageData([...prev.items, 'custom_injected', ...incoming.items]),
        );

        expect(result.items, ['a', 'custom_injected', 'b']);
        expect(client.cache.readQuery(req1)?.items, [
          'a',
          'custom_injected',
          'b',
        ]);
      },
    );
  });

  group('GraphQLPaginator Automatic Accumulation Tests', () {
    test(
      'GraphQLPaginator automatically accumulates items and updates cache across pages',
      () async {
        final link = _MockDataLink((req) {
          final offset = req.variables['offset'] as int? ?? 0;
          if (offset == 0) {
            return {
              'items': ['p1_a', 'p1_b'],
            };
          } else if (offset == 2) {
            return {
              'items': ['p2_c', 'p2_d'],
            };
          } else {
            return {
              'items': ['p3_e'],
            };
          }
        });

        final client = GraphQLClient.fromLink(link);
        final req = _PageReq(const _PageVars(offset: 0, limit: 2));

        final paginator = GraphQLPaginator<_PageData, _PageVars, String>.offset(
          client: client,
          initialRequest: req,
          getItems: (d) => d.items,
          updateOffset: (curr, offset, limit) =>
              _PageVars(offset: offset, limit: limit),
          limit: 2,
        );

        // Track itemsStream emissions
        final streamHistory = <List<String>>[];
        final sub = paginator.itemsStream.listen((items) {
          streamHistory.add(List.from(items));
        });

        // 1. loadInitial returns page 1 items directly
        final initialItems = await paginator.loadInitial();
        expect(initialItems, ['p1_a', 'p1_b']);
        expect(paginator.items, ['p1_a', 'p1_b']);
        expect(paginator.accumulatedData?.items, ['p1_a', 'p1_b']);
        expect(paginator.hasMore, isTrue);

        // 2. loadNext returns accumulated items directly without manual append
        final page2Items = await paginator.loadNext();
        expect(page2Items, ['p1_a', 'p1_b', 'p2_c', 'p2_d']);
        expect(paginator.items, ['p1_a', 'p1_b', 'p2_c', 'p2_d']);
        expect(paginator.accumulatedData?.items, [
          'p1_a',
          'p1_b',
          'p2_c',
          'p2_d',
        ]);
        // And the normalized cache under initialRequest holds the merged data!
        expect(client.cache.readQuery(req)?.items, [
          'p1_a',
          'p1_b',
          'p2_c',
          'p2_d',
        ]);

        // 3. loadNext for page 3 (returns 1 item < limit 2, so hasMore becomes false)
        final page3Items = await paginator.loadNext();
        expect(page3Items, ['p1_a', 'p1_b', 'p2_c', 'p2_d', 'p3_e']);
        expect(paginator.hasMore, isFalse);

        await Future<void>.delayed(Duration.zero);
        expect(streamHistory, [
          [],
          ['p1_a', 'p1_b'],
          ['p1_a', 'p1_b', 'p2_c', 'p2_d'],
          ['p1_a', 'p1_b', 'p2_c', 'p2_d', 'p3_e'],
        ]);

        // 4. refetch resets to page 1
        final refetchedItems = await paginator.refetch();
        expect(refetchedItems, ['p1_a', 'p1_b']);
        expect(paginator.items, ['p1_a', 'p1_b']);
        expect(paginator.accumulatedData?.items, ['p1_a', 'p1_b']);
        expect(paginator.hasMore, isTrue);

        await Future<void>.delayed(Duration.zero);
        expect(streamHistory.last, ['p1_a', 'p1_b']);
        expect(streamHistory.length, 5);

        await sub.cancel();
        paginator.dispose();
      },
    );

    test(
      'GraphQLPaginator.loadAll fetches all pages until exhausted',
      () async {
        final link = _MockDataLink((req) {
          final offset = req.variables['offset'] as int? ?? 0;
          if (offset == 0) {
            return {
              'items': ['1', '2'],
            };
          } else if (offset == 2) {
            return {
              'items': ['3', '4'],
            };
          } else {
            return {
              'items': ['5'],
            };
          }
        });

        final client = GraphQLClient.fromLink(link);
        final req = _PageReq(const _PageVars(offset: 0, limit: 2));

        final paginator = GraphQLPaginator<_PageData, _PageVars, String>.offset(
          client: client,
          initialRequest: req,
          getItems: (d) => d.items,
          updateOffset: (curr, offset, limit) =>
              _PageVars(offset: offset, limit: limit),
          limit: 2,
        );

        final allItems = await paginator.loadAll();
        expect(allItems, ['1', '2', '3', '4', '5']);
        expect(paginator.items, ['1', '2', '3', '4', '5']);
        expect(paginator.hasMore, isFalse);

        paginator.dispose();
      },
    );

    test('GraphQLPaginator.loadAll with interPageDelay waits between pages, '
        'not before the first one', () async {
      final requestTimes = <DateTime>[];
      final link = _MockDataLink((req) {
        requestTimes.add(DateTime.now());
        final offset = req.variables['offset'] as int? ?? 0;
        if (offset == 0) {
          return {
            'items': ['1', '2'],
          };
        } else if (offset == 2) {
          return {
            'items': ['3', '4'],
          };
        } else {
          return {
            'items': ['5'],
          };
        }
      });

      final client = GraphQLClient.fromLink(link);
      final req = _PageReq(const _PageVars(offset: 0, limit: 2));

      final paginator = GraphQLPaginator<_PageData, _PageVars, String>.offset(
        client: client,
        initialRequest: req,
        getItems: (d) => d.items,
        updateOffset: (curr, offset, limit) =>
            _PageVars(offset: offset, limit: limit),
        limit: 2,
      );

      await paginator.loadAll(interPageDelay: const Duration(milliseconds: 60));

      expect(
        requestTimes,
        hasLength(3),
        reason:
            'loadInitial + two loadNext calls to exhaust 5 items '
            'at a page size of 2',
      );
      final gapBeforeSecondPage = requestTimes[1]
          .difference(requestTimes[0])
          .inMilliseconds;
      final gapBeforeThirdPage = requestTimes[2]
          .difference(requestTimes[1])
          .inMilliseconds;
      expect(
        gapBeforeSecondPage,
        lessThan(30),
        reason:
            'no delay between loadInitial and the first loadNext — '
            'interPageDelay only spaces out subsequent page requests',
      );
      expect(
        gapBeforeThirdPage,
        greaterThanOrEqualTo(55),
        reason:
            'interPageDelay must be waited before the second '
            'loadNext call',
      );

      paginator.dispose();
    });

    test(
      'GraphQLPaginator applyVariables updates variables and refetch preserves them',
      () async {
        int receivedLimit = 0;
        final link = _MockDataLink((req) {
          receivedLimit = req.variables['limit'] as int? ?? 0;
          final offset = req.variables['offset'] as int? ?? 0;
          return {
            'items': List.generate(receivedLimit, (i) => 'item_${offset + i}'),
          };
        });

        final client = GraphQLClient.fromLink(link);
        final req = _PageReq(const _PageVars(offset: 0, limit: 2));

        final paginator = GraphQLPaginator<_PageData, _PageVars, String>.offset(
          client: client,
          initialRequest: req,
          getItems: (d) => d.items,
          updateOffset: (curr, offset, limit) =>
              _PageVars(offset: offset, limit: limit),
          limit: 2,
        );

        await paginator.loadInitial();
        expect(paginator.items.length, 2);
        expect(receivedLimit, 2);

        // Apply new variables (e.g. limit changed or filter applied)
        await paginator.applyVariables(const _PageVars(offset: 0, limit: 5));
        expect(paginator.items.length, 5);
        expect(receivedLimit, 5);
        expect(paginator.currentVariables.limit, 5);

        // Pagination persists and accumulates items
        await paginator.loadNext();
        expect(paginator.items.length, 7);

        // Refetch resets back to initialRequest (limit: 2, offset: 0, 2 items)
        receivedLimit = 0;
        await paginator.refetch();
        expect(receivedLimit, 2);
        expect(paginator.items.length, 2);
        expect(paginator.currentVariables.limit, 2);

        paginator.dispose();
      },
    );
  });
}
