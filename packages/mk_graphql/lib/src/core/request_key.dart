import 'dart:convert';
import 'request.dart';

/// Per-instance memo of [computeRequestKey]'s result. A single
/// [GraphQLRequest] is immutable and commonly reused across several cache
/// calls within one request cycle (`readQuery`, `writtenAt`, `writeQuery`,
/// `watchQuery`/`evictQuery` from [GraphQLClient], plus the in-flight dedup
/// lookup) — without this, each of those re-serializes [GraphQLRequest.
/// variables] to canonical JSON from scratch. Keyed by object identity, so
/// it costs nothing extra once the request is garbage-collected.
final _requestKeyCache = Expando<String>('computeRequestKey');

/// Canonical identity for a [GraphQLRequest]: same operation, same document
/// text, and same variables (regardless of map key insertion order) all map
/// to the same key. Shared by [InMemoryCache]'s query storage keys, the
/// in-flight request dedup map, and the active-watcher registry on
/// [GraphQLClient] so all three agree on request identity.
String computeRequestKey(GraphQLRequest request) {
  final cached = _requestKeyCache[request];
  if (cached != null) return cached;

  final vars = request.toJsonVars(request.variables);
  final sortedVars = _canonicalJson(vars);
  final key = '${request.operationName}:${request.document.hashCode}:$sortedVars';
  _requestKeyCache[request] = key;
  return key;
}

String _canonicalJson(dynamic value) {
  if (value is Map) {
    final sortedKeys = value.keys.map((e) => e.toString()).toList()..sort();
    final buffer = StringBuffer('{');
    for (var i = 0; i < sortedKeys.length; i++) {
      if (i > 0) buffer.write(',');
      final k = sortedKeys[i];
      buffer.write('"$k":${_canonicalJson(value[k])}');
    }
    buffer.write('}');
    return buffer.toString();
  } else if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  } else {
    return jsonEncode(value);
  }
}
