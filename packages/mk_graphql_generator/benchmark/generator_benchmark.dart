// Wall-clock benchmark for the generator's cold-build path (factory scan +
// build()) and GeneratorCache.put.
//
// Run:
//   dart run benchmark/generator_benchmark.dart
//
// Useful as a regression guard: re-run before/after a generator change and
// compare the printed us/op numbers. Numbers are machine-dependent; only
// relative deltas on the same machine are meaningful.
import 'dart:io';

import 'package:mk_graphql_generator/src/cache/generator_cache.dart';
import 'package:mk_graphql_generator/src/generator/orchestrator/generator_orchestrator.dart';
import 'package:mk_graphql_generator/src/parser/graphql_parser.dart';

import 'fixtures.dart';

void _report(String label, Stopwatch sw, int iterations) {
  print('$label: ${sw.elapsedMilliseconds}ms total, '
      '${(sw.elapsedMicroseconds / iterations).toStringAsFixed(1)}us/op '
      '($iterations iterations)');
}

void main() async {
  final schema = buildSchema();
  final ops = buildOperationsFile();

  // --- Cold build simulation: what MkGraphQLBuilder's factory (parse +
  // computeOutputPaths) and build() (generateForGraphQLFile, useCache:
  // false to force a miss every time, simulating a fresh `build_runner
  // build`) do for one schema file + one feature file.
  const buildIterations = 200;
  final sw1 = Stopwatch()..start();
  for (var i = 0; i < buildIterations; i++) {
    final schemaParsed = ParsedGraphQLDocument.parse(schema);
    GeneratorOrchestrator.computeOutputPaths(
      content: schema,
      inputPath: 'lib/schema.graphql',
      schemaPath: 'lib/schema.graphql',
      preParsed: schemaParsed,
    );
    final opsParsed = ParsedGraphQLDocument.parse(ops);
    GeneratorOrchestrator.computeOutputPaths(
      content: ops,
      inputPath: 'lib/ops.graphql',
      schemaPath: 'lib/schema.graphql',
      preParsed: opsParsed,
    );
    await GeneratorOrchestrator.generateForGraphQLFile(
      content: schema,
      inputPath: 'lib/schema.graphql',
      schemaPath: 'lib/schema.graphql',
      useCache: false,
      preParsed: schemaParsed,
    );
    await GeneratorOrchestrator.generateForGraphQLFile(
      content: ops,
      inputPath: 'lib/ops.graphql',
      schemaPath: 'lib/schema.graphql',
      schemaContent: schema,
      useCache: false,
      preParsed: opsParsed,
    );
  }
  sw1.stop();
  _report('cold build cycle (schema + 1 feature file, 20 operations)', sw1,
      buildIterations);

  // --- GeneratorCache.put
  final tempDir = Directory.systemTemp.createTempSync('gen_cache_bench_');
  GeneratorCache.cacheDir = tempDir.path;
  const putIterations = 500;
  final bundle = GeneratedBundle(files: {
    for (var i = 0; i < 20; i++) 'file_$i.dart': schema,
  });
  final sw2 = Stopwatch()..start();
  for (var i = 0; i < putIterations; i++) {
    GeneratorCache.put('key_$i', bundle);
  }
  sw2.stop();
  tempDir.deleteSync(recursive: true);
  _report('GeneratorCache.put', sw2, putIterations);
}
