import 'dart:async';
import 'dart:io';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'src/config/builder_options.dart';
import 'src/generator/orchestrator/generator_orchestrator.dart';

Builder mkGraphQLBuilder(BuilderOptions options) => MkGraphQLBuilder(options);

class MkGraphQLBuilder implements Builder {
  final MkGraphQLConfig config;

  @override
  final Map<String, List<String>> buildExtensions;

  factory MkGraphQLBuilder([BuilderOptions? options]) {
    final config = MkGraphQLConfig.fromOptions(options ?? BuilderOptions.empty);
    final extensions = <String, List<String>>{};
    final schemaPath = config.schemaPath;
    final sharedDir = config.sharedDir;
    final libDir = Directory('lib');
    if (libDir.existsSync()) {
      final gqlFiles = libDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.graphql') || f.path.endsWith('.gql'));
      for (final file in gqlFiles) {
        try {
          final content = file.readAsStringSync();
          final outputRels = GeneratorOrchestrator.computeOutputPaths(
            content: content,
            inputPath: file.path,
            schemaPath: schemaPath,
            sharedDir: sharedDir,
          );
          final outputs = outputRels
              .map((k) => p.normalize(p.join(p.dirname(file.path), k)))
              .toList();
          extensions[file.path] = outputs;
        } catch (_) {}
      }
    }

    if (extensions.isEmpty) {
      extensions['.graphql'] = ['.gql.dart'];
      extensions['.gql'] = ['.gql.dart'];
    }

    return MkGraphQLBuilder._(config, extensions);
  }

  MkGraphQLBuilder._(this.config, this.buildExtensions);

  @override
  Future<void> build(BuildStep buildStep) async {
    final inputId = buildStep.inputId;
    if (!inputId.path.endsWith('.graphql') && !inputId.path.endsWith('.gql')) {
      return;
    }
    final content = await buildStep.readAsString(inputId);
    final schemaPath = config.schemaPath;
    final sharedDir = config.sharedDir;

    String? schemaContent;
    if (schemaPath != null &&
        p.normalize(schemaPath) != p.normalize(inputId.path)) {
      final schemaAssetId = AssetId(inputId.package, schemaPath);
      if (await buildStep.canRead(schemaAssetId)) {
        schemaContent = await buildStep.readAsString(schemaAssetId);
      } else {
        try {
          schemaContent = File(schemaPath).readAsStringSync();
        } catch (_) {}
      }
    }

    final bundle = GeneratorOrchestrator.generateForGraphQLFile(
      content: content,
      inputPath: inputId.path,
      schemaPath: schemaPath,
      sharedDir: sharedDir,
      schemaContent: schemaContent,
      packageName: inputId.package,
      customScalars: config.scalars,
      useCache: config.cache,
    );

    final baseDir = p.dirname(inputId.path);

    for (final entry in bundle.files.entries) {
      final targetPath = p.normalize(p.join(baseDir, entry.key));
      final outputId = AssetId(inputId.package, targetPath);
      await buildStep.writeAsString(outputId, entry.value);
    }
  }
}
