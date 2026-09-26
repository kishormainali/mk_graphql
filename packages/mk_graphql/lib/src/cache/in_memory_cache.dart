import 'dart:async';
import '../core/request.dart';
import '../core/request_key.dart';
import 'cache.dart';
import 'record_source.dart';

/// Normalized in-memory cache store.
class InMemoryCache implements Cache {
  final RecordSource _store = RecordSource();
  final Map<String, RecordSource> _optimisticLayers = {};
  final KeyGetter _keyGetter;

  final Map<String, DateTime> _writtenAt = {};
  final Map<String, Set<String>> _queryTypenames = {};

  final _watchers = <String, Set<StreamController<dynamic>>>{};

  /// Bumped by every call that can change what [_getRecord]/[_denormalize]
  /// would produce for *any* key — [writeQuery], [writeFragment], [evict],
  /// [clear], [recordOptimistic], [removeOptimistic]. [_readCache] entries
  /// are stamped with the version current when they were computed, so a
  /// stale entry (anything written since) is never served — this is
  /// deliberately coarse (any write anywhere invalidates every cached read,
  /// not just reads of records that write actually touched), trading away
  /// some cache hits a precise per-record dependency graph would keep, for
  /// a scheme simple enough to be confident is never wrong. A real per-
  /// record invalidation graph is a legitimate future improvement, not a
  /// correctness requirement this trades away.
  int _version = 0;

  /// Per-query-key memo of [readQuery]'s already-denormalized-and-parsed
  /// result, valid only while [_ReadCacheEntry.version] still matches
  /// [_version]. Skips a full denormalize + [GraphQLRequest.parseData] walk
  /// for two routine cases: several [GraphQLClient.watchQuery] subscribers
  /// attaching to the same key back-to-back with no write in between (each
  /// otherwise independently denormalizes from scratch), and this class's
  /// own [watchQuery] computing an initial value that a caller going
  /// through `GraphQLClient.watchQuery` immediately recomputes itself (see
  /// that method's doc comment) — with this, the second computation is
  /// close to free instead of a second full walk.
  final Map<String, _ReadCacheEntry> _readCache = {};

  InMemoryCache({KeyGetter? keyGetter})
      : _keyGetter = keyGetter ?? defaultKeyGetter;

  static String? defaultKeyGetter(Map<String, dynamic> data) {
    if (data.containsKey('__typename')) {
      final typename = data['__typename'];
      if (data.containsKey('id') && data['id'] != null) {
        return '$typename:${data['id']}';
      }
      if (data.containsKey('_id') && data['_id'] != null) {
        return '$typename:${data['_id']}';
      }
    }
    return null;
  }

  @override
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final key = computeRequestKey(request);

    final cached = _readCache[key];
    if (cached != null && cached.version == _version) {
      return cached.data as TData?;
    }

    final queryKey = 'ROOT_QUERY:$key';
    final rootRecord = _getRecord(queryKey);
    if (rootRecord == null) {
      _readCache.remove(key);
      return null;
    }

