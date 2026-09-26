import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _uploadMutation =
    r'mutation Upload($file: Upload!) { upload(file: $file) { id } }';

class _Vars {
  const _Vars();
}

class _Data {
  const _Data();
}

class _Req extends GraphQLRequest<_Data, _Vars> {
  _Req({
    this.doc = 'query Test { user { id } }',
    this.upload = false,
    super.headers,
  });

  final String doc;
  final bool upload;

  @override
  _Vars get variables => const _Vars();

  @override
  String get document => doc;

  @override
  String get operationName => 'Test';

  @override
  Map<String, dynamic> toJsonVars(_Vars vars) => upload
      ? {
          'file': Upload.fromBytes([1, 2, 3], filename: 'a.png')
        }
      : {};

  @override
  _Data parseData(Map<String, dynamic> json) => const _Data();

  @override
  _Req copyWithRequest({
    _Vars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    dio.CancelToken? cancelToken,
    _Data? optimisticResponse,
  }) =>
      _Req(doc: doc, upload: upload, headers: headers ?? this.headers);
}

/// Records the [dio.RequestOptions] of every request that reaches the wire —
/// `options.headers` there is the final merge of the Dio's own base headers
/// and the per-request headers, and is case-insensitive.
class _RecordingAdapter implements dio.HttpClientAdapter {
  _RecordingAdapter({this.respond});

  final List<dio.RequestOptions> seen = [];
  final FutureOr<dio.ResponseBody> Function(int callNumber)? respond;

  static dio.ResponseBody ok() => dio.ResponseBody.fromString(
        jsonEncode({
          'data': {
            'user': {'id': '1'}
          }
        }),
        200,
        headers: {
          'content-type': ['application/json']
        },
      );

