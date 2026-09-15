import 'dart:async';
import 'dart:convert';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mk_graphql/mk_graphql.dart';

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
      );
}

// ---------------------------------------------------------------------------
// gql_link test doubles
// ---------------------------------------------------------------------------

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

/// In-memory [TokenStorage] test double — avoids touching the real
/// platform-channel-backed [SecureTokenStorage] in unit tests.
class _FakeTokenStorage implements TokenStorage {
  _FakeTokenStorage({String? initialAccessToken, String? initialRefreshToken})
      : _accessToken = initialAccessToken,
        _refreshToken = initialRefreshToken;

  String? _accessToken;
  String? _refreshToken;
  bool cleared = false;
  final _changes = StreamController<AuthToken?>.broadcast();

  @override
  Future<String?> get accessToken async => _accessToken;

  @override
  Future<String?> get refreshToken async => _refreshToken;

  @override
  Stream<AuthToken?> get onChange => _changes.stream;

  @override
  Future<void> save(AuthToken token) async {
    _accessToken = token.accessToken;
    if (token.refreshToken != null) _refreshToken = token.refreshToken;
    cleared = false;
    _changes.add(token);
  }

  @override
  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
    cleared = true;
    _changes.add(null);
  }

  @override
  Future<void> dispose() => _changes.close();
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
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
          tokenHeader: () => {'Authorization': 'Bearer tok'},
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
  });

  group('GraphQLClient refreshCallback / tokenStorage', () {
    test('setAuthToken/clearAuthToken delegate to tokenStorage', () async {
      final storage = _FakeTokenStorage();
      final client = GraphQLClient(
        url: 'https://api.example.com/graphql',
        addTypename: false,
        tokenStorage: storage,
        refreshCallback: (_, __) async => null,
      );

      expect(await client.isAuthenticated, isFalse);

      await client.setAuthToken(
        const AuthToken(accessToken: 'access-1', refreshToken: 'refresh-1'),
      );
      expect(await client.isAuthenticated, isTrue);
      expect(await storage.accessToken, equals('access-1'));

      await client.clearAuthToken();
      expect(await client.isAuthenticated, isFalse);
      expect(storage.cleared, isTrue);
    });

    test('onAuthTokenChange emits on setAuthToken and clearAuthToken',
        () async {
      final storage = _FakeTokenStorage();
      final client = GraphQLClient(
        url: 'https://api.example.com/graphql',
        addTypename: false,
        tokenStorage: storage,
        refreshCallback: (_, __) async => null,
      );

      final events = <AuthToken?>[];
      final sub = client.onAuthTokenChange.listen(events.add);

      await client.setAuthToken(const AuthToken(accessToken: 'access-1'));
      await client.clearAuthToken();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0]?.accessToken, equals('access-1'));
      expect(events[1], isNull);

      await sub.cancel();
    });

    test('onAuthTokenChange is empty when no tokenStorage/refreshCallback',
        () async {
      final client = GraphQLClient(
          url: 'https://api.example.com/graphql', addTypename: false);
      expect(await client.onAuthTokenChange.isEmpty, isTrue);
    });

    test('setAuthToken throws when no tokenStorage/refreshCallback configured',
        () async {
      final client = GraphQLClient(
          url: 'https://api.example.com/graphql', addTypename: false);
      expect(
        () => client.setAuthToken(const AuthToken(accessToken: 'x')),
        throwsA(isA<StateError>()),
      );
    });

    test(
        'refreshCallback receives the stored refresh token, persists the new '
        'AuthToken, and the failed request is retried with the new access token',
        () async {
      final storage = _FakeTokenStorage(
        initialAccessToken: 'old-access',
        initialRefreshToken: 'old-refresh',
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
        tokenStorage: storage,
        refreshCallback: (refreshClient, refreshToken) async {
          refreshTokenSeen = refreshToken;
          return const AuthToken(
              accessToken: 'new-access', refreshToken: 'new-refresh');
        },
      );

      final result = await client.future(_TestReq(const _TestVars('123')));

      expect(result.name, equals('Refreshed User'));
      expect(callCount, equals(2));
      expect(refreshTokenSeen, equals('old-refresh'));
      expect(capturedHeaders[0]['Authorization'], equals('Bearer old-access'));
      expect(capturedHeaders[1]['Authorization'], equals('Bearer new-access'));
      expect(await storage.accessToken, equals('new-access'));
      expect(await storage.refreshToken, equals('new-refresh'));
    });

    test(
        'defaultHeaders reach the token-refresh request too, not just the '
        'original one — AuthLink must share the client\'s configured Dio '
        'instance rather than falling back to an unconfigured one', () async {
      final storage = _FakeTokenStorage(
        initialAccessToken: 'old-access',
        initialRefreshToken: 'old-refresh',
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
        tokenStorage: storage,
        refreshCallback: (refreshClient, refreshToken) async =>
            const AuthToken(accessToken: 'new-access'),
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
      final storage = _FakeTokenStorage(initialAccessToken: 'old-access');
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
        tokenStorage: storage,
        refreshCallback: (_, __) async {
          refreshCalls++;
          return const AuthToken(accessToken: 'should-not-happen');
        },
      );

      await expectLater(
        client.future(_TestReq(const _TestVars('123'))),
        throwsA(isA<GraphQLException>()),
      );

      expect(refreshCalls, equals(0));
      expect(listenerCalled, isTrue);
      expect(storage.cleared, isTrue);
      GraphQLClient.clearRevokeTokenListeners();
    });

    test(
        'multiple concurrent requests failing at once trigger only one '
        'refreshCallback call and all retry successfully', () async {
      final storage = _FakeTokenStorage(
        initialAccessToken: 'old-access',
        initialRefreshToken: 'old-refresh',
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
        tokenStorage: storage,
        refreshCallback: (refreshClient, refreshToken) async {
          refreshCalls++;
          // Widen the window so all 5 concurrent 401s queue behind this
          // single refresh instead of each triggering their own.
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return const AuthToken(
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
  });

  group('AuthLink', () {
    test('triggers revoke token listeners when refresh fails', () async {
      bool listenerCalled = false;
      GraphQLClient.registerRevokeTokenListener(() => listenerCalled = true);

      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          tokenHeader: () => {'Authorization': 'Bearer old'},
          onTokenRefresh: (_) => throw Exception('Refresh failed'),
        ),
        _ErrorLink(errors: [
          const gql.GraphQLError(
              message: 'Unauthorized', extensions: {'code': 'UNAUTHORIZED'}),
        ]),
      ]);

      await chain
          .request(gql.Request(
            operation: gql.Operation(
              document: parseString('query Test { user { id } }'),
              operationName: 'Test',
            ),
          ))
          .drain<void>();

      expect(listenerCalled, isTrue);
      GraphQLClient.clearRevokeTokenListeners();
    });

    test('deduplicates concurrent token refreshes', () async {
      int refreshCount = 0;

      final chain = Link.from([
        AuthLink(
          url: 'https://api.example.com/graphql',
          tokenHeader: () => {'Authorization': 'Bearer old'},
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
          tokenHeader: () => {'Authorization': 'Bearer old'},
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
          tokenHeader: () => {'Authorization': 'Bearer old'},
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
          tokenHeader: () => {'Authorization': 'Bearer old'},
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
        tokenHeader: () async => {'Authorization': 'Bearer dynamic-sse-token'},
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
          tokenHeader: () async => {'Authorization': 'Bearer old-token'},
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
      final client = MockClient((request) async {
        expect(request.method, equals('POST'));
        return http.Response(
          jsonEncode({
            'data': {
              'user': {'id': '1', 'name': 'Ada'}
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final httpLink = HttpLink('https://example.com/graphql', client: client);
      final responses = await httpLink.request(buildReq()).toList();

      expect(responses.length, equals(1));
      expect(responses.first.data?['user']?['name'], equals('Ada'));
    });

    test(
        'a connection failure throws HttpLinkConnectionException and maps to NetworkException',
        () async {
      // Mirrors what a real IOClient throws for a socket failure: a
      // ClientException that also implements SocketException (see
      // package:http's io_client.dart `_ClientSocketException`).
      final client = MockClient((request) async {
        throw http.ClientException('Failed host lookup', request.url);
      });
      final httpLink = HttpLink('https://example.com/graphql', client: client);

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
      final client = MockClient((request) async {
        return http.Response('not json', 200);
      });
      final httpLink = HttpLink('https://example.com/graphql', client: client);

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
      final client = MockClient((request) async {
        handlerStarted.complete();
        await Future.delayed(const Duration(seconds: 5));
        return http.Response(jsonEncode({'data': null}), 200);
      });
      final httpLink = HttpLink('https://example.com/graphql', client: client);
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
      final client = MockClient((request) async {
        handlerCalled = true;
        return http.Response(jsonEncode({'data': null}), 200);
      });
      final httpLink = HttpLink('https://example.com/graphql', client: client);
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
