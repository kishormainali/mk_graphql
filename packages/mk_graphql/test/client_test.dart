import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// ---------------------------------------------------------------------------
// Test domain types
// ---------------------------------------------------------------------------

class _TestVars {
  final String id;
  const _TestVars(this.id);
  Map<String, dynamic> toJson() => {'id': id};
}

class _TestData {
  final String? id;
  final String? name;
  const _TestData({this.id, this.name});
  factory _TestData.fromJson(Map<String, dynamic> json) =>
      _TestData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

class _TestReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestReq(
    this.variables, {
    super.requestId,
    super.cancelToken,
    super.fetchPolicy,
    super.errorPolicy,
    super.headers,
    super.optimisticResponse,
    super.staleTime,
    super.cacheTime,
    super.retry,
    super.refetchInterval,
  });

  @override
  String get document => 'query Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestReq(
        variables ?? this.variables,
        fetchPolicy: fetchPolicy ?? this.fetchPolicy,
        errorPolicy: errorPolicy ?? this.errorPolicy,
        headers: headers ?? this.headers,
        cancelToken: cancelToken ?? this.cancelToken,
        optimisticResponse: optimisticResponse ?? this.optimisticResponse,
        requestId: requestId,
        staleTime: staleTime,
        cacheTime: cacheTime,
        retry: retry,
        refetchInterval: refetchInterval,
      );
}

class _TestMutationReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _TestMutationReq(this.variables);

  @override
  String get document => 'mutation Test { user { id name } }';

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _TestMutationReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _TestMutationReq(variables ?? this.variables);
}

class _TypedData {
  final String? id;
  final String? name;
  const _TypedData({this.id, this.name});
  factory _TypedData.fromJson(Map<String, dynamic> json) =>
      _TypedData(id: json['id'] as String?, name: json['name'] as String?);
  Map<String, dynamic> toJson() =>
      {'__typename': 'User', 'id': id, 'name': name};
}

class _TypedTestReq extends GraphQLRequest<_TypedData, _TestVars> {
  @override
  final _TestVars variables;
  _TypedTestReq(this.variables);

  @override
  String get document => 'query TypedTest { user { id name } }';

  @override
  String get operationName => 'TypedTest';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TypedData parseData(Map<String, dynamic> json) => _TypedData.fromJson(json);

  @override
  _TypedTestReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TypedData? optimisticResponse,
  }) =>
      _TypedTestReq(variables ?? this.variables);
}

// ---------------------------------------------------------------------------
// gql_link test doubles
// ---------------------------------------------------------------------------

class _CountingLink extends Link {
  final void Function() onRequest;
  _CountingLink(this.onRequest);

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    onRequest();
    yield const gql.Response(data: {'id': '1', 'name': 'Dedup'}, response: {});
  }
}

class _CapturingLink extends Link {
  gql.Request? captured;

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    captured = req;
    yield const gql.Response(data: {}, response: {});
  }
}

/// Mirrors what the generator emits: a class-level cached [DocumentNode]
/// overriding [GraphQLRequest.documentNode] so the client never touches the
/// string-keyed parse cache for this request type.
class _PreparsedDocReq extends GraphQLRequest<_TestData, _TestVars> {
  @override
  final _TestVars variables;
  _PreparsedDocReq(this.variables);

  static final DocumentNode _documentNode =
      parseString('query Preparsed { user { id name } }');

  @override
  String get document => 'query Preparsed { user { id name } }';

  @override
  DocumentNode get documentNode => _documentNode;

  @override
  String get operationName => 'Preparsed';

  @override
  Map<String, dynamic> toJsonVars(_TestVars vars) => vars.toJson();

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _PreparsedDocReq copyWithRequest({
    _TestVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _PreparsedDocReq(variables ?? this.variables);
}

class _ErrorLink extends Link {
  final List<gql.GraphQLError> errors;
  const _ErrorLink({required this.errors});

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    yield gql.Response(errors: errors, response: const {});
  }
}

/// Seeds the in-memory test double backing [TokenStorage.i] — GraphQLClient
/// now always talks to the [TokenStorage] singleton (no DI), so tests reset
/// its backing [FlutterSecureStorage] mock platform and go through
/// [TokenStorage.saveToken] rather than poking storage keys directly.
Future<void> _seedTokenStorage({String? accessToken, String? refreshToken}) {
  FlutterSecureStorage.setMockInitialValues({});
  if (accessToken == null) return Future.value();
  return TokenStorage.i.saveToken(
      TokenPair(accessToken: accessToken, refreshToken: refreshToken));
}

/// Throws [exception] on the first call (simulating a terminating link like
/// DioLink throwing ServerException for a non-2xx HTTP status), then
/// succeeds on any retry.
class _ServerExceptionOnceLink extends Link {
  final ServerException exception;
  int calls = 0;
  _ServerExceptionOnceLink(this.exception);

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    calls++;
    if (calls == 1) {
      throw exception;
    }
    yield const gql.Response(data: {'ok': true}, response: {});
  }
}

