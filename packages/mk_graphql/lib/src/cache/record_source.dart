/// Key-value storage map for normalized GraphQL entities and references.
class RecordSource {
  final Map<String, Map<String, dynamic>> _data = {};

  Map<String, dynamic>? get(String key) => _data[key];

  void set(String key, Map<String, dynamic> record) {
    if (_data.containsKey(key)) {
      _data[key] = {..._data[key]!, ...record};
    } else {
      _data[key] = Map<String, dynamic>.from(record);
    }
  }

  void delete(String key) => _data.remove(key);

  void clear() => _data.clear();

  Map<String, Map<String, dynamic>> toMap() => Map.unmodifiable(_data);

  static bool isRef(dynamic value) =>
      value is Map && value.length == 1 && value.containsKey('__ref');

  static String getRefId(dynamic value) => value['__ref'] as String;

  static Map<String, String> makeRef(String id) => {'__ref': id};
}
