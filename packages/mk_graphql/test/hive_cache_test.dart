import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _TestVars {
  final String id;
  const _TestVars(this.id);
  Map<String, dynamic> toJson() => {'id': id};
}

class _TestData {
  final String? id;
  final String? name;
  const _TestData({this.id, this.name});
  factory _TestData.fromJson(Map<String, dynamic> json) =>
      _TestData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(this.variables, {super.requestId});

  @override
  String get document => 'query Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestReq(variables ?? this.variables, requestId: requestId);
}

class _TypedData {
  final String? id;
  final String? name;
  const _TypedData({this.id, this.name});
  factory _TypedData.fromJson(Map<String, dynamic> json) =>
      _TypedData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() =>
      {'__typename': 'User', 'id': id, 'name': name};
}

class _TypedTestReq extends GraphQLRequest<_TypedData, _TestVars> {
  @override
  final _TestVars variables;
  _TypedTestReq(this.variables);

  @override
  String get document => 'query TypedTest { user { id name } }';

  @override
  String get operationName => 'TypedTest';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TypedData parseData(Map<String, dynamic> json) => _TypedData.fromJson(json);

  @override
  _TypedTestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _TypedData? optimisticResponse,
  }) =>
      _TypedTestReq(variables ?? this.variables);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_cache_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('writeQuery persists and a reopened box hydrates the same data',
      () async {
    final req = _TestReq(const _TestVars('1'));

    final cache1 = await HiveCache.open(boxName: 'gql_cache_test');
    cache1.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    expect(cache1.readQuery(req)?.name, equals('Alice'));
    await pumpEventQueue(); // let the debounced persist complete
    await cache1.close();

    final cache2 = await HiveCache.open(boxName: 'gql_cache_test');
    expect(cache2.readQuery(req)?.name, equals('Alice'));
    await cache2.close();
  });

  test('evict removes the entry from both the in-memory store and the box',
      () async {
    final req = _TestReq(const _TestVars('1'));
    final cache = await HiveCache.open(boxName: 'gql_cache_evict_test');
    cache.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    await pumpEventQueue();

    cache.evictQuery(req);
    await pumpEventQueue();
    await cache.close();

    final reopened = await HiveCache.open(boxName: 'gql_cache_evict_test');
    expect(reopened.readQuery(req), isNull);
    await reopened.close();
  });

  test('optimistic writes never reach the box', () async {
    final req = _TestReq(const _TestVars('1'), requestId: 'req_1');
    final cache = await HiveCache.open(boxName: 'gql_cache_optimistic_test');
    cache.recordOptimistic(req, const _TestData(id: '1', name: 'Optimistic'));
    expect(cache.readQuery(req)?.name, equals('Optimistic'));
    await pumpEventQueue();
    await cache.close();

    final reopened = await HiveCache.open(boxName: 'gql_cache_optimistic_test');
    expect(reopened.readQuery(req), isNull,
        reason: 'optimistic data must never be persisted');
    await reopened.close();
  });

  test('onPersistError is invoked, not thrown, when the box write fails',
      () async {
    final req = _TestReq(const _TestVars('1'));
    Object? capturedError;
    final cache = await HiveCache.open(
      boxName: 'gql_cache_error_test',
      onPersistError: (e, st) => capturedError = e,
    );

    // Force the underlying box into a state where persisting fails.
    final box = await Hive.openBox<Map>('gql_cache_error_test');
    await box.close();

    expect(
      () => cache.writeQuery(req, const _TestData(id: '1', name: 'Alice')),
      returnsNormally,
    );
    await pumpEventQueue();
    expect(capturedError, isNotNull);
  });

  test(
      'a query hydrated from a reopened box is immediately visible to '
      'matchingQueryKeys (by operationName and by type), without waiting '
      'for a live re-write', () async {
    final req = _TestReq(const _TestVars('1'));
    final typedReq = _TypedTestReq(const _TestVars('2'));

    final cache1 = await HiveCache.open(boxName: 'gql_cache_hydration_test');
    cache1.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    cache1.writeQuery(typedReq, const _TypedData(id: '2', name: 'Bob'));
    await pumpEventQueue();
    await cache1.close();

    // Fresh process-equivalent: a brand-new HiveCache hydrated purely from
    // disk, no live writeQuery call on this instance at all.
    final cache2 = await HiveCache.open(boxName: 'gql_cache_hydration_test');

    expect(cache2.writtenAt(req), isNotNull,
        reason: 'seeded records must be timestamped, not left as '
            'never-written');
    expect(cache2.matchingQueryKeys(operationNames: ['Test']), isNotEmpty,
        reason: 'a hydrated query must be matchable by operation name '
            'without requiring a prior live write');
    expect(cache2.matchingQueryKeys(types: ['User']), isNotEmpty,
        reason: 'a hydrated query must be matchable by typename too — the '
            'seeded record\'s __typename must be denormalized and '
            'collected, not just the raw record dumped in');
    await cache2.close();
  });

  test(
      'incremental writes persist every touched query, not just the most '
      'recent one — regression for the diff-based persist that replaced a '
      'full box clear()+putAll() on every batch', () async {
    final reqA = _TestReq(const _TestVars('a'));
    final reqB = _TestReq(const _TestVars('b'));
    final reqC = _TestReq(const _TestVars('c'));

    final cache1 = await HiveCache.open(boxName: 'gql_cache_incremental_test');
    cache1.writeQuery(reqA, const _TestData(id: 'a', name: 'Alice'));
    await pumpEventQueue();
    cache1.writeQuery(reqB, const _TestData(id: 'b', name: 'Bob'));
    await pumpEventQueue();
    cache1.writeQuery(reqC, const _TestData(id: 'c', name: 'Carol'));
    await pumpEventQueue();
    await cache1.close();

    final cache2 = await HiveCache.open(boxName: 'gql_cache_incremental_test');
    expect(cache2.readQuery(reqA)?.name, equals('Alice'));
    expect(cache2.readQuery(reqB)?.name, equals('Bob'));
    expect(cache2.readQuery(reqC)?.name, equals('Carol'));
    await cache2.close();
  });

  test(
      'evicting one query leaves a separately persisted query untouched on '
      'disk', () async {
    final reqA = _TestReq(const _TestVars('a'));
    final reqB = _TestReq(const _TestVars('b'));

    final cache = await HiveCache.open(boxName: 'gql_cache_partial_evict_test');
    cache.writeQuery(reqA, const _TestData(id: 'a', name: 'Alice'));
    await pumpEventQueue();
    cache.writeQuery(reqB, const _TestData(id: 'b', name: 'Bob'));
    await pumpEventQueue();

    cache.evictQuery(reqA);
    await pumpEventQueue();
    await cache.close();

    final reopened = await HiveCache.open(boxName: 'gql_cache_partial_evict_test');
    expect(reopened.readQuery(reqA), isNull);
    expect(reopened.readQuery(reqB)?.name, equals('Bob'));
    await reopened.close();
  });

  test(
      'a query hydrated from a reopened box is timestamped arbitrarily old, '
      'not "just written" — so it stays correctly stale under any '
      'configured staleTime, not just the default Duration.zero', () async {
    final req = _TestReq(const _TestVars('1'));

    final cache1 = await HiveCache.open(boxName: 'gql_cache_staleness_test');
    cache1.writeQuery(req, const _TestData(id: '1', name: 'Alice'));
    await pumpEventQueue();
    await cache1.close();

    final cache2 = await HiveCache.open(boxName: 'gql_cache_staleness_test');
    final writtenAt = cache2.writtenAt(req);

    expect(writtenAt, isNotNull);
    // A hydrated value's writtenAt must be old enough that even a generous
    // staleTime (e.g. a day) would still consider it stale — proving it
    // isn't stamped as "just written" (DateTime.now()), which would have
    // made disk-persisted data from a prior app run wrongly count as fresh.
    expect(DateTime.now().difference(writtenAt!),
        greaterThan(const Duration(days: 1)));
    await cache2.close();
  });
}
