import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';

class _Vars {
  final int id;
  const _Vars(this.id);
  Map<String, dynamic> toJson() => {'id': id};
}

// Mirrors what the code generator actually produces: a wrapper model
// (TData) whose toJson() does NOT recursively call .toJson() on a nested
// model field — json_serializable's default (explicit_to_json: false)
// behavior, which the generator relies on because opting classes into
// explicitToJson breaks fromJson for required fields (see
// mk_graphql_generator's dart_codegen.dart). InMemoryCache must handle this
// itself rather than assuming toJson() already produced a fully JSON-safe
// tree.
class _MediaEntity {
  final int id;
  final String? title;
  const _MediaEntity({required this.id, this.title});
  factory _MediaEntity.fromJson(Map<String, dynamic> json) => _MediaEntity(
        id: json['id'] as int,
        title: json['title'] as String?,
      );
  Map<String, dynamic> toJson() =>
      {'__typename': 'Media', 'id': id, 'title': title};
}

class _Wrapper {
  final _MediaEntity? media;
  const _Wrapper({this.media});
  factory _Wrapper.fromJson(Map<String, dynamic> json) => _Wrapper(
        media: json['Media'] == null
            ? null
            : _MediaEntity.fromJson(json['Media'] as Map<String, dynamic>),
      );
  // Deliberately NOT calling media?.toJson() here — this is the shape the
  // generator actually emits.
  Map<String, dynamic> toJson() => {'Media': media};
}

class _Req extends GraphQLRequest<_Wrapper, _Vars> {
  @override
  final _Vars variables;
  const _Req(this.variables);

  @override
  String get document => 'query GetMedia(\$id: Int) { Media(id: \$id) { id title } }';

  @override
  String get operationName => 'GetMedia';

  @override
  Map<String, dynamic> toJsonVars(_Vars vars) => vars.toJson();

  @override
  _Wrapper parseData(Map<String, dynamic> json) => _Wrapper.fromJson(json);

  @override
  _Req copyWithRequest({
    _Vars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _Wrapper? optimisticResponse,
  }) =>
      _Req(variables ?? this.variables);
}

void main() {
  test(
      'writeQuery/readQuery round-trip a wrapper whose toJson() embeds a '
      'raw (not pre-serialized) nested model object', () {
    final cache = InMemoryCache();
    const req = _Req(_Vars(1));

    cache.writeQuery(
      req,
      const _Wrapper(media: _MediaEntity(id: 1, title: 'Cowboy Bebop')),
    );

    final result = cache.readQuery(req);
    expect(result, isNotNull);
    expect(result?.media?.id, 1);
    expect(result?.media?.title, 'Cowboy Bebop');
  });

  test(
      'the nested entity is still extracted into its own normalized record '
      '(matchingQueryKeys by type works even for an un-pre-serialized '
      'nested field)', () {
    final cache = InMemoryCache();
    const req = _Req(_Vars(1));

    cache.writeQuery(
      req,
      const _Wrapper(media: _MediaEntity(id: 1, title: 'Cowboy Bebop')),
    );

    expect(cache.matchingQueryKeys(types: const ['Media']), isNotEmpty);
  });
}
