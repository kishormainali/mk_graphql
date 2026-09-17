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

    final reopened =
        await HiveCache.open(boxName: 'gql_cache_optimistic_test');
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
}
