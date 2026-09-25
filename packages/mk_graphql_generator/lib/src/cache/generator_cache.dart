import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../generator/orchestrator/generator_orchestrator.dart';

/// Cache manager for GraphQL code generation to avoid re-generating
/// unchanged operations and schemas.
class GeneratorCache {
  static const String version = 'v16';
  static String cacheDir = p.join('.dart_tool', 'mk_graphql_cache');

  static final Map<String, GeneratedBundle> _memory = {};

  /// Computes a unique cache fingerprint for the given generation inputs.
  static String computeKey({
    required String inputPath,
    required String content,
    String? schemaContent,
    String? sharedDir,
    String? packageName,
    Map<String, String> customScalars = const {},
  }) {
    final scalarsKey = customScalars.entries
        .map((e) => '${e.key}:${e.value}')
        .toList()
      ..sort();
    final rawKey = [
      version,
      p.normalize(inputPath),
      content,
      schemaContent ?? '',
      sharedDir ?? '',
      packageName ?? '',
      scalarsKey.join(','),
    ].join('::');

    final bytes = utf8.encode(rawKey);
    return sha256.convert(bytes).toString();
  }

  /// Retrieves a [GeneratedBundle] from in-memory cache or disk cache if available.
  static GeneratedBundle? get(String key) {
    // 1. In-memory check
    if (_memory.containsKey(key)) {
      return _memory[key];
    }

    // 2. Disk cache check
    try {
      final cacheFile = File(p.join(cacheDir, '$key.json'));
      if (cacheFile.existsSync()) {
        final rawJson = cacheFile.readAsStringSync();
        final decoded = jsonDecode(rawJson);
        if (decoded is Map<String, dynamic> && decoded['files'] is Map) {
          final files = (decoded['files'] as Map).cast<String, String>();
          final bundle = GeneratedBundle(files: files);
          _memory[key] = bundle;
          return bundle;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Stores a [GeneratedBundle] into both in-memory cache and disk cache.
  static void put(String key, GeneratedBundle bundle) {
    _memory[key] = bundle;

    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final cacheFile = File(p.join(cacheDir, '$key.json'));
      cacheFile.writeAsStringSync(
        jsonEncode({'files': bundle.files}),
        flush: true,
      );
    } catch (_) {}
  }

  /// Clears only the in-memory cache.
  static void clearMemory() {
    _memory.clear();
  }

  /// Clears both memory and disk caches.
  static void clear() {
    _memory.clear();
    try {
      final dir = Directory(cacheDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}
