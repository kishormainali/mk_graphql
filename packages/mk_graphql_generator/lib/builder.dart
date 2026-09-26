import 'dart:async';
import 'dart:io';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;
import 'src/config/builder_options.dart';
import 'src/generator/orchestrator/generator_orchestrator.dart';
import 'src/parser/graphql_parser.dart';

Builder mkGraphQLBuilder(BuilderOptions options) => MkGraphQLBuilder(options);

/// A parse the factory already did for one file, kept around so [build]
/// can reuse it instead of parsing the same content again — see
/// [MkGraphQLBuilder._parsedCache]'s doc comment.
class _CachedParse {
  _CachedParse(this.content, this.parsed);
  final String content;
  final ParsedGraphQLDocument parsed;
}

class MkGraphQLBuilder implements Builder {
  final MkGraphQLConfig config;

  @override
  final Map<String, List<String>> buildExtensions;

  /// One entry per `.graphql`/`.gql` file under `lib/`, populated once by
  /// the factory below while it computes [buildExtensions] (build_runner
  /// requires every output path declared before any [build] call runs, so
  /// that scan — and the parse it needs — is unavoidable). [build] reuses
  /// the cached parse instead of parsing the same content a second time,
  /// which matters most for a fresh `build_runner build`: every file is a
  /// [GeneratorCache] miss on that first run, so without this, every file
  /// would otherwise be parsed twice per build, not once.
  ///
  /// Bounded by construction, not by eviction: exactly one entry per
  /// `.graphql`/`.gql` file that existed when this [MkGraphQLBuilder] was
  /// constructed, and a fresh instance (with a fresh map) is created for
  /// every build_runner invocation — nothing ever adds to it afterwards, so
  /// there is no unbounded, long-lived growth to guard against. If a file's
  /// content changes between the factory's scan and [build] running against
  /// it (routine in `watch` mode — the whole reason `buildExtensions` isn't
  /// just declared once and left alone), the content-equality check below
  /// misses and [build] falls back to parsing fresh, so this is never
  /// stale, only sometimes not helpful.
  final Map<String, _CachedParse> _parsedCache;

  factory MkGraphQLBuilder([BuilderOptions? options]) {
    // One recursive listing of `lib/`, reused for both this file discovery
    // loop and (via `autoDetectedSchemaPath` below) MkGraphQLConfig's own
    // schema-file auto-detection — previously two separate full-tree
    // `listSync(recursive: true)` walks per builder construction.
    final libDir = Directory('lib');
    final gqlFiles = libDir.existsSync()
        ? libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where(
                (f) => f.path.endsWith('.graphql') || f.path.endsWith('.gql'))
            .toList()
        : const <File>[];

    String? autoDetectedSchemaPath;
    for (final file in gqlFiles) {
      final name = p.basename(file.path);
      if (name == 'schema.graphql' || name == 'schema.gql') {
        autoDetectedSchemaPath = file.path;
        break;
      }
    }

    final config = MkGraphQLConfig.fromOptions(
      options ?? BuilderOptions.empty,
      autoDetectedSchemaPath: autoDetectedSchemaPath,
    );
    final extensions = <String, List<String>>{};
    final parsedCache = <String, _CachedParse>{};
    final schemaPath = config.schemaPath;
    final sharedDir = config.sharedDir;
    for (final file in gqlFiles) {
      try {
        final content = file.readAsStringSync();
        final parsed = ParsedGraphQLDocument.parse(content);
        parsedCache[file.path] = _CachedParse(content, parsed);
        final outputRels = GeneratorOrchestrator.computeOutputPaths(
          content: content,
          inputPath: file.path,
          schemaPath: schemaPath,
          sharedDir: sharedDir,
          preParsed: parsed,
        );
        final outputs = outputRels
            .map((k) => p.normalize(p.join(p.dirname(file.path), k)))
            .toList();
        extensions[file.path] = outputs;
      } catch (e, st) {
        log.warning(
          'mk_graphql_generator: failed to compute build extensions for '
          '${file.path} — this file will be skipped by codegen until its '
          'error is fixed.',
          e,
          st,
        );
      }
    }

    if (extensions.isEmpty) {
      extensions['.graphql'] = ['.gql.dart'];
      extensions['.gql'] = ['.gql.dart'];
    }

    return MkGraphQLBuilder._(config, extensions, parsedCache);
  }

  MkGraphQLBuilder._(this.config, this.buildExtensions, this._parsedCache);

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
        } catch (e, st) {
          log.warning(
            'mk_graphql_generator: could not read schema file $schemaPath '
            'for ${inputId.path} — generating without schema-derived types '
            '(utility selection sets, enums, custom scalars) for this file.',
            e,
            st,
          );
        }
      }
    }

    final cachedParse = _parsedCache[inputId.path];
    final preParsed =
        cachedParse != null && cachedParse.content == content
            ? cachedParse.parsed
            : null;

    final bundle = await GeneratorOrchestrator.generateForGraphQLFile(
      content: content,
      inputPath: inputId.path,
      schemaPath: schemaPath,
      sharedDir: sharedDir,
      schemaContent: schemaContent,
      packageName: inputId.package,
      customScalars: config.scalars,
      useCache: config.cache,
      preParsed: preParsed,
    );

    final baseDir = p.dirname(inputId.path);

    for (final entry in bundle.files.entries) {
      final targetPath = p.normalize(p.join(baseDir, entry.key));
      final outputId = AssetId(inputId.package, targetPath);
      await buildStep.writeAsString(outputId, entry.value);
    }
  }
}
