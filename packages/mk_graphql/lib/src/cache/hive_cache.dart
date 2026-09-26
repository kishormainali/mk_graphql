import 'dart:async';
import 'package:hive_ce/hive_ce.dart';
import '../core/request.dart';
import 'cache.dart';
import 'in_memory_cache.dart';

/// A [Cache] that persists the normalized record store to a Hive [Box] so
/// it survives app restarts, while keeping every read/write on the fast
/// in-memory [InMemoryCache] path — the box is only a durable mirror,
/// updated in the background after each mutation.
///
/// Hive must already be initialized by the app (e.g. via `hive_ce_flutter`'s
/// `Hive.initFlutter()`, or plain `hive_ce`'s `Hive.init(path)`) before
/// calling [open] — this package stays storage-path-agnostic, consistent
/// with it never touching Flutter lifecycle/connectivity APIs elsewhere.
class HiveCache implements Cache {
  HiveCache._(this._delegate, this._box, this._onPersistError);

  final InMemoryCache _delegate;
  final Box<Map> _box;
  final void Function(Object error, StackTrace stackTrace)? _onPersistError;

  bool _persistScheduled = false;

  /// The record instance persisted under each key as of the last successful
  /// persist. [RecordSource.set] always installs a brand-new [Map] instance
  /// whenever a key is touched (see its source), so a key whose record is
  /// still `identical()` to the one captured here has not changed since —
  /// letting [_schedulePersist] write only the records that actually
  /// changed instead of dumping and rewriting the whole box on every batch.
  Map<String, Map<String, dynamic>> _lastPersisted = {};

  /// Opens (creating if needed) the Hive box named [boxName], hydrates a
  /// fresh [InMemoryCache] from its contents, and returns a ready
  /// [HiveCache].
  static Future<HiveCache> open({
    required String boxName,
    KeyGetter? keyGetter,
    void Function(Object error, StackTrace stackTrace)? onPersistError,
  }) async {
    final box = await Hive.openBox<Map>(boxName);
    final delegate = InMemoryCache(keyGetter: keyGetter);
    final seedData = <String, Map<String, dynamic>>{
      for (final key in box.keys)
        key as String: Map<String, dynamic>.from(box.get(key)!),
    };
    delegate.seed(seedData);
    final cache = HiveCache._(delegate, box, onPersistError);
    cache._lastPersisted = Map.of(delegate.exportAll());
    return cache;
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    Future.microtask(() async {
      _persistScheduled = false;
      try {
        final snapshot = _delegate.exportAll();

        final toPut = <String, Map<String, dynamic>>{};
        for (final entry in snapshot.entries) {
          if (!identical(_lastPersisted[entry.key], entry.value)) {
            toPut[entry.key] = entry.value;
          }
        }
        final toDelete = _lastPersisted.keys
            .where((key) => !snapshot.containsKey(key))
            .toList();

        if (toPut.isNotEmpty) await _box.putAll(toPut);
        if (toDelete.isNotEmpty) await _box.deleteAll(toDelete);

        _lastPersisted = Map.of(snapshot);
      } catch (e, st) {
        _onPersistError?.call(e, st);
      }
    });
  }

  @override
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _delegate.readQuery(request);

  @override
  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    _delegate.writeQuery(request, data);
    _schedulePersist();
  }

  @override
  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  }) =>
      _delegate.readFragment(id: id, fragmentName: fragmentName);

  @override
  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  }) {
    _delegate.writeFragment(id: id, data: data);
    _schedulePersist();
  }

  @override
  void evict(String key) {
    _delegate.evict(key);
    _schedulePersist();
  }

  @override
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    _delegate.evictQuery(request);
    _schedulePersist();
  }

  @override
  void clear() {
    _delegate.clear();
    _schedulePersist();
  }

  @override
  Stream<TData?> watchQuery<TData, TVars>(
          GraphQLRequest<TData, TVars> request) =>
      _delegate.watchQuery(request);

  @override
  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) =>
      _delegate.recordOptimistic(request, data);

  @override
  void removeOptimistic(String requestId) =>
      _delegate.removeOptimistic(requestId);

  @override
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _delegate.writtenAt(request);

  @override
  Iterable<String> matchingQueryKeys({
    List<String>? operationNames,
    List<String>? types,
  }) =>
      _delegate.matchingQueryKeys(
        operationNames: operationNames,
        types: types,
      );

  /// Closes the underlying Hive box. Call when the [GraphQLClient] that
  /// owns this cache is disposed.
  Future<void> close() => _box.close();
}
