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

  /// Caps the in-memory map so a long-running `build_runner watch` session
  /// doesn't grow it forever — every edit-save cycle would otherwise add
  /// one more (file, content-hash) entry that's never evicted. Insertion
  /// order in [_memory] doubles as LRU order: [get] re-inserts a hit at the
  /// end, so eviction in [put] always drops the least-recently-used entry.
  static int maxMemoryEntries = 500;

  /// Caps how many `.json` files are kept under [cacheDir]. Checked (and
  /// pruned by mtime, oldest first) only every [_diskPruneInterval] writes,
  /// so a normal build doesn't pay for a directory listing on every single
  /// generated file.
  static int maxDiskEntries = 2000;
  static const int _diskPruneInterval = 200;
  static int _writesSincePrune = 0;

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
    // 1. In-memory check — re-insert on hit so the map's iteration order
    // (used by [_evictLruIfNeeded]) reflects recency, not just insertion.
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached;
      return cached;
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
          _rememberInMemory(key, bundle);
          return bundle;
        }
      }
    } catch (e) {
      stderr.writeln(
        'mk_graphql_generator: could not read cache entry $key ($e) — '
        'regenerating from source instead.',
      );
    }

    return null;
  }

  /// Stores a [GeneratedBundle] into both in-memory cache and disk cache.
  static void put(String key, GeneratedBundle bundle) {
    _rememberInMemory(key, bundle);

    try {
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final cacheFile = File(p.join(cacheDir, '$key.json'));
      // No `flush: true`: this is a disposable cache, not durable state — an
      // OS-buffered write is fine, and forcing a flush on every single
      // generated file serializes every builder invocation's disk write,
      // preventing build_runner from overlapping I/O across files/isolates.
      cacheFile.writeAsStringSync(jsonEncode({'files': bundle.files}));

      _writesSincePrune++;
      if (_writesSincePrune >= _diskPruneInterval) {
        _writesSincePrune = 0;
        _pruneDiskCache(dir);
      }
    } catch (e) {
      stderr.writeln(
        'mk_graphql_generator: could not write cache entry $key ($e) — '
        'this file will be regenerated on every build until the cache '
        'directory is writable again.',
      );
    }
  }

  static void _rememberInMemory(String key, GeneratedBundle bundle) {
    _memory.remove(key);
    _memory[key] = bundle;
    if (_memory.length > maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// Deletes the oldest-by-mtime `.json` entries under [dir] once the count
  /// exceeds [maxDiskEntries] — otherwise a long-lived `.dart_tool` cache
  /// (across many schema/query edits over the project's lifetime, never
  /// cleared by anything but an explicit [clear]) grows without bound.
  static void _pruneDiskCache(Directory dir) {
    try {
      final entries = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (entries.length <= maxDiskEntries) return;

      entries.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      final toDelete = entries.length - maxDiskEntries;
      for (var i = 0; i < toDelete; i++) {
        try {
          entries[i].deleteSync();
        } catch (_) {
          // Best-effort: another process may have already removed it.
        }
      }
    } catch (e) {
      stderr.writeln(
        'mk_graphql_generator: could not prune disk cache at '
        '${dir.path} ($e).',
      );
    }
  }

  /// Clears only the in-memory cache.
  static void clearMemory() {
    _memory.clear();
  }

  /// Clears both memory and disk caches.
  static void clear() {
    _memory.clear();
    _writesSincePrune = 0;
    try {
      final dir = Directory(cacheDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (e) {
      stderr.writeln(
        'mk_graphql_generator: could not delete cache directory '
        '$cacheDir ($e).',
      );
    }
  }
}
