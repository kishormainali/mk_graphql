// Wall-clock benchmarks for InMemoryCache/HiveCache's hot paths.
//
// Not part of the regular test suite (lives outside test/, so plain
// `flutter test` never picks it up) — run explicitly:
//   flutter test benchmark/cache_benchmark_test.dart
//
// Useful as a regression guard: re-run before/after a cache change and
// compare the printed us/op numbers. Numbers are machine-dependent; only
// relative deltas on the same machine are meaningful.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _Vars {
  final String id;
  const _Vars(this.id);
  Map<String, dynamic> toJson() => {'id': id};
}

class _Item {
  final String id;
  final String name;
  final String description;
  const _Item(this.id, this.name, this.description);
  Map<String, dynamic> toJson() => {
        '__typename': 'Item',
        'id': id,
        'name': name,
        'description': description,
      };
}

class _PageData {
  final List<_Item> items;
  const _PageData(this.items);
  factory _PageData.fromJson(Map<String, dynamic> json) => _PageData(
        (json['items'] as List)
            .map((e) => _Item(
                e['id'] as String, e['name'] as String, e['description'] as String))
            .toList(),
      );
  Map<String, dynamic> toJson() =>
      {'items': items.map((e) => e.toJson()).toList()};
}

class _Req extends GraphQLRequest<_PageData, _Vars> {
  const _Req(this.variables);
  @override
  final _Vars variables;
  @override
  String get document =>
      'query GetPage(\$id: String) { items { id name description } }';
  @override
  String get operationName => 'GetPage';
  @override
  Map<String, dynamic> toJsonVars(_Vars vars) => vars.toJson();
  @override
  _PageData parseData(Map<String, dynamic> json) => _PageData.fromJson(json);
  @override
  _Req copyWithRequest({
    _Vars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _PageData? optimisticResponse,
  }) =>
      _Req(variables ?? this.variables);
}

_PageData _syntheticPage(int itemCount) => _PageData([
      for (var i = 0; i < itemCount; i++)
        _Item('item_$i', 'Name $i', 'A description for item number $i'),
    ]);

void _report(String label, Stopwatch sw, int iterations) {
  final usPerOp = sw.elapsedMicroseconds / iterations;
  // ignore: avoid_print
  print('$label: ${sw.elapsedMilliseconds}ms total, '
      '${usPerOp.toStringAsFixed(1)}us/op ($iterations iterations)');
}

void main() {
  const itemCount = 500;
  const writeIterations = 300;
  const readIterations = 300;

  test('InMemoryCache.writeQuery ($itemCount items per response)', () async {
    final cache = InMemoryCache();
    final data = _syntheticPage(itemCount);

    final sw = Stopwatch()..start();
    for (var i = 0; i < writeIterations; i++) {
      cache.writeQuery(_Req(_Vars('$i')), data);
    }
    sw.stop();
    _report('writeQuery', sw, writeIterations);
  });

  test(
      'InMemoryCache.readQuery, repeated reads of one key with no writes '
      'in between ($itemCount items)', () async {
    final cache = InMemoryCache();
    final req = _Req(const _Vars('1'));
    cache.writeQuery(req, _syntheticPage(itemCount));

    final sw = Stopwatch()..start();
    for (var i = 0; i < readIterations; i++) {
      cache.readQuery(req);
    }
    sw.stop();
    _report('readQuery (memoized after 1st)', sw, readIterations);
  });

  test('HiveCache incremental persist across distinct queries (50 items each)',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('hive_bench_');
    Hive.init(tempDir.path);
    final cache = await HiveCache.open(boxName: 'bench_box');

    const hiveIterations = 100;
    final sw = Stopwatch()..start();
    for (var i = 0; i < hiveIterations; i++) {
      cache.writeQuery(_Req(_Vars('$i')), _syntheticPage(50));
      // Let this write's debounced persist actually run before the next
      // one, so each write gets its own persist cycle — matching the
      // realistic incremental pattern (queries spread over time), not one
      // big batched persist covering everything.
      await pumpEventQueue();
    }
    sw.stop();
    await cache.close();
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);

    _report('HiveCache persist cycle', sw, hiveIterations);
  });
}
