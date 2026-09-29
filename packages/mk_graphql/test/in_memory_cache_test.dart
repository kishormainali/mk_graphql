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
  factory _MediaEntity.fromJson(Map<String, dynamic> json) =>
      _MediaEntity(id: json['id'] as int, title: json['title'] as String?);
  Map<String, dynamic> toJson() => {
    '__typename': 'Media',
    'id': id,
    'title': title,
  };
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
  String get document =>
      'query GetMedia(\$id: Int) { Media(id: \$id) { id title } }';

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
  }) => _Req(variables ?? this.variables);
}

/// Same shape as [_Req] but a distinct operation — used to prove the
/// read-cache's invalidation is correct across different queries that
/// share a normalized entity, not just within one query's own key.
class _ReqB extends GraphQLRequest<_Wrapper, _Vars> {
  @override
  final _Vars variables;
  const _ReqB(this.variables);

  @override
  String get document =>
      'query GetMediaB(\$id: Int) { Media(id: \$id) { id title } }';

  @override
  String get operationName => 'GetMediaB';

  @override
  Map<String, dynamic> toJsonVars(_Vars vars) => vars.toJson();

  @override
  _Wrapper parseData(Map<String, dynamic> json) => _Wrapper.fromJson(json);

  @override
  _ReqB copyWithRequest({
    _Vars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _Wrapper? optimisticResponse,
  }) => _ReqB(variables ?? this.variables);
}

/// Same shape as [_Req], but counts every [parseData] call via [onParse] —
/// used to prove the read-cache actually skips recomputation on a hit,
/// not just that it returns the right value (which a bug that always
/// recomputes would also do).
class _CountingReq extends GraphQLRequest<_Wrapper, _Vars> {
  _CountingReq(this.variables, this.onParse);

  @override
  final _Vars variables;
  final void Function() onParse;

  @override
  String get document =>
      'query GetMedia(\$id: Int) { Media(id: \$id) { id title } }';

  @override
  String get operationName => 'GetMedia';

  @override
  Map<String, dynamic> toJsonVars(_Vars vars) => vars.toJson();

  @override
  _Wrapper parseData(Map<String, dynamic> json) {
    onParse();
    return _Wrapper.fromJson(json);
  }

  @override
  _CountingReq copyWithRequest({
    _Vars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    _Wrapper? optimisticResponse,
  }) => _CountingReq(variables ?? this.variables, onParse);
}

void main() {
  test('writeQuery/readQuery round-trip a wrapper whose toJson() embeds a '
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

  test('the nested entity is still extracted into its own normalized record '
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

  group('readQuery memoization', () {
    test('reading the same query repeatedly with no write in between reuses '
        'the memoized result instead of denormalizing and parsing again', () {
      final cache = InMemoryCache();
      var parseCount = 0;
      final req = _CountingReq(const _Vars(1), () => parseCount++);

      cache.writeQuery(
        req,
        const _Wrapper(media: _MediaEntity(id: 1, title: 'Cowboy Bebop')),
      );
      expect(parseCount, 0, reason: 'writeQuery never calls parseData');

      final first = cache.readQuery(req);
      final second = cache.readQuery(req);
      final third = cache.readQuery(req);

      expect(
        parseCount,
        1,
        reason:
            'only the first read actually denormalizes and parses; '
            'the next two are served from the memoized result since '
            'nothing was written in between',
      );
      expect(second?.media?.title, first?.media?.title);
      expect(third?.media?.title, first?.media?.title);
    });

    test('a write to a different query sharing the same normalized entity '
        'invalidates a previously memoized read — the coarse invalidation '
        'never serves stale data', () {
      final cache = InMemoryCache();
      const reqA = _Req(_Vars(1));
      const reqB = _ReqB(_Vars(1));

      cache.writeQuery(
        reqA,
        const _Wrapper(media: _MediaEntity(id: 1, title: 'Original Title')),
      );
      final firstRead = cache.readQuery(reqA);
      expect(firstRead?.media?.title, 'Original Title');

      // A completely different query, but it writes the same Media:1
      // entity with a new title.
      cache.writeQuery(
        reqB,
        const _Wrapper(media: _MediaEntity(id: 1, title: 'Updated Title')),
      );

      final secondRead = cache.readQuery(reqA);
      expect(
        secondRead?.media?.title,
        'Updated Title',
        reason:
            'reqA\'s memoized read must be invalidated by a write '
            'that happened through a completely different query, since '
            'both reference the same normalized Media:1 entity',
      );
    });

    test('evicting a query invalidates its memoized read', () {
      final cache = InMemoryCache();
      const req = _Req(_Vars(1));

      cache.writeQuery(
        req,
        const _Wrapper(media: _MediaEntity(id: 1, title: 'Cowboy Bebop')),
      );
      expect(cache.readQuery(req), isNotNull);

      cache.evictQuery(req);

      expect(cache.readQuery(req), isNull);
    });
  });
}
