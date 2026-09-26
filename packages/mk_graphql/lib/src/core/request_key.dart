import 'dart:convert';
import 'request.dart';

/// Canonical identity for a [GraphQLRequest]: same operation, same document
/// text, and same variables (regardless of map key insertion order) all map
/// to the same key. Shared by [InMemoryCache]'s query storage keys, the
/// in-flight request dedup map, and the active-watcher registry on
/// [GraphQLClient] so all three agree on request identity.
String computeRequestKey(GraphQLRequest request) {
  final vars = request.toJsonVars(request.variables);
  final sortedVars = _canonicalJson(vars);
  return '${request.operationName}:${request.document.hashCode}:$sortedVars';
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