    try {
      final denormalized = _denormalize(rootRecord);
      final data = request.parseData(denormalized);
      _readCache[key] = _ReadCacheEntry(_version, data);
      return data;
    } catch (_) {
      return null;
    }
  }

  @override
  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    final key = computeRequestKey(request);
    final queryKey = 'ROOT_QUERY:$key';
    final json = _dataToJson(data);

    if (json is Map<String, dynamic>) {
      // Collected during the same walk that builds [normalized] (see
      // _normalize/_normalizeValue's `typenames` parameter) rather than by
      // denormalizing it again afterwards purely to re-walk it for
      // __typename — a write with a large nested/paginated response
      // otherwise pays for two full tree walks where one already visits
      // every field.
      final typenames = <String>{};
      final normalized = _normalize(json, typenames);
      _store.set(queryKey, normalized);
      _writtenAt[key] = DateTime.now();
      _queryTypenames[key] = typenames;
      _version++;
      _notifyWatchers(request);
    }
  }

  @override
  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  }) {
    final record = _getRecord(id);
    if (record == null) return null;
    return _denormalize(record);
  }

  @override
  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  }) {
    final normalized = _normalize(data);
    _store.set(id, normalized);
    _version++;
  }

  @override
  void evict(String key) {
    _store.delete(key);
    if (key.startsWith('ROOT_QUERY:')) {
      final requestKey = key.substring('ROOT_QUERY:'.length);
      _writtenAt.remove(requestKey);
      _queryTypenames.remove(requestKey);
      _readCache.remove(requestKey);
    }
    _version++;
  }

  @override
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    evict(queryKey);
    _notifyWatchers(request);
  }

  @override
  void clear() {
    _store.clear();
    _optimisticLayers.clear();
    _writtenAt.clear();
    _queryTypenames.clear();
    _readCache.clear();
    _version++;
  }

  @override
  Stream<TData?> watchQuery<TData, TVars>(
      GraphQLRequest<TData, TVars> request) {
    final key = computeRequestKey(request);
    final controller = StreamController<TData?>.broadcast();

    _watchers
        .putIfAbsent(key, () => {})
        .add(controller as StreamController<dynamic>);

    controller.onCancel = () {
      _watchers[key]?.remove(controller);
      if (_watchers[key]?.isEmpty ?? false) {
        _watchers.remove(key);
      }
    };

    // Emit initial value.
    final initialData = readQuery(request);
    // NOTE: this add() is currently unreachable for callers going through
    // GraphQLClient.watchQuery — its own listener isn't attached to this
    // broadcast stream yet when this fires, so the event is silently
    // dropped, and client.dart works around it by seeding its outer
    // controller itself (`controller.add(cache.readQuery(req))` inside its
    // onListen). If this drop is ever "fixed" here in isolation,
    // GraphQLClient.watchQuery will start double-emitting its first value —
    // fix both together, or remove the client-side seed workaround first.
    controller.add(initialData);

    return controller.stream;
  }

  @override
  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    final layer = RecordSource();
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    final json = _dataToJson(data);

    if (json is Map<String, dynamic>) {
      final normalized = _normalize(json);
      layer.set(queryKey, normalized);
      _optimisticLayers[request.requestId] = layer;
      _version++;
      _notifyWatchers(request);
    }
  }

  @override
  void removeOptimistic(String requestId) {
    if (_optimisticLayers.containsKey(requestId)) {
      _optimisticLayers.remove(requestId);
      _version++;
    }
  }

  @override
  DateTime? writtenAt<TData, TVars>(GraphQLRequest<TData, TVars> request) =>
      _writtenAt[computeRequestKey(request)];

  @override
  Iterable<String> matchingQueryKeys({
    List<String>? operationNames,
    List<String>? types,
  }) {
    if (operationNames == null && types == null) return const [];
    return _writtenAt.keys.where((key) {
      final opMatch = operationNames != null &&
          operationNames.any((name) => key.startsWith('$name:'));
      final typeMatch =
          types != null && (_queryTypenames[key]?.any(types.contains) ?? false);
      return opMatch || typeMatch;
    }).toList();
  }

  Map<String, dynamic>? _getRecord(String key) {
    // The overwhelmingly common case — no optimistic response in flight —
    // skips the allocation of a reversed layer list entirely; this runs
    // once per ref per record on every denormalizing read.
    if (_optimisticLayers.isNotEmpty) {
      // Check optimistic layers first (most recent to oldest).
      for (final layer in _optimisticLayers.values.toList().reversed) {
        final opt = layer.get(key);
        if (opt != null) return opt;
      }
    }
    return _store.get(key);
  }

  /// Normalizes [json], writing every nested entity it finds into [_store].
  ///
  /// When [typenames] is supplied, every `__typename` this walk encounters
  /// — at this map and every map nested under it, whether or not that
  /// nested map ends up replaced by a [RecordSource] ref — is added to it.
  /// This lets [writeQuery] collect a write's touched typenames in the same
  /// pass that builds the normalized record, instead of denormalizing the
  /// result afterwards purely to re-walk it for __typename.
  Map<String, dynamic> _normalize(
    Map<String, dynamic> json, [
    Set<String>? typenames,
  ]) {
    final result = <String, dynamic>{};

    json.forEach((key, value) {
      result[key] = _normalizeValue(value, typenames);
    });

    final t = result['__typename'];
    if (t is String) typenames?.add(t);

    final entityKey = _keyGetter(json);
    if (entityKey != null) {
      _store.set(entityKey, result);
      return RecordSource.makeRef(entityKey);
    }

    return result;
  }

  dynamic _normalizeValue(dynamic value, [Set<String>? typenames]) {
    if (value is Map<String, dynamic>) {
      final entityKey = _keyGetter(value);
      final normalizedMap = _normalize(value, typenames);
      if (entityKey != null) {
        return RecordSource.makeRef(entityKey);
      }
      return normalizedMap;
    } else if (value is List) {
      return value.map((v) => _normalizeValue(v, typenames)).toList();
    } else if (value != null &&
        value is! String &&
        value is! num &&
        value is! bool) {
      // A nested typed object (e.g. a generated freezed model field) that
      // the parent's own toJson() didn't already recursively convert —
      // json_serializable only does this when a class opts into
      // `explicitToJson: true`, which the generator's classes don't (it
      // breaks fromJson for classes with required fields; see
      // dart_codegen.dart). Coerce it into a plain JSON map ourselves so
      // normalize/denormalize always operates on JSON-safe data, whatever
      // the field's own toJson() behavior is.
      final asJson = _dataToJson(value);
      if (asJson is Map<String, dynamic>) {
        return _normalizeValue(asJson, typenames);
      }
    }
    return value;
  }

  dynamic _denormalize(dynamic value) {
    if (RecordSource.isRef(value)) {
      final id = RecordSource.getRefId(value);
      final refRecord = _getRecord(id);
      if (refRecord == null) return null;
      return _denormalize(refRecord);
    } else if (value is Map<String, dynamic>) {
      final map = <String, dynamic>{};
      value.forEach((k, v) {
        map[k] = _denormalize(v);
      });
      return map;
    } else if (value is List) {
      return value.map(_denormalize).toList();
    }
    return value;
  }

  dynamic _dataToJson(dynamic data) {
    if (data == null) return null;
    try {
      return (data as dynamic).toJson();
    } catch (_) {
      return data;
    }
  }

  Set<String> _collectTypenames(dynamic json) {
    final result = <String>{};
    void walk(dynamic value) {
      if (value is Map) {
        final t = value['__typename'];
        if (t is String) result.add(t);
        value.values.forEach(walk);
      } else if (value is List) {
        value.forEach(walk);
      }
    }

    walk(json);
    return result;
  }

  void _notifyWatchers(GraphQLRequest request) {
    final key = computeRequestKey(request);
    final controllers = _watchers[key];
    if (controllers != null && controllers.isNotEmpty) {
      final data = readQuery(request);
      for (final controller in controllers) {
        controller.add(data);
      }
    }
  }

  /// Dumps the entire normalized record store — never includes optimistic
  /// layers. Used only by [HiveCache] to mirror state to disk.
  Map<String, Map<String, dynamic>> exportAll() => _store.toMap();

  /// Bulk-loads [records] into the store. Used only by [HiveCache.open] to
  /// hydrate a fresh [InMemoryCache] from a previously persisted box, before
  /// any reads/writes happen.
  ///
  /// Every seeded `ROOT_QUERY:` record also gets its `writtenAt` and
  /// typename bookkeeping populated, so a hydrated query is immediately
  /// visible to [writtenAt] and [matchingQueryKeys] (and therefore to
  /// `GraphQLClient.invalidateQueries`, by operation name *and* by type)
  /// without waiting for a live network response to re-write it. Hydrated
  /// data is timestamped as [DateTime.fromMillisecondsSinceEpoch]`(0)` —
  /// arbitrarily old, not "just written" — so it stays correctly stale under
  /// *any* configured `staleTime`, not just the default `Duration.zero`: a
  /// disk-persisted `HiveCache` value must never be treated as fresher than
  /// it can actually know it is, since the write that produced it may be
  /// long gone (a previous app run, possibly days ago).
  void seed(Map<String, Map<String, dynamic>> records) {
    for (final entry in records.entries) {
      _store.set(entry.key, entry.value);
    }
    // Second pass: refs inside one root query may point at entity records
    // that appear later in [records], so typenames can only be collected
    // once the whole store is populated.
    const rootPrefix = 'ROOT_QUERY:';
    final arbitrarilyOld = DateTime.fromMillisecondsSinceEpoch(0);
    for (final entry in records.entries) {
      if (!entry.key.startsWith(rootPrefix)) continue;
      final requestKey = entry.key.substring(rootPrefix.length);
      _writtenAt[requestKey] = arbitrarilyOld;
      _queryTypenames[requestKey] = _collectTypenames(
        _denormalize(entry.value),
      );
    }
    _version++;
  }
}

/// A [InMemoryCache._readCache] entry: [data] as of [version] — see that
/// field's doc comment for the invalidation scheme this is part of.
class _ReadCacheEntry {
  const _ReadCacheEntry(this.version, this.data);
  final int version;
  final dynamic data;
}
