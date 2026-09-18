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
    final queryKey = 'ROOT_QUERY:${computeRequestKey(request)}';
    final rootRecord = _getRecord(queryKey);
    if (rootRecord == null) return null;

    try {
      final denormalized = _denormalize(rootRecord);
      return request.parseData(denormalized);
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
      final normalized = _normalize(json);
      _store.set(queryKey, normalized);
      _writtenAt[key] = DateTime.now();
      _queryTypenames[key] = _collectTypenames(json);
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
  }

  @override
  void evict(String key) {
    _store.delete(key);
    if (key.startsWith('ROOT_QUERY:')) {
      final requestKey = key.substring('ROOT_QUERY:'.length);
      _writtenAt.remove(requestKey);
      _queryTypenames.remove(requestKey);
    }
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
      _notifyWatchers(request);
    }
  }

  @override
  void removeOptimistic(String requestId) {
    if (_optimisticLayers.containsKey(requestId)) {
      _optimisticLayers.remove(requestId);
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
      final typeMatch = types != null &&
          (_queryTypenames[key]?.any(types.contains) ?? false);
      return opMatch || typeMatch;
    }).toList();
  }

  Map<String, dynamic>? _getRecord(String key) {
    // Check optimistic layers first (most recent to oldest)
    for (final layer in _optimisticLayers.values.toList().reversed) {
      final opt = layer.get(key);
      if (opt != null) return opt;
    }
    return _store.get(key);
  }

  Map<String, dynamic> _normalize(Map<String, dynamic> json) {
    final result = <String, dynamic>{};

    json.forEach((key, value) {
      result[key] = _normalizeValue(value);
    });

    final entityKey = _keyGetter(json);
    if (entityKey != null) {
      _store.set(entityKey, result);
      return RecordSource.makeRef(entityKey);
    }

    return result;
  }

  dynamic _normalizeValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      final entityKey = _keyGetter(value);
      final normalizedMap = _normalize(value);
      if (entityKey != null) {
        return RecordSource.makeRef(entityKey);
      }
      return normalizedMap;
    } else if (value is List) {
      return value.map(_normalizeValue).toList();
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
  }
}
