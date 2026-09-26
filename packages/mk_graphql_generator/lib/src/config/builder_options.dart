import 'dart:io';
import 'package:build/build.dart';
import 'package:path/path.dart' as p;

/// Configuration options passed to [MkGraphQLBuilder] from `build.yaml`.
class MkGraphQLConfig {
  /// Custom path to GraphQL schema SDL file (e.g. `lib/graphql/schema.graphql`).
  final String? schemaPath;

  /// Custom directory for shared generated artifacts (enums, inputs, models).
  /// If omitted, defaults to `generated/` within the schema file's directory.
  final String? sharedDir;

  /// Whether to cache generated artifacts to avoid re-generating. Defaults to `true`.
  final bool cache;

  /// Custom scalar type mappings from GraphQL scalar names to Dart types.
  final Map<String, String> scalars;

  const MkGraphQLConfig({
    this.schemaPath,
    this.sharedDir,
    this.cache = true,
    this.scalars = const {},
  });

  /// [autoDetectedSchemaPath] lets a caller that already walked `lib/` for
  /// its own purposes (e.g. [MkGraphQLBuilder]'s factory, which scans it for
  /// every `.graphql`/`.gql` file anyway) hand over the schema file it found
  /// instead of this doing its own separate recursive [Directory.listSync]
  /// of the same tree — two full scans back-to-back in the same builder
  /// construction otherwise. Only consulted when `schema_path` isn't set in
  /// `build.yaml`; still falls back to [_findSchemaPath]'s own scan when
  /// omitted, so any other caller (tests included) keeps working unchanged.
  factory MkGraphQLConfig.fromOptions(
    BuilderOptions options, {
    String? autoDetectedSchemaPath,
  }) {
    final cfg = options.config;

    // 1. Schema path
    final rawSchemaPath = cfg['schema_path'] ?? cfg['schemaPath'];
    String? schemaPath;
    if (rawSchemaPath is String && rawSchemaPath.trim().isNotEmpty) {
      schemaPath = p.normalize(rawSchemaPath.trim());
    } else {
      schemaPath = autoDetectedSchemaPath ?? _findSchemaPath();
    }

    // 2. Shared directory
    final rawSharedDir = cfg['shared_dir'] ??
        cfg['sharedDir'] ??
        cfg['shared_path'] ??
        cfg['sharedPath'];
    String? sharedDir;
    if (rawSharedDir is String && rawSharedDir.trim().isNotEmpty) {
      sharedDir = p.normalize(rawSharedDir.trim());
    } else if (schemaPath != null) {
      sharedDir = p.normalize(p.join(p.dirname(schemaPath), 'generated'));
    }

    // 3. Cache flag (defaults to true)
    final cache = cfg['cache'] is bool ? cfg['cache'] as bool : true;

    // 4. Custom scalars mapping
    final rawScalars = cfg['scalars'];
    final scalars = <String, String>{};
    if (rawScalars is Map) {
      rawScalars.forEach((k, v) {
        if (k != null && v != null) scalars[k.toString()] = v.toString();
      });
    }

    return MkGraphQLConfig(
      schemaPath: schemaPath,
      sharedDir: sharedDir,
      cache: cache,
      scalars: Map.unmodifiable(scalars),
    );
  }

  static String? _findSchemaPath() {
    final libDir = Directory('lib');
    if (libDir.existsSync()) {
      final matches =
          libDir.listSync(recursive: true).whereType<File>().where((f) {
        final name = p.basename(f.path);
        return name == 'schema.graphql' || name == 'schema.gql';
      });
      if (matches.isNotEmpty) {
        return matches.first.path;
      }
    }
    return null;
  }
}
