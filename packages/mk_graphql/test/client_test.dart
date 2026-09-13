import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart' as gql;
import 'package:gql_link/gql_link.dart';
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

class _ErrorLink extends Link {
  final List<gql.GraphQLError> errors;
  const _ErrorLink({required this.errors});

  @override
  Stream<gql.Response> request(gql.Request req, [NextLink? forward]) async* {
    yield gql.Response(errors: errors, response: const {});
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

    test('SseLink retries on 401 response with refreshed token', () async {
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

      var refreshCalled = false;
      final sseLink = SseLink(
        'https://example.com/graphql/sse',
        client: dioInstance,
        tokenHeader: () async => {'Authorization': 'Bearer old-token'},
        onTokenRefresh: (link) async {
          refreshCalled = true;
          return {'Authorization': 'Bearer refreshed-token'};
        },
      );

      final req = gql.Request(
        operation: gql.Operation(
          document: parseString('subscription OnUser { user { id name } }'),
          operationName: 'OnUser',
        ),
      );

      final responses = await sseLink.request(req).toList();
      expect(responses.length, equals(1));
      expect(
          responses.first.data?['user']?['name'], equals('Refreshed SSE User'));
      expect(refreshCalled, isTrue);
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
