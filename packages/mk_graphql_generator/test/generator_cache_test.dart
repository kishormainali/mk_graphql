import 'dart:io';

import 'package:mk_graphql_generator/src/cache/generator_cache.dart';
import 'package:mk_graphql_generator/src/generator/orchestrator/generator_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  group('GeneratorCache', () {
    late int originalMaxMemoryEntries;

    setUp(() {
      GeneratorCache.clear();
      originalMaxMemoryEntries = GeneratorCache.maxMemoryEntries;
    });

    tearDown(() {
      GeneratorCache.clear();
      GeneratorCache.maxMemoryEntries = originalMaxMemoryEntries;
    });

    test(
        'evicts the least-recently-used entry once the in-memory cache '
        'exceeds maxMemoryEntries, instead of growing forever', () async {
      GeneratorCache.maxMemoryEntries = 3;

      final keys = [for (var i = 0; i < 5; i++) 'lru_test_key_$i'];
      for (final key in keys) {
        GeneratorCache.put(key, GeneratedBundle(files: {'a.dart': key}));
      }

      // Disk cache would otherwise mask a memory-only eviction bug (get()
      // falls back to disk) — delete it so this test observes memory
      // behavior in isolation.
      final dir = Directory(GeneratorCache.cacheDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);

      expect(GeneratorCache.get(keys[0]), isNull,
          reason: 'the oldest entry must have been evicted once a 4th and '
              '5th entry pushed the cache past its cap of 3');
      expect(GeneratorCache.get(keys[1]), isNull);
      expect(GeneratorCache.get(keys[4])?.files['a.dart'], equals(keys[4]),
          reason: 'the most recently written entries must survive');
    });

    test(
        'reading an entry counts as a use, so it survives longer than an '
        'entry that was only ever written', () async {
      GeneratorCache.maxMemoryEntries = 2;

      GeneratorCache.put('lru_touch_a', GeneratedBundle(files: {'a.dart': 'a'}));
      GeneratorCache.put('lru_touch_b', GeneratedBundle(files: {'a.dart': 'b'}));
      // Touch "a" so it becomes the most-recently-used of the two.
      GeneratorCache.get('lru_touch_a');
      GeneratorCache.put('lru_touch_c', GeneratedBundle(files: {'a.dart': 'c'}));

      final dir = Directory(GeneratorCache.cacheDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);

      expect(GeneratorCache.get('lru_touch_b'), isNull,
          reason: '"b" is the least-recently-used once "a" was re-read '
              'and "c" was added, so it is the one evicted');
      expect(GeneratorCache.get('lru_touch_a')?.files['a.dart'], equals('a'));
      expect(GeneratorCache.get('lru_touch_c')?.files['a.dart'], equals('c'));
    });

    test('put/get round-trips through disk once memory is cleared', () {
      final key = GeneratorCache.computeKey(
        inputPath: 'lib/foo.graphql',
        content: 'query Foo { foo }',
      );
      GeneratorCache.put(key, GeneratedBundle(files: {'foo.dart': 'content'}));
      GeneratorCache.clearMemory();

      expect(GeneratorCache.get(key)?.files['foo.dart'], equals('content'));
    });
  });
}