/// Throws a [NetworkException]-mapping [DioException] the first [failTimes]
/// calls, then succeeds.
class _FlakyLink extends Link {
  final int failTimes;
  final void Function() onAttempt;
  int _calls = 0;
  _FlakyLink({required this.failTimes, required this.onAttempt});

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    onAttempt();
    _calls++;
    if (_calls <= failTimes) {
      throw dio.DioException(
        requestOptions: dio.RequestOptions(path: '/graphql'),
        type: dio.DioExceptionType.connectionError,
      );
    }
    yield const gql.Response(
        data: {'id': '1', 'name': 'Recovered'}, response: {});
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // TokenStorage.i lazily constructs a SharedPreferencesAsync on first use
  // (for clearOnInstall) — give it an in-memory platform so that doesn't
  // throw, even though these tests never call clearOnInstall themselves.
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  group('InMemoryCache Tests', () {
    test('writeQuery and readQuery normalised caching', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      const data = _TestData(id: '123', name: 'Alice');

      cache.writeQuery(req, data);
      final read = cache.readQuery(req);

      expect(read, isNotNull);
      expect(read?.id, equals('123'));
      expect(read?.name, equals('Alice'));
    });

    test('evict removes entry from cache', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));
      expect(cache.readQuery(req), isNotNull);
      cache.evictQuery(req);
      expect(cache.readQuery(req), isNull);
    });

    test('optimistic response recording and removal', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'), requestId: 'req_1');
      const optimisticData = _TestData(id: '123', name: 'Optimistic Alice');

      cache.recordOptimistic(req, optimisticData);
      expect(cache.readQuery(req)?.name, equals('Optimistic Alice'));

      cache.removeOptimistic('req_1');
      expect(cache.readQuery(req), isNull);
    });

    test('writtenAt is null before any write and set after writeQuery', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      expect(cache.writtenAt(req), isNull);

      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));
      final writtenAt = cache.writtenAt(req);
      expect(writtenAt, isNotNull);
      expect(DateTime.now().difference(writtenAt!).inSeconds, lessThan(5));
    });

    test('matchingQueryKeys matches by operationName and by typename', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));

      expect(
        cache.matchingQueryKeys(operationNames: ['Test']),
        isNotEmpty,
      );
      expect(
        cache.matchingQueryKeys(operationNames: ['SomethingElse']),
        isEmpty,
      );
      expect(cache.matchingQueryKeys(), isEmpty,
          reason: 'no operationNames or types given → no matches');
    });

    test('evict clears writtenAt bookkeeping for the evicted query', () {
      final cache = InMemoryCache();
      final req = _TestReq(const _TestVars('123'));
      cache.writeQuery(req, const _TestData(id: '123', name: 'Alice'));
      expect(cache.writtenAt(req), isNotNull);

      cache.evictQuery(req);
      expect(cache.writtenAt(req), isNull);
    });
  });

  group('GraphQLError parsing', () {
    test('fromJson maps all fields', () {
      final error = GraphQLError.fromJson({
        'message': 'Field error',
        'locations': [
          {'line': 2, 'column': 4}
        ],
        'path': ['user', 'email'],
      });
      expect(error.message, equals('Field error'));
      expect(error.locations?.first.line, equals(2));
      expect(error.path, equals(['user', 'email']));
    });
  });

  group('GraphQLResponse', () {
    test('hasErrors is true when errors list is non-empty', () {
      const response = GraphQLResponse<_TestData>(
        errors: [GraphQLError(message: 'oops')],
        source: ResponseSource.network,
      );
      expect(response.hasErrors, isTrue);
      expect(response.data, isNull);
    });

    test('copyWith replaces only specified fields', () {
      const original = GraphQLResponse<_TestData>(
          data: _TestData(id: '1'), source: ResponseSource.network);
      final copy =
          original.copyWith(source: ResponseSource.cache, loading: true);
      expect(copy.data?.id, equals('1'));
      expect(copy.source, equals(ResponseSource.cache));
      expect(copy.loading, isTrue);
    });
  });

  group('GraphQLClient', () {
    test('constructs without auth params', () {
      expect(
        GraphQLClient(
            url: 'https://api.example.com/graphql', addTypename: false),
        isA<GraphQLClient>(),
      );
    });

    test('constructs with auth params (AuthLink built internally)', () {
      expect(
        GraphQLClient(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer tok'},
        ),
        isA<GraphQLClient>(),
      );
    });

    test('constructs with wsUrl and sseUrl subscription links', () {
      final client = GraphQLClient(
        url: 'https://api.example.com/graphql',
        wsUrl: 'wss://api.example.com/graphql',
      );
      expect(client, isA<GraphQLClient>());

      final sseClient = GraphQLClient(
        url: 'https://api.example.com/graphql',
        sseUrl: 'https://api.example.com/sse',
      );
      expect(sseClient, isA<GraphQLClient>());
    });

    test(
        'GraphQLClient.create resolves a synchronous cache and builds a client',
        () async {
      final client = await GraphQLClient.create(
        url: 'https://api.example.com/graphql',
        cache: InMemoryCache(),
      );
      expect(client, isA<GraphQLClient>());
    });

    test('GraphQLClient.create awaits a FutureOr<Cache> before constructing',
        () async {
      final cache = InMemoryCache();
      final client = await GraphQLClient.create(
        url: 'https://api.example.com/graphql',
        cache: Future.value(cache),
      );
      expect(client.cache, same(cache));
    });

    test('GraphQLClient.create defaults to a fresh InMemoryCache when cache '
        'is omitted', () async {
      final client =
          await GraphQLClient.create(url: 'https://api.example.com/graphql');
      expect(client.cache, isA<InMemoryCache>());
    });

    test('maps Dio network error to GraphQLException', () {
      final client = GraphQLClient(
          url: 'https://invalid-host-unreachable-12345.com/graphql');
      expect(
        () => client.future(_TestReq(const _TestVars('1'))),
        throwsA(isA<GraphQLException>()),
      );
    });

    test('supports CancelToken via request or future parameter', () async {
      final token = CancelToken();
      token.cancel('Operation cancelled by user');

      final reqWithToken = _TestReq(const _TestVars('1'), cancelToken: token);
      expect(reqWithToken.cancelToken, equals(token));

      final client = GraphQLClient(
          url: 'https://invalid-host-unreachable-12345.com/graphql');

      expect(
        () => client.future(_TestReq(const _TestVars('1')), cancelToken: token),
        throwsA(isA<RequestCancelledException>()),
      );
    });

    test(
        'deduplicates concurrent identical queries into a single network call',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      final results = await Future.wait([
        for (var i = 0; i < 5; i++) client.future(_TestReq(const _TestVars('1'))),
      ]);

      expect(callCount, equals(1),
          reason: 'identical concurrent queries must share one network call');
      expect(results, hasLength(5));
    });

    test('mutations are never deduplicated, even with identical variables',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      await Future.wait([
        for (var i = 0; i < 3; i++)
          client.future(_TestMutationReq(const _TestVars('1'))),
      ]);

      expect(callCount, equals(3),
          reason: 'mutations must each hit the network independently');
    });

    test('a request with an explicit cancelToken is never deduplicated',
        () async {
      var callCount = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        callCount++;
      }));

      await Future.wait([
        client.future(_TestReq(const _TestVars('1'),
            cancelToken: CancelToken())),
        client.future(_TestReq(const _TestVars('1'),
            cancelToken: CancelToken())),
      ]);

      expect(callCount, equals(2));
    });

    test('retries a query on NetworkException up to maxAttempts, then succeeds',
        () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 2, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      final result = await client.future(_TestReq(const _TestVars('1')));
      expect(attempts, equals(3));
      expect(result.name, equals('Recovered'));
    });

    test('exhausts retries and surfaces the final failure', () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 10, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.future(_TestReq(const _TestVars('1'))),
        throwsA(isA<NetworkException>()),
      );
      expect(attempts, equals(2));
    });

    test('mutations never auto-retry by default, even with defaultRetry set',
        () async {
      var attempts = 0;
      final client = GraphQLClient.fromLink(
        _FlakyLink(failTimes: 10, onAttempt: () => attempts++),
        defaultRetry: const RetryOptions(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
        ),
      );

      await expectLater(
        client.future(_TestMutationReq(const _TestVars('1'))),
        throwsA(isA<NetworkException>()),
      );
      expect(attempts, equals(1));
    });
  });

  group('GraphQLClient refreshCallback / TokenStorage.i', () {
    test('isAuthenticated reflects TokenStorage.i', () async {
      await _seedTokenStorage();
      final client = GraphQLClient(
          url: 'https://api.example.com/graphql', addTypename: false);
      expect(await client.isAuthenticated, isFalse);

      await _seedTokenStorage(
          accessToken: 'access-1', refreshToken: 'refresh-1');
      expect(await client.isAuthenticated, isTrue);
    });

    test(
        'refreshCallback receives the stored refresh token, persists the new '
        'TokenPair, and the failed request is retried with the new access token',
        () async {
      await _seedTokenStorage(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      var callCount = 0;
      final capturedHeaders = <Map<String, dynamic>>[];
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        capturedHeaders.add(Map.from(options.headers));
        if (callCount == 1) {
          return dio.ResponseBody.fromString(
            jsonEncode({
              'errors': [
                {
                  'message': 'Unauthenticated',
                  'extensions': {'code': 'UNAUTHENTICATED'},
                }
              ]
            }),
            401,
            headers: {
              'content-type': ['application/json']
            },
          );
        }
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {'id': '123', 'name': 'Refreshed User'}
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      String? refreshTokenSeen;
      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        addTypename: false,
        refreshCallback: (refreshClient, refreshToken) async {
          refreshTokenSeen = refreshToken;
          return const TokenPair(
              accessToken: 'new-access', refreshToken: 'new-refresh');
        },
      );

      final result = await client.future(_TestReq(const _TestVars('123')));

      expect(result.name, equals('Refreshed User'));
      expect(callCount, equals(2));
      expect(refreshTokenSeen, equals('old-refresh'));
      expect(capturedHeaders[0]['Authorization'], equals('Bearer old-access'));
      expect(capturedHeaders[1]['Authorization'], equals('Bearer new-access'));
      expect(await TokenStorage.i.accessToken, equals('new-access'));
      expect(await TokenStorage.i.refreshToken, equals('new-refresh'));
    });

    test(
        'defaultHeaders reach the token-refresh request too, not just the '
        'original one — AuthLink must share the client\'s configured Dio '
        'instance rather than falling back to an unconfigured one', () async {
      await _seedTokenStorage(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      var callCount = 0;
      final capturedHeaders = <Map<String, dynamic>>[];
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        capturedHeaders.add(Map.from(options.headers));
        if (callCount == 1) {
          return dio.ResponseBody.fromString(
            jsonEncode({
              'errors': [
                {
                  'message': 'Unauthenticated',
                  'extensions': {'code': 'UNAUTHENTICATED'},
                }
              ]
            }),
            401,
            headers: {
              'content-type': ['application/json']
            },
          );
        }
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {'id': '123', 'name': 'Refreshed User'}
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        defaultHeaders: {'X-Client-Id': 'test-client'},
        addTypename: false,
        refreshCallback: (refreshClient, refreshToken) async =>
            const TokenPair(accessToken: 'new-access'),
      );

      await client.future(_TestReq(const _TestVars('123')));

      expect(callCount, equals(2));
      expect(capturedHeaders[0]['X-Client-Id'], equals('test-client'),
          reason: 'original request must carry defaultHeaders');
      expect(capturedHeaders[1]['X-Client-Id'], equals('test-client'),
          reason: 'refresh request must carry defaultHeaders too — it runs '
              'through the same configured Dio, not a second bare one');
    });

    test(
        'refreshCallback is never called without a stored refresh token; '
        'revokes immediately instead', () async {
      await _seedTokenStorage(accessToken: 'old-access');
      var refreshCalls = 0;
      var listenerCalled = false;
      GraphQLClient.registerRevokeTokenListener(() => listenerCalled = true);

      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        return dio.ResponseBody.fromString(
          jsonEncode({
            'errors': [
              {
                'message': 'Unauthenticated',
                'extensions': {'code': 'UNAUTHENTICATED'},
              }
            ]
          }),
          401,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        addTypename: false,
        refreshCallback: (_, __) async {
          refreshCalls++;
          return const TokenPair(accessToken: 'should-not-happen');
        },
      );

      await expectLater(
        client.future(_TestReq(const _TestVars('123'))),
        throwsA(isA<GraphQLException>()),
      );

      expect(refreshCalls, equals(0));
      expect(listenerCalled, isTrue);
      expect(await TokenStorage.i.accessToken, isNull);
      GraphQLClient.clearRevokeTokenListeners();
    });

    test(
        'multiple concurrent requests failing at once trigger only one '
        'refreshCallback call and all retry successfully', () async {
      await _seedTokenStorage(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );
      var refreshCalls = 0;

      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        final authHeader = options.headers['Authorization'];
        if (authHeader == 'Bearer old-access') {
          return dio.ResponseBody.fromString(
            jsonEncode({
              'errors': [
                {
                  'message': 'Unauthenticated',
                  'extensions': {'code': 'UNAUTHENTICATED'},
                }
              ]
            }),
            401,
            headers: {
              'content-type': ['application/json']
            },
          );
        }
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {'id': '123', 'name': 'Refreshed User'}
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        addTypename: false,
        refreshCallback: (refreshClient, refreshToken) async {
          refreshCalls++;
          // Widen the window so all 5 concurrent 401s queue behind this
          // single refresh instead of each triggering their own.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return const TokenPair(
              accessToken: 'new-access', refreshToken: 'new-refresh');
        },
      );

      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          client.future(_TestReq(const _TestVars('123'))),
      ]);

      expect(refreshCalls, equals(1),
          reason: 'refreshCallback must be deduped across concurrent 401s');
      expect(results, hasLength(5));
      expect(
          results.map((d) => d.name), everyElement(equals('Refreshed User')));
    });

    test(
        'refreshTokenHeader attaches the refresh token to requests made '
        'through the internal refresh client, not the normal access-token '
        'header', () async {
      await _seedTokenStorage(
        accessToken: 'old-access',
        refreshToken: 'the-refresh-token',
      );

      var callCount = 0;
      final capturedHeaders = <Map<String, dynamic>>[];
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        capturedHeaders.add(Map.from(options.headers));
        if (callCount == 1) {
          return dio.ResponseBody.fromString(
            jsonEncode({
              'errors': [
                {
                  'message': 'Unauthenticated',
                  'extensions': {'code': 'UNAUTHENTICATED'},
                }
              ]
            }),
            401,
            headers: {
              'content-type': ['application/json']
            },
          );
        }
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {'id': '123', 'name': 'Refreshed User'}
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        addTypename: false,
        refreshTokenHeader: (_) async =>
            {'Authorization': 'Bearer the-refresh-token'},
        refreshCallback: (refreshClient, refreshToken) async {
          // Hits the mock Dio through the internal refresh client's own
          // pipeline, which is where refreshTokenHeader's headers apply.
          await refreshClient.future(_TestReq(const _TestVars('refresh')));
          return const TokenPair(accessToken: 'new-access');
        },
      );

      await client.future(_TestReq(const _TestVars('123')));

      expect(callCount, equals(3));
      expect(capturedHeaders[0]['Authorization'], equals('Bearer old-access'),
          reason: 'original request carries the access-token header');
      expect(capturedHeaders[1]['Authorization'],
          equals('Bearer the-refresh-token'),
          reason: 'the request made via refreshClient inside refreshCallback '
              'carries the refresh-token header instead');
      expect(capturedHeaders[2]['Authorization'], equals('Bearer new-access'),
          reason: 'the retried original request carries the new access token');
    });

    test(
        'without refreshTokenHeader, a request made through the internal '
        'refresh client carries no Authorization header at all — the '
        'access-token header must never leak onto refresh requests', () async {
      await _seedTokenStorage(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      var callCount = 0;
      final capturedHeaders = <Map<String, dynamic>>[];
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        capturedHeaders.add(Map.from(options.headers));
        if (callCount == 1) {
          return dio.ResponseBody.fromString(
            jsonEncode({
              'errors': [
                {
                  'message': 'Unauthenticated',
                  'extensions': {'code': 'UNAUTHENTICATED'},
                }
              ]
            }),
            401,
            headers: {
              'content-type': ['application/json']
            },
          );
        }
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {'id': '123', 'name': 'Refreshed User'}
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final client = GraphQLClient(
        url: 'https://example.com/graphql',
        dio: dioInstance,
        addTypename: false,
        refreshCallback: (refreshClient, refreshToken) async {
          // No refreshTokenHeader configured — this request through
          // refreshClient must not inherit the outer AuthLink's
          // accessTokenHeader, nor default to any header of its own.
          await refreshClient.future(_TestReq(const _TestVars('refresh')));
          return const TokenPair(accessToken: 'new-access');
        },
      );

      await client.future(_TestReq(const _TestVars('123')));

      expect(callCount, equals(3));
      expect(capturedHeaders[0]['Authorization'], equals('Bearer old-access'),
          reason: 'original request carries the access-token header');
      expect(capturedHeaders[1].containsKey('Authorization'), isFalse,
          reason: 'the refresh client request must carry no Authorization '
              'header when refreshTokenHeader is not configured');
      expect(capturedHeaders[2]['Authorization'], equals('Bearer new-access'),
          reason: 'the retried original request carries the new access token');
    });
  });

  group('AuthLink', () {
    test('triggers revoke token listeners when refresh fails', () async {
      bool listenerCalled = false;
      GraphQLClient.registerRevokeTokenListener(() => listenerCalled = true);

      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) => throw Exception('Refresh failed'),
        ),
        _ErrorLink(errors: [
          const gql.GraphQLError(
              message: 'Unauthorized', extensions: {'code': 'UNAUTHORIZED'}),
        ]),
      ]);

      await expectLater(
        chain
            .request(gql.Request(
              operation: gql.Operation(
                document: parseString('query Test { user { id } }'),
                operationName: 'Test',
              ),
            ))
            .drain<void>(),
        // The real refresh failure reason is surfaced instead of silently
        // ending the stream.
        throwsA(isA<RevokeTokenException>()
            .having((e) => e.message, 'message', contains('Refresh failed'))),
      );

      expect(listenerCalled, isTrue);
      GraphQLClient.clearRevokeTokenListeners();
    });

    test('deduplicates concurrent token refreshes', () async {
      int refreshCount = 0;

      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async {
            refreshCount++;
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return {'Authorization': 'Bearer new'};
          },
        ),
        _ErrorLink(errors: [
          const gql.GraphQLError(
              message: 'Unauthorized', extensions: {'code': 'UNAUTHORIZED'}),
        ]),
      ]);

      final gqlReq = gql.Request(
        operation: gql.Operation(
          document: parseString('query Test { user { id } }'),
          operationName: 'Test',
        ),
      );

      await Future.wait([
        for (var i = 0; i < 5; i++) chain.request(gqlReq).drain<void>(),
      ]);

      expect(refreshCount, equals(1),
          reason: 'refresh must be deduplicated across concurrent requests');
    });

    test('retries after a thrown ServerException with HTTP 401 status',
        () async {
      final failingLink = _ServerExceptionOnceLink(
        const ServerException(statusCode: 401),
      );
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async => {'Authorization': 'Bearer new'},
        ),
        failingLink,
      ]);

      final responses = await chain
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .toList();

      expect(failingLink.calls, equals(2));
      expect(responses.single.data, equals({'ok': true}));
    });

    test(
        'retries when a thrown ServerException carries a parsed unauthorized error',
        () async {
      final failingLink = _ServerExceptionOnceLink(
        ServerException(
          parsedResponse: const gql.Response(
            errors: [
              gql.GraphQLError(
                  message: 'nope', extensions: {'code': 'unauthenticated'}),
            ],
            response: {},
          ),
        ),
      );
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async => {'Authorization': 'Bearer new'},
        ),
        failingLink,
      ]);

      final responses = await chain
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .toList();

      expect(failingLink.calls, equals(2));
      expect(responses.single.data, equals({'ok': true}));
    });

    test('rethrows a ServerException that is not unauthorized', () async {
      final failingLink = _ServerExceptionOnceLink(
        const ServerException(statusCode: 500),
      );
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async => {'Authorization': 'Bearer new'},
        ),
        failingLink,
      ]);

      await expectLater(
        chain
            .request(gql.Request(
              operation: gql.Operation(
                document: parseString('query Test { user { id } }'),
                operationName: 'Test',
              ),
            ))
            .drain<void>(),
        throwsA(isA<ServerException>()),
      );
      expect(failingLink.calls, equals(1),
          reason: 'must not retry non-unauthorized failures');
    });

    test(
        'isUnauthorized lets a custom API convention (a non-standard error '
        'code the built-in default would not recognize) trigger refresh',
        () async {
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async => {'Authorization': 'Bearer new'},
          isUnauthorized: (context) => context.errorCode == 'TOKEN_EXPIRED'
              ? AuthFailure.refresh
              : AuthFailure.none,
        ),
        _ErrorLink(errors: [
          const gql.GraphQLError(
              message: 'Session expired',
              extensions: {'code': 'TOKEN_EXPIRED'}),
        ]),
      ]);

      final responses = await chain
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .toList();

      // _ErrorLink always yields the same error response — the "retry"
      // observed here is just that response coming through once more,
      // proving the refresh-and-retry path fired instead of the error
      // being yielded straight through.
      expect(responses, hasLength(1));
      expect(responses.single.errors?.first.extensions?['code'],
          equals('TOKEN_EXPIRED'));
    });

    test(
        'isUnauthorized overrides the built-in default entirely — a 401 it '
        'does not recognize is left alone, not refreshed', () async {
      final failingLink = _ServerExceptionOnceLink(
        const ServerException(statusCode: 401),
      );
      var refreshCalls = 0;
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async {
            refreshCalls++;
            return {'Authorization': 'Bearer new'};
          },
          isUnauthorized: (context) => AuthFailure.none,
        ),
        failingLink,
      ]);

      await expectLater(
        chain
            .request(gql.Request(
              operation: gql.Operation(
                document: parseString('query Test { user { id } }'),
                operationName: 'Test',
              ),
            ))
            .drain<void>(),
        throwsA(isA<ServerException>()),
      );
      expect(refreshCalls, equals(0));
      expect(failingLink.calls, equals(1));
    });

    test(
        'a 403/FORBIDDEN response revokes immediately without attempting a '
        'refresh — the token is valid but lacks permission, so refreshing '
        "wouldn't help", () async {
      var refreshCalls = 0;
      var revokeCalls = 0;
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async {
            refreshCalls++;
            return {'Authorization': 'Bearer new'};
          },
          onRevokeToken: () => revokeCalls++,
        ),
        _ErrorLink(errors: [
          const gql.GraphQLError(
              message: 'Insufficient permissions',
              extensions: {'code': 'FORBIDDEN'}),
        ]),
      ]);

      final responses = await chain
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .toList();

      expect(refreshCalls, equals(0));
      expect(revokeCalls, equals(1));
      expect(responses, hasLength(1),
          reason: 'the real FORBIDDEN response is still yielded instead of '
              'silently ending the stream');
      expect(responses.single.errors?.first.message,
          equals('Insufficient permissions'));
    });

    test(
        'a thrown ServerException with HTTP 403 status also revokes '
        'immediately instead of attempting a refresh', () async {
      final failingLink = _ServerExceptionOnceLink(
        const ServerException(statusCode: 403),
      );
      var refreshCalls = 0;
      var revokeCalls = 0;
      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          accessTokenHeader: (_) => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) async {
            refreshCalls++;
            return {'Authorization': 'Bearer new'};
          },
          onRevokeToken: () => revokeCalls++,
        ),
        failingLink,
      ]);

      await expectLater(
        chain
            .request(gql.Request(
              operation: gql.Operation(
                document: parseString('query Test { user { id } }'),
                operationName: 'Test',
              ),
            ))
            .toList(),
        // The real ServerException is rethrown instead of silently ending
        // the stream.
        throwsA(isA<ServerException>()),
      );

      expect(refreshCalls, equals(0));
      expect(revokeCalls, equals(1));
      expect(failingLink.calls, equals(1),
          reason: 'must not retry — a revoke is not a refresh-and-retry');
    });
  });

  group('TypenameLink', () {
    test('injects __typename into every selection set', () async {
      final capture = _CapturingLink();
      await Link.from([const TypenameLink(), capture])
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id name } }'),
              operationName: 'Test',
            ),
          ))
          .first;

      expect(
        printNode(capture.captured!.operation.document),
        contains('__typename'),
      );
    });

    test(
        'reuses the transformed document instance across repeated requests '
        'for the same original document (identity-cached, not re-walked)',
        () async {
      final capture = _CapturingLink();
      const link = TypenameLink();
      final originalDoc = parseString('query Test { user { id name } }');

      await Link.from([link, capture])
          .request(gql.Request(
            operation: gql.Operation(document: originalDoc),
          ))
          .first;
      final firstTransformed = capture.captured!.operation.document;

      await Link.from([link, capture])
          .request(gql.Request(
            operation: gql.Operation(document: originalDoc),
          ))
          .first;
      final secondTransformed = capture.captured!.operation.document;

      expect(identical(firstTransformed, secondTransformed), isTrue);
    });
  });

  group('SseLink Tests', () {
    test('SseLink parses text/event-stream events correctly', () async {
      final dioInstance = dio.Dio();
      final adapter = _MockHttpClientAdapter();
      dioInstance.httpClientAdapter = adapter;

      final sseData = utf8.encode(
        'event: next\n'
        'data: {"data": {"user": {"id": "1", "name": "SSE User"}}}\n\n'
        'event: complete\n\n',
      );

      adapter.setResponse(sseData);

      final sseLink =
          SseLink('https://example.com/graphql/sse', client: dioInstance);

      final req = gql.Request(
        operation: gql.Operation(
          document: parseString('subscription OnUser { user { id name } }'),
          operationName: 'OnUser',
        ),
      );

      final responses = await sseLink.request(req).toList();
      expect(responses.length, equals(1));
      expect(responses.first.data?['user']?['name'], equals('SSE User'));
    });

    test('SseLink injects dynamic tokenHeader into request headers', () async {
      // tokenHeader is only invoked when TokenStorage.i actually has an
      // access token stored.
      await _seedTokenStorage(accessToken: 'dynamic-sse-token');
      final dioInstance = dio.Dio();
      dio.RequestOptions? capturedOptions;

      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        capturedOptions = options;
        final sseData = utf8.encode(
          'event: next\n'
          'data: {"data":{"user":{"id":"1","name":"Auth SSE User"}}}\n\n'
          'event: complete\n\n',
        );
        return dio.ResponseBody(
          Stream.value(Uint8List.fromList(sseData)),
          200,
          headers: {
            'content-type': ['text/event-stream']
          },
        );
      });

      final sseLink = SseLink(
        'https://example.com/graphql/sse',
        client: dioInstance,
        tokenHeader: (_) async => {'Authorization': 'Bearer dynamic-sse-token'},
      );

      final req = gql.Request(
        operation: gql.Operation(
          document: parseString('subscription OnUser { user { id name } }'),
          operationName: 'OnUser',
        ),
      );

      final responses = await sseLink.request(req).toList();
      expect(responses.length, equals(1));
      expect(capturedOptions?.headers['Authorization'],
          equals('Bearer dynamic-sse-token'));
    });

    test(
        'surfaces a 401 as ServerException instead of retrying itself — '
        'SseLink has no refresh logic of its own; that is AuthLink\'s job',
        () async {
      final dioInstance = dio.Dio();
      int callCount = 0;
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        throw dio.DioException(
          requestOptions: options,
          response: dio.Response(requestOptions: options, statusCode: 401),
          type: dio.DioExceptionType.badResponse,
        );
      });

      final sseLink =
          SseLink('https://example.com/graphql/sse', client: dioInstance);
      final req = gql.Request(
        operation: gql.Operation(
          document: parseString('subscription OnUser { user { id name } }'),
          operationName: 'OnUser',
        ),
      );

      await expectLater(
        sseLink.request(req).drain<void>(),
        throwsA(isA<ServerException>()),
      );
      expect(callCount, equals(1));
    });

    test(
        'AuthLink wraps SseLink and retries a 401 with a refreshed token — '
        'the same single-flight refresh path every other link goes through',
        () async {
      // accessTokenHeader is only invoked when TokenStorage.i actually has
      // an access token stored.
      await _seedTokenStorage(accessToken: 'old-token');
      final dioInstance = dio.Dio();
      int callCount = 0;
      final capturedHeaders = <Map<String, dynamic>>[];

      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        callCount++;
        capturedHeaders.add(Map.from(options.headers));
        if (callCount == 1) {
          throw dio.DioException(
            requestOptions: options,
            response: dio.Response(
              requestOptions: options,
              statusCode: 401,
            ),
            type: dio.DioExceptionType.badResponse,
          );
        }
        final sseData = utf8.encode(
          'event: next\n'
          'data: {"data":{"user":{"id":"1","name":"Refreshed SSE User"}}}\n\n'
          'event: complete\n\n',
        );
        return dio.ResponseBody(
          Stream.value(Uint8List.fromList(sseData)),
          200,
          headers: {
            'content-type': ['text/event-stream']
          },
        );
      });

      final sseLink =
          SseLink('https://example.com/graphql/sse', client: dioInstance);
      final chain = Link.from([
        AuthLink(
          url: 'https://example.com/graphql',
          accessTokenHeader: (_) async => {'Authorization': 'Bearer old-token'},
          onTokenRefresh: (_) async =>
              {'Authorization': 'Bearer refreshed-token'},
        ),
        sseLink,
      ]);

      final req = gql.Request(
        operation: gql.Operation(
          document: parseString('subscription OnUser { user { id name } }'),
          operationName: 'OnUser',
        ),
      );

      final responses = await chain.request(req).toList();
      expect(responses.length, equals(1));
      expect(
          responses.first.data?['user']?['name'], equals('Refreshed SSE User'));
      expect(callCount, equals(2));
      expect(capturedHeaders[0]['Authorization'], equals('Bearer old-token'));
      expect(capturedHeaders[1]['Authorization'],
          equals('Bearer refreshed-token'));
    });
  });

  group('WebSocketLink Tests', () {
    test('creates WebSocketLink instance and disposes properly', () async {
      final wsLink = WebSocketLink('ws://localhost:4000/graphql');
      expect(wsLink, isA<WebSocketLink>());
      await wsLink.dispose();
    });
  });

  group('BatchLink Tests', () {
    test(
        'dispose() fails queued-but-undispatched requests instead of '
        'leaving their callers hanging forever', () async {
      final batchLink = BatchLink(
        'https://api.example.com/graphql',
        batchTimeout: const Duration(seconds: 30),
      );

      final pending = batchLink
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .drain<void>();

      // Let the async* generator body actually run (enqueueing the item)
      // before disposing — subscribing via drain() only schedules that.
      await Future<void>.delayed(Duration.zero);

      await batchLink.dispose();

      await expectLater(pending, throwsA(isA<ServerException>()));
    });
  });

  group('Multipart Upload Tests', () {
    test(
        'DioLink converts requests with Upload to GraphQL Multipart Request format',
        () async {
      final dioInstance = dio.Dio();
      dio.RequestOptions? capturedOptions;

      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        capturedOptions = options;
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {
              'uploadFile': {'id': 'uploaded_1'}
            }
          }),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      });

      final dioLink =
          DioLink('https://example.com/graphql', client: dioInstance);

      final file = Upload.fromBytes([1, 2, 3, 4], filename: 'avatar.png');

      final req = gql.Request(
        operation: gql.Operation(
          document: parseString(
              'mutation UploadAvatar(\$file: Upload!) { uploadFile(file: \$file) { id } }'),
          operationName: 'UploadAvatar',
        ),
        variables: {'file': file},
      );

      final responses = await dioLink.request(req).toList();
      expect(responses.length, equals(1));
      expect(responses.first.data?['uploadFile']?['id'], equals('uploaded_1'));

      expect(capturedOptions, isNotNull);
      expect(capturedOptions!.data, isA<dio.FormData>());

      final formData = capturedOptions!.data as dio.FormData;
      final operationsField =
          formData.fields.firstWhere((f) => f.key == 'operations').value;
      final mapField = formData.fields.firstWhere((f) => f.key == 'map').value;

      final parsedOperations =
          jsonDecode(operationsField) as Map<String, dynamic>;
      final parsedMap = jsonDecode(mapField) as Map<String, dynamic>;

      // Conforms to GraphQL Multipart Request Spec
      expect(parsedOperations['variables']['file'], isNull);
      expect(parsedMap['0'], equals(['variables.file']));
      expect(formData.files.first.key, equals('0'));
      expect(formData.files.first.value.filename, equals('avatar.png'));
    });
  });

  group('HttpLink Tests', () {
    gql.Request buildReq({gql.Context? context}) => gql.Request(
          operation: gql.Operation(
            document: parseString('query Test { user { id name } }'),
            operationName: 'Test',
          ),
          context: context ?? const gql.Context(),
        );

    test('sends a query and parses a successful response', () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        expect(options.method, equals('POST'));
        return dio.ResponseBody.fromString(
          jsonEncode({
            'data': {
              'user': {'id': '1', 'name': 'Ada'}
            }
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });

      final httpLink =
          HttpLink('https://example.com/graphql', client: dioInstance);
      final responses = await httpLink.request(buildReq()).toList();

      expect(responses.length, equals(1));
      expect(responses.first.data?['user']?['name'], equals('Ada'));
    });

    test(
        'a connection failure throws HttpLinkConnectionException and maps to NetworkException',
        () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        throw dio.DioException(
          requestOptions: options,
          type: dio.DioExceptionType.connectionError,
          error: const SocketException('Failed host lookup'),
        );
      });
      final httpLink =
          HttpLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await httpLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<HttpLinkConnectionException>());
      expect(GraphQLExceptionExtension.fromLinkException(caught!),
          isA<NetworkException>());
    });

    test(
        'a malformed response body throws ResponseFormatException instead of a raw FormatException',
        () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        return dio.ResponseBody.fromString('not json', 200);
      });
      final httpLink =
          HttpLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await httpLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<ResponseFormatException>());
    });

    test(
        'cancelling via CancelToken while a request is in flight throws '
        'HttpLinkCanceledException instead of waiting for the response',
        () async {
      final handlerStarted = Completer<void>();
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) async {
        handlerStarted.complete();
        await Future.delayed(const Duration(seconds: 5));
        return dio.ResponseBody.fromString(jsonEncode({'data': null}), 200);
      });
      final httpLink =
          HttpLink('https://example.com/graphql', client: dioInstance);
      final cancelToken = dio.CancelToken();

      final future = httpLink
          .request(buildReq(
            context: const gql.Context()
                .withEntry(DioLinkCancelTokenContextEntry(cancelToken)),
          ))
          .toList();

      await handlerStarted.future;
      cancelToken.cancel();

      await expectLater(future, throwsA(isA<HttpLinkCanceledException>()));
    });

    test('an already-cancelled CancelToken fails fast without sending',
        () async {
      var handlerCalled = false;
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        handlerCalled = true;
        return dio.ResponseBody.fromString(jsonEncode({'data': null}), 200);
      });
      final httpLink =
          HttpLink('https://example.com/graphql', client: dioInstance);
      final cancelToken = dio.CancelToken()..cancel();

      await expectLater(
        httpLink
            .request(buildReq(
              context: const gql.Context()
                  .withEntry(DioLinkCancelTokenContextEntry(cancelToken)),
            ))
            .toList(),
        throwsA(isA<HttpLinkCanceledException>()),
      );
      expect(handlerCalled, isFalse);
    });
  });

  group('DioLink Exception Handling', () {
    gql.Request buildReq() => gql.Request(
          operation: gql.Operation(
            document: parseString('query Test { user { id } }'),
            operationName: 'Test',
          ),
        );

    test(
        'connectionError maps to DioLinkConnectionException and NetworkException',
        () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        throw dio.DioException(
          requestOptions: options,
          type: dio.DioExceptionType.connectionError,
          error: const SocketException('Failed host lookup'),
        );
      });
      final dioLink =
          DioLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await dioLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioLinkConnectionException>());
      expect(GraphQLExceptionExtension.fromLinkException(caught!),
          isA<NetworkException>());
    });

    test(
        'badCertificate maps to DioLinkCertificateException and CertificateException',
        () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        throw dio.DioException(
          requestOptions: options,
          type: dio.DioExceptionType.badCertificate,
          error: const HandshakeException('Certificate not trusted'),
        );
      });
      final dioLink =
          DioLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await dioLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioLinkCertificateException>());
      expect(GraphQLExceptionExtension.fromLinkException(caught!),
          isA<CertificateException>());
    });

    test(
        'a malformed 200 response body (errors present but wrongly shaped) '
        'throws DioLinkParserException, not a raw TypeError', () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        return dio.ResponseBody.fromString(
          // 'errors' is a List but entries are Strings, not Maps —
          // ResponseParser.parseError does `error as Map<String, dynamic>`.
          jsonEncode({
            'errors': ['not a map']
          }),
          200,
          headers: {
            'content-type': ['application/json']
          },
        );
      });
      final dioLink =
          DioLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await dioLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioLinkParserException>());
      expect(GraphQLExceptionExtension.fromLinkException(caught!),
          isA<ParseException>());
    });

    test(
        'a malformed error-status body still classifies as DioLinkServerException '
        '(status preserved) instead of a parser exception', () async {
      final dioInstance = dio.Dio();
      dioInstance.httpClientAdapter = _MockUploadAdapter((options) {
        return dio.ResponseBody.fromString(
          jsonEncode({
            'errors': ['not a map']
          }),
          500,
          headers: {
            'content-type': ['application/json']
          },
        );
      });
      final dioLink =
          DioLink('https://example.com/graphql', client: dioInstance);

      Object? caught;
      try {
        await dioLink.request(buildReq()).toList();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioLinkServerException>());
      expect((caught as DioLinkServerException).parsedResponse, isNull);
      expect(caught.statusCode, equals(500));
    });
  });

  group('GraphQL Conventions & Optimizations', () {
    test(
        'ErrorPolicy.none throws when response has errors even if data is present',
        () async {
      final client = GraphQLClient.fromLink(
        const _DataAndErrorLink(
          data: {'id': '123', 'name': 'Alice'},
          errors: [
            gql.GraphQLError(message: 'Non-fatal field error'),
          ],
        ),
        defaultErrorPolicy: ErrorPolicy.none,
      );

      expect(
        () => client.future(_TestReq(const _TestVars('123'))),
        throwsA(isA<GraphQLException>()),
      );
    });

    test('ErrorPolicy.ignore returns data when partial errors are present',
        () async {
      final client = GraphQLClient.fromLink(
        const _DataAndErrorLink(
          data: {'id': '123', 'name': 'Alice'},
          errors: [
            gql.GraphQLError(message: 'Non-fatal field error'),
          ],
        ),
        defaultErrorPolicy: ErrorPolicy.ignore,
      );

      final result = await client.future(_TestReq(const _TestVars('123')));
      expect(result.id, '123');
      expect(result.name, 'Alice');
    });

    test(
        'ErrorPolicy.all returns data without throwing when partial errors are present',
        () async {
      final client = GraphQLClient.fromLink(
        const _DataAndErrorLink(
          data: {'id': '123', 'name': 'Alice'},
          errors: [
            gql.GraphQLError(message: 'Non-fatal field error'),
          ],
        ),
      );

      // Per-request override
      final result = await client.future(
        _TestReq(const _TestVars('123'), errorPolicy: ErrorPolicy.all),
      );
      expect(result.id, '123');
      expect(result.name, 'Alice');
    });

    test('ErrorPolicy.all still throws when data is null', () async {
      final client = GraphQLClient.fromLink(
        const _ErrorLink(
          errors: [
            gql.GraphQLError(message: 'Fatal error'),
          ],
        ),
      );

      expect(
        () => client.future(
          _TestReq(const _TestVars('123'), errorPolicy: ErrorPolicy.all),
        ),
        throwsA(isA<GraphQLException>()),
      );
    });

    test('Deterministic canonical cache key ordering for variables', () {
      final cache = InMemoryCache();
      // Test two requests whose variables maps have different key insertion order
      final req1 = _CustomVarsReq({'b': '2', 'a': '1'});
      final req2 = _CustomVarsReq({'a': '1', 'b': '2'});

      cache.writeQuery(req1, const _TestData(id: '123', name: 'Cached'));

      // Reading with differently-ordered keys must hit the exact same cache record
      final read = cache.readQuery(req2);
      expect(read, isNotNull);
      expect(read?.name, 'Cached');
    });

    test('Document AST caching reuses parsed DocumentNode across requests', () {
      const doc = 'query GetCachedDoc { user { id } }';
      final node1 = GraphQLClient.getParsedDocument(doc);
      final node2 = GraphQLClient.getParsedDocument(doc);
      expect(identical(node1, node2), isTrue);
    });

    test(
        'GraphQLRequest.documentNode override is sent as-is, bypassing the '
        'string parse cache entirely', () async {
      final capture = _CapturingLink();
      final client = GraphQLClient.fromLink(capture);

      await client.future(_PreparsedDocReq(const _TestVars('1')));

      expect(
        identical(
          capture.captured!.operation.document,
          _PreparsedDocReq._documentNode,
        ),
        isTrue,
      );
    });

    test('GraphQLRequest.documentNode defaults to the shared parse cache',
        () async {
      final req = _TestReq(const _TestVars('1'));
      expect(
        identical(
            req.documentNode, GraphQLClient.getParsedDocument(req.document)),
        isTrue,
      );
    });
  });

  group('Stale-while-revalidate (cacheFirst)', () {
    test(
        'default staleTime (Duration.zero): a cache hit emits cached data '
        'immediately and also background-refetches', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst);

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final responses = await client.request(req).toList();
      expect(responses.first.data?.name, equals('Cached'));
      expect(responses.first.source, equals(ResponseSource.cache));
      expect(responses.first.loading, isTrue,
          reason: 'default staleTime means the cache hit is always stale');
      expect(networkCalls, equals(1),
          reason: 'stale cache hit must trigger a background network refetch');
    });

    test('explicit staleTime, still fresh: no network call at all', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(minutes: 5));

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(1));
      expect(responses.single.loading, isFalse);
      expect(networkCalls, equals(0));
    });

    test('explicit staleTime, expired: cache emission then network emission',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(milliseconds: 1));

      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(2));
      expect(responses[0].source, equals(ResponseSource.cache));
      expect(responses[0].loading, isTrue);
      expect(responses[1].source, equals(ResponseSource.network));
      expect(networkCalls, equals(1));
    });

    test('cache miss always fetches from network regardless of staleTime',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          fetchPolicy: FetchPolicy.cacheFirst,
          staleTime: const Duration(minutes: 5));

      final responses = await client.request(req).toList();
      expect(responses, hasLength(1));
      expect(responses.single.source, equals(ResponseSource.network));
      expect(networkCalls, equals(1));
    });
  });

  group('watchQuery: staleness, GC, refetchInterval', () {
    test('watchQuery triggers a background refetch on attach when stale',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(networkCalls, equals(1),
          reason: 'default staleTime is zero, so attaching a watcher to '
              'already-cached data must background-refetch it');
      await sub.cancel();
    });

    test(
        'watchQuery does not refetch on attach when staleTime keeps the '
        'cached value fresh', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Fresh'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(networkCalls, equals(0));
      await sub.cancel();
    });

    test(
        'cacheTime evicts the cache entry after the last watcher cancels, '
        'once the timer elapses', () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          cacheTime: const Duration(milliseconds: 20));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub.cancel();

      expect(client.cache.readQuery(req), isNotNull,
          reason: 'not evicted yet — cacheTime has not elapsed');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.cache.readQuery(req), isNull);
    });

    test('a resubscribe before cacheTime elapses cancels the pending GC',
        () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          cacheTime: const Duration(milliseconds: 20));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub1 = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await sub1.cancel();

      final sub2 = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(client.cache.readQuery(req), isNotNull,
          reason: 'resubscribing before the GC timer fired must cancel it');
      await sub2.cancel();
    });

    test('refetchInterval refetches on schedule and stops after cancel',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          refetchInterval: const Duration(milliseconds: 15));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      final callsAtCancel = networkCalls;

      expect(callsAtCancel, greaterThanOrEqualTo(2));

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(networkCalls, equals(callsAtCancel),
          reason: 'the interval timer must stop once the watcher cancels');
    });

    test(
        'two concurrent watchQuery subscriptions on the same key each poll '
        'refetchInterval independently', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          refetchInterval: const Duration(milliseconds: 15));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub1 = client.watchQuery(req).listen((_) {});
      final sub2 = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(networkCalls, greaterThanOrEqualTo(2),
          reason: 'both watchers are polling');

      // Cancel the first watcher only — the second must keep polling on
      // its own, independent timer.
      await sub1.cancel();
      final callsAfterFirstCancel = networkCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(networkCalls, greaterThan(callsAfterFirstCancel),
          reason: 'the second watcher must still be polling after the '
              'first cancels');

      // Cancel the second (last) watcher — all polling must stop. Give any
      // already-in-flight background refetch (fired just before cancel) a
      // moment to settle before taking the "final" snapshot, so this
      // assertion is about the timer being stopped, not about a network
      // call's completion race.
      await sub2.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final callsAfterBothCancel = networkCalls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(networkCalls, equals(callsAfterBothCancel),
          reason: 'no polling may continue once every watcher has '
              'cancelled');
    });

    test('dispose() cancels pending GC and refetchInterval timers', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5),
          cacheTime: const Duration(milliseconds: 20),
          refetchInterval: const Duration(milliseconds: 10));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Cached'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await sub.cancel();
      final callsAtDispose = networkCalls;

      await client.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(networkCalls, equals(callsAtDispose),
          reason: 'no refetchInterval/GC timer should fire after dispose()');
    });
  });

  group('notifyReconnected / notifyAppResumed', () {
    test('notifyReconnected refetches only currently active watched queries',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final watchedReq = _TestReq(const _TestVars('watched'),
          staleTime: const Duration(minutes: 5));
      final unwatchedReq = _TestReq(const _TestVars('unwatched'),
          staleTime: const Duration(minutes: 5));
      client.cache
          .writeQuery(watchedReq, const _TestData(id: '1', name: 'A'));
      client.cache
          .writeQuery(unwatchedReq, const _TestData(id: '2', name: 'B'));

      final sub = client.watchQuery(watchedReq).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final callsAfterAttach = networkCalls;
      expect(callsAfterAttach, equals(0),
          reason: 'fresh staleTime, no reconnect yet — no refetch');

      await client.notifyReconnected();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1),
          reason: 'only the watched query refetches on reconnect');
      await sub.cancel();
    });

    test('notifyAppResumed behaves the same as notifyReconnected', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'A'));

      final sub = client.watchQuery(req).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await client.notifyAppResumed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1));
      await sub.cancel();
    });
  });

  group('invalidateQueries', () {
    test('invalidates by operationNames: active watcher gets refetched data',
        () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'),
          staleTime: const Duration(minutes: 5));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      final emissions = <_TestData?>[];
      final sub = client.watchQuery(req).listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emissions.single?.name, equals('Old'));

      await client.invalidateQueries(operationNames: ['Test']);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(networkCalls, equals(1));
      expect(emissions.last?.name, equals('Dedup'),
          reason: '_CountingLink always returns name "Dedup"');
      await sub.cancel();
    });

    test(
        'invalidates by types: matches only queries whose cached result '
        'touched that typename', () async {
      final client = GraphQLClient.fromLink(_CountingLink(() {}));

      final untypedReq = _TestReq(const _TestVars('1'));
      client.cache
          .writeQuery(untypedReq, const _TestData(id: '1', name: 'Alice'));

      final typedReq = _TypedTestReq(const _TestVars('2'));
      client.cache
          .writeQuery(typedReq, const _TypedData(id: '2', name: 'Bob'));

      await client.invalidateQueries(types: ['User'], refetchActive: false);

      expect(client.cache.readQuery(typedReq), isNull,
          reason: 'evicted because its cached JSON included __typename: User');
      expect(client.cache.readQuery(untypedReq), isNotNull,
          reason: '_TestData.toJson() carries no __typename, so it must '
              'not match a type-based invalidation');
    });

    test(
        'an inactive (unwatched) match is evicted but not refetched — no '
        'network call', () async {
      var networkCalls = 0;
      final client = GraphQLClient.fromLink(_CountingLink(() {
        networkCalls++;
      }));
      final req = _TestReq(const _TestVars('1'));
      client.cache.writeQuery(req, const _TestData(id: '1', name: 'Old'));

      await client.invalidateQueries(operationNames: ['Test']);

      expect(networkCalls, equals(0));
      expect(client.cache.readQuery(req), isNull);
    });
  });
}