  static dio.ResponseBody unauthenticated() => dio.ResponseBody.fromString(
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

  @override
  void close({bool force = false}) {}

  @override
  Future<dio.ResponseBody> fetch(
    dio.RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return respond?.call(seen.length) ?? ok();
  }
}

void main() {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  /// Builds a client over [adapter] (on [callerDio] when given), runs [req]
  /// once and returns what reached the wire.
  Future<_RecordingAdapter> send(
    Map<String, String>? defaultHeaders, {
    _Req? req,
    dio.Dio? callerDio,
    _RecordingAdapter? adapter,
    RefreshCallback? refreshCallback,
  }) async {
    final recorder = adapter ?? _RecordingAdapter();
    final dioInstance = callerDio ?? dio.Dio();
    dioInstance.httpClientAdapter = recorder;
    final client = GraphQLClient(
      url: 'https://api.test/graphql',
      dio: dioInstance,
      defaultHeaders: defaultHeaders,
      refreshCallback: refreshCallback,
      addTypename: false,
    );
    await client.future(req ?? _Req());
    return recorder;
  }

  group('defaultHeaders', () {
    test('are sent on queries and mutations', () async {
      final query = await send({'X-Api-Key': 'k'});
      expect(query.seen.single.headers['X-Api-Key'], equals('k'));

      final mutation = await send(
        {'X-Api-Key': 'k'},
        req: _Req(doc: 'mutation Do { doIt { id } }'),
      );
      expect(mutation.seen.single.headers['X-Api-Key'], equals('k'));
    });

    test('override the built-in Accept header', () async {
      final wire = await send({'Accept': 'application/json'});

      expect(wire.seen.single.headers['accept'], equals('application/json'));
    });

    test('override the built-in Content-Type header of a JSON request',
        () async {
      final wire = await send({'Content-Type': 'application/vnd.custom+json'});

      expect(wire.seen.single.headers['content-type'],
          equals('application/vnd.custom+json'));
    });

    for (final key in ['Content-Type', 'content-type']) {
      test(
          'a default "$key" does not break a multipart upload — the boundary '
          'Content-Type must still win', () async {
        final wire = await send(
          {key: 'application/json'},
          req: _Req(doc: _uploadMutation, upload: true),
        );

        expect(wire.seen.single.data, isA<dio.FormData>());
        expect(
          wire.seen.single.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
      });
    }

    test('a per-request header beats a default, whatever the key casing',
        () async {
      for (final defaultKey in ['X-Api-Key', 'x-api-key']) {
        final wire = await send(
          {defaultKey: 'default'},
          req: _Req(headers: {'X-Api-Key': 'per-request'}),
        );

        expect(wire.seen.single.headers['x-api-key'], equals('per-request'),
            reason: 'default key "$defaultKey"');
      }
    });

    test(
        'a default Authorization is the fallback when logged out, but the '
        'stored access token beats it', () async {
      Future<RefreshCallback> noRefresh() async => (_, __) async => null;

      var wire = await send({'Authorization': 'Basic static'},
          refreshCallback: await noRefresh());
      expect(wire.seen.single.headers['Authorization'], equals('Basic static'));

      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'stored', refreshToken: 'r'));
      wire = await send({'Authorization': 'Basic static'},
          refreshCallback: await noRefresh());
      expect(
          wire.seen.single.headers['Authorization'], equals('Bearer stored'));
    });

    test('reach the token-refresh request and the retry after it', () async {
      await TokenStorage.i.saveToken(
          const TokenPair(accessToken: 'old', refreshToken: 'old-r'));

      final wire = _RecordingAdapter(
        respond: (n) => n == 1
            ? _RecordingAdapter.unauthenticated()
            : _RecordingAdapter.ok(),
      );
      await send(
        {'X-Api-Key': 'k', 'Accept': 'application/json'},
        adapter: wire,
        refreshCallback: (refreshClient, refreshToken) async {
          await refreshClient
              .future(_Req(doc: 'mutation Refresh { r { id } }'));
          return const TokenPair(accessToken: 'new', refreshToken: 'new-r');
        },
      );

      expect(wire.seen, hasLength(3)); // original, refresh, retry
      final [original, refresh, retry] = wire.seen;
      expect(original.headers['X-Api-Key'], equals('k'));
      expect(original.headers['Authorization'], equals('Bearer old'));
      expect(refresh.headers['X-Api-Key'], equals('k'));
      expect(refresh.headers['accept'], equals('application/json'),
          reason: 'overrides must apply to the refresh request too');
      expect(refresh.headers['Authorization'], isNull,
          reason: 'the access token must never leak onto the refresh request');
      expect(retry.headers['X-Api-Key'], equals('k'));
      expect(retry.headers['Authorization'], equals('Bearer new'));
    });

    test('are sent on SSE subscription requests', () async {
      final wire = _RecordingAdapter(
        respond: (_) => dio.ResponseBody.fromString(
          'event: next\ndata: {"data":{"user":{"id":"1"}}}\n\n'
          'event: complete\n\n',
          200,
          headers: {
            'content-type': ['text/event-stream']
          },
        ),
      );
      final dioInstance = dio.Dio()..httpClientAdapter = wire;
      final client = GraphQLClient(
        url: 'https://api.test/graphql',
        sseUrl: 'https://api.test/sse',
        dio: dioInstance,
        defaultHeaders: {'X-Api-Key': 'k'},
        addTypename: false,
      );

      await client.stream(_Req(doc: 'subscription Test { user { id } }')).first;

      expect(wire.seen.single.uri.path, equals('/sse'));
      expect(wire.seen.single.headers['X-Api-Key'], equals('k'));
      expect(wire.seen.single.headers['accept'], equals('text/event-stream'));
    });

    group('with a caller-supplied Dio', () {
      test('leave that Dio untouched', () async {
        final callerDio = dio.Dio()
          ..options.headers['X-Own'] = '1'
          ..options.headers['X-Api-Key'] = 'original';

        await send({'X-Api-Key': 'graphql', 'X-Client': 'mk'},
            callerDio: callerDio);

        expect(callerDio.options.headers['X-Api-Key'], equals('original'));
        expect(callerDio.options.headers.containsKey('X-Client'), isFalse);
        expect(callerDio.options.headers['X-Own'], equals('1'));
      });

      test(
          'still apply to GraphQL requests (overriding the Dio\'s own header) '
          'without leaking into the caller\'s other requests', () async {
        final callerDio = dio.Dio()..options.headers['X-Api-Key'] = 'original';
        final wire = _RecordingAdapter();

        await send({'X-Api-Key': 'graphql', 'X-Client': 'mk'},
            callerDio: callerDio, adapter: wire);
        await callerDio.get<dynamic>('https://rest.test/thing');

        final [graphql, rest] = wire.seen;
        expect(graphql.headers['X-Api-Key'], equals('graphql'));
        expect(graphql.headers['X-Client'], equals('mk'));
        expect(rest.headers['X-Api-Key'], equals('original'));
        expect(rest.headers.containsKey('X-Client'), isFalse);
      });

      test('still reach the token-refresh request', () async {
        await TokenStorage.i.saveToken(
            const TokenPair(accessToken: 'old', refreshToken: 'old-r'));
        final callerDio = dio.Dio();
        final wire = _RecordingAdapter(
          respond: (n) => n == 1
              ? _RecordingAdapter.unauthenticated()
              : _RecordingAdapter.ok(),
        );

        await send(
          {'X-Client': 'mk'},
          callerDio: callerDio,
          adapter: wire,
          refreshCallback: (refreshClient, _) async {
            await refreshClient
                .future(_Req(doc: 'mutation Refresh { r { id } }'));
            return const TokenPair(accessToken: 'new', refreshToken: 'new-r');
          },
        );

        expect(wire.seen[1].headers['X-Client'], equals('mk'));
        expect(callerDio.options.headers.containsKey('X-Client'), isFalse);
      });
    });
  });
}
