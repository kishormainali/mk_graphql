import 'dart:io';
import 'package:yaml/yaml.dart';

/// Reads a `build.yaml` file and extracts the `schema_path` configured for `mk_graphql_generator` or `mk_graphql_builder`.
String? findSchemaPathFromBuildYaml({String buildYamlPath = 'build.yaml'}) {
  final file = File(buildYamlPath);
  if (!file.existsSync()) return null;

  try {
    final content = file.readAsStringSync();
    return parseSchemaPathFromYaml(content);
  } catch (_) {
    return null;
  }
}

/// Parses YAML content of a `build.yaml` and extracts the `schema_path` or `schemaPath`.
String? parseSchemaPathFromYaml(String yamlContent) {
  try {
    final doc = loadYaml(yamlContent);
    if (doc is! Map) return null;

    // 1. Check targets -> <target> -> builders -> <builder> -> options -> schema_path
    final targets = doc['targets'];
    if (targets is Map) {
      for (final target in targets.values) {
        if (target is! Map) continue;
        final builders = target['builders'];
        if (builders is! Map) continue;

        // First look specifically for mk_graphql builders
        for (final entry in builders.entries) {
          final builderKey = entry.key.toString();
          if (builderKey.contains('mk_graphql')) {
            final path = _extractSchemaPath(entry.value);
            if (path != null) return path;
          }
        }

        // Fallback: any builder with schema_path / schemaPath in options
        for (final entry in builders.entries) {
          final path = _extractSchemaPath(entry.value);
          if (path != null) return path;
        }
      }
    }

    // 2. Check global_options -> <builder> -> options -> schema_path
    final globalOptions = doc['global_options'];
    if (globalOptions is Map) {
      for (final entry in globalOptions.entries) {
        final path = _extractSchemaPath(entry.value);
        if (path != null) return path;
      }
    }
  } catch (_) {}

  return null;
}

String? _extractSchemaPath(dynamic builderConfig) {
  if (builderConfig is! Map) return null;
  final options = builderConfig['options'];
  if (options is! Map) return null;
  final rawPath = options['schema_path'] ?? options['schemaPath'];
  if (rawPath is String && rawPath.trim().isNotEmpty) {
    return rawPath.trim();
  }
  return null;
}