class _DataAndErrorLink extends Link {
  final Map<String, dynamic> data;
  final List<gql.GraphQLError> errors;
  const _DataAndErrorLink({required this.data, required this.errors});

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    yield gql.Response(data: data, errors: errors, response: const {});
  }
}

class _CustomVarsReq extends GraphQLRequest<_TestData, Map<String, dynamic>> {
  @override
  final Map<String, dynamic> variables;

  _CustomVarsReq(this.variables, {super.fetchPolicy, super.errorPolicy});

  @override
  String get document => 'query TestCustom { user { id name } }';

  @override
  String get operationName => 'TestCustom';

  @override
  Map<String, dynamic> toJsonVars(Map<String, dynamic> vars) => vars;

  @override
  _TestData parseData(Map<String, dynamic> json) => _TestData.fromJson(json);

  @override
  _CustomVarsReq copyWithRequest({
    Map<String, dynamic>? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _TestData? optimisticResponse,
  }) =>
      _CustomVarsReq(
        variables ?? this.variables,
        fetchPolicy: fetchPolicy ?? this.fetchPolicy,
        errorPolicy: errorPolicy ?? this.errorPolicy,
      );
}

class _MockUploadAdapter implements dio.HttpClientAdapter {
  final FutureOr<dio.ResponseBody> Function(dio.RequestOptions options) onFetch;
  _MockUploadAdapter(this.onFetch);

  @override
  void close({bool force = false}) {}

  @override
  Future<dio.ResponseBody> fetch(
    dio.RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return onFetch(options);
  }
}

class _MockHttpClientAdapter implements dio.HttpClientAdapter {
  Uint8List _data = Uint8List(0);

  void setResponse(List<int> bytes) {
    _data = Uint8List.fromList(bytes);
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<dio.ResponseBody> fetch(
    dio.RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return dio.ResponseBody(
      Stream.value(_data),
      200,
      headers: {
        'content-type': ['text/event-stream'],
      },
    );
  }
}
