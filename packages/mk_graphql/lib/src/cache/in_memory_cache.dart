import 'dart:async';
import 'dart:convert';
import '../core/request.dart';
import 'cache.dart';
import 'record_source.dart';

/// Normalized in-memory cache store.
class InMemoryCache implements Cache {
  final RecordSource _store = RecordSource();
  final Map<String, RecordSource> _optimisticLayers = {};
  final KeyGetter _keyGetter;

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

  String _requestKey(GraphQLRequest req) {
    final vars = req.toJsonVars(req.variables);
    final sortedVars = _canonicalJson(vars);
    return '${req.operationName}:${req.document.hashCode}:$sortedVars';
  }

  static String _canonicalJson(dynamic value) {
    if (value is Map) {
      final sortedKeys = value.keys.map((e) => e.toString()).toList()..sort();
      final buffer = StringBuffer('{');
      for (var i = 0; i < sortedKeys.length; i++) {
        if (i > 0) buffer.write(',');
        final k = sortedKeys[i];
        buffer.write('"${k}":${_canonicalJson(value[k])}');
      }
      buffer.write('}');
      return buffer.toString();
    } else if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    } else {
      return jsonEncode(value);
    }
  }

  @override
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final queryKey = 'ROOT_QUERY:${_requestKey(request)}';
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
    final queryKey = 'ROOT_QUERY:${_requestKey(request)}';
    final json = _dataToJson(data);

    if (json is Map<String, dynamic>) {
      final normalized = _normalize(json);
      _store.set(queryKey, normalized);
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
  }

  @override
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request) {
    final queryKey = 'ROOT_QUERY:${_requestKey(request)}';
    evict(queryKey);
    _notifyWatchers(request);
  }

  @override
  void clear() {
    _store.clear();
    _optimisticLayers.clear();
  }

  @override
  Stream<TData?> watchQuery<TData, TVars>(
      GraphQLRequest<TData, TVars> request) {
    final key = _requestKey(request);
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

    // Emit initial value
    final initialData = readQuery(request);
    controller.add(initialData);

    return controller.stream;
  }

  @override
  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  ) {
    final layer = RecordSource();
    final queryKey = 'ROOT_QUERY:${_requestKey(request)}';
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

  void _notifyWatchers(GraphQLRequest request) {
    final key = _requestKey(request);
    final controllers = _watchers[key];
    if (controllers != null && controllers.isNotEmpty) {
      final data = readQuery(request);
      for (final controller in controllers) {
        controller.add(data);
      }
    }
  }
}
