import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:mk_graphql/mk_graphql.dart';

/// A minimal `graphql-sse` single-connection-mode server: `PUT` reserves a
/// token, `GET` opens the shared stream, `POST` starts an operation (202) and
/// echoes one `next` event on the stream, `DELETE` cancels one.
class _Server {
  late HttpServer http;
  final streams = <String, HttpResponse>{};
  final posted = <String, List<String>>{}; // token -> operation ids
  final deleted = <String>[];
  int puts = 0;
  int gets = 0;
  bool failNextPostWith404 = false;
  bool failPuts = false;

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((r) async {
      final token = r.headers.value('x-graphql-event-stream-token');
      switch (r.method) {
        case 'PUT':
          puts++;
          if (failPuts) {
            r.response.statusCode = 503;
            await r.response.close();
            return;
          }
          r.response.statusCode = 201;
          r.response.write('tok$puts');
          await r.response.close();
        case 'GET':
          gets++;
          r.response.headers.contentType = ContentType('text', 'event-stream');
          r.response.bufferOutput = false;
          streams[token!] = r.response;
          r.response.write(': open\n\n');
          await r.response.flush();
        case 'POST':
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          final id = body['extensions']['operationId'] as String;
          if (failNextPostWith404) {
            failNextPostWith404 = false;
            r.response.statusCode = 404;
            await r.response.close();
            return;
          }
          (posted[token!] ??= []).add(id);
          r.response.statusCode = 202;
          await r.response.close();
          final stream = streams[token];
          stream?.write(
            'event: next\ndata: ${jsonEncode({
              'id': id,
              'payload': {
                'data': {'s': body['operationName']},
              },
            })}\n\n',
          );
          await stream?.flush();
        case 'DELETE':
          deleted.add(r.uri.queryParameters['operationId']!);
          r.response.statusCode = 200;
          await r.response.close();
      }
    });
  }

  String get url => 'http://${http.address.host}:${http.port}/';
  Future<void> stop() => http.close(force: true);
}

void main() {
  late _Server server;

  Request sub(String name) => Request(
    operation: Operation(
      document: parseString('subscription $name { s }'),
      operationName: name,
    ),
  );

  Future<void> settle([int ms = 300]) =>
      Future.delayed(Duration(milliseconds: ms));

  SseSingleConnectionLink makeLink() => SseSingleConnectionLink(
    server.url,
    reconnectInterval: const Duration(milliseconds: 20),
    idleCloseDelay: const Duration(milliseconds: 200),
  );

  setUp(() async {
    server = _Server();
    await server.start();
  });

  tearDown(() => server.stop());

  test('operations share one reserved stream', () async {
    final link = makeLink();
    final a = <dynamic>[];
    final b = <dynamic>[];
    final subA = link.request(sub('A')).listen((r) => a.add(r.data));
    final subB = link.request(sub('B')).listen((r) => b.add(r.data));
    await settle();

    expect(server.puts, 1);
    expect(server.gets, 1);
    expect(a, [
      {'s': 'A'},
    ]);
    expect(b, [
      {'s': 'B'},
    ]);

    await subA.cancel();
    await subB.cancel();
    await link.dispose();
  });

  test('cancelling an operation sends DELETE with its id', () async {
    final link = makeLink();
    final sub1 = link.request(sub('A')).listen((_) {});
    await settle();
    final id = server.posted['tok1']!.single;
    await sub1.cancel();
    await settle(100);

    expect(server.deleted, [id]);
    await link.dispose();
  });

  test('a server complete event ends only that operation', () async {
    final link = makeLink();
    var aDone = false;
    final bGot = <dynamic>[];
    link.request(sub('A')).listen((_) {}, onDone: () => aDone = true);
    final subB = link.request(sub('B')).listen((r) => bGot.add(r.data));
    await settle();

    final idA = server.posted['tok1']!.first;
    server.streams['tok1']!.write(
      'event: complete\ndata: ${jsonEncode({'id': idA})}\n\n',
    );
    await server.streams['tok1']!.flush();
    await settle(100);

    expect(aDone, isTrue);
    await subB.cancel();
    await link.dispose();
  });

  test('closes the stream when idle and re-reserves for the next', () async {
    final link = makeLink();
    final first = link.request(sub('A')).listen((_) {});
    await settle();
    await first.cancel();
    await settle(500);

    final second = link.request(sub('B')).listen((_) {});
    await settle();

    expect(server.puts, 2);
    await second.cancel();
    await link.dispose();
  });

  test('re-reserves and re-sends live operations after a drop', () async {
    final link = makeLink();
    final got = <dynamic>[];
    final s = link.request(sub('A')).listen((r) => got.add(r.data));
    await settle();
    await server.streams['tok1']!.close();
    await settle(500);

    expect(server.puts, 2);
    expect(got, hasLength(2)); // re-sent on the new stream
    await s.cancel();
    await link.dispose();
  });

  test('a 404 on an operation POST reopens the stream', () async {
    final link = makeLink();
    server.failNextPostWith404 = true;
    final got = <dynamic>[];
    final s = link.request(sub('A')).listen((r) => got.add(r.data));
    await settle(800);

    expect(server.puts, 2);
    expect(got, [
      {'s': 'A'},
    ]);
    await s.cancel();
    await link.dispose();
  });

  group('connection status', () {
    List<SubscriptionConnectionStatus> record(SseSingleConnectionLink link) {
      final seen = <SubscriptionConnectionStatus>[];
      link.connectionStatus.stream.listen((s) => seen.add(s.status));
      return seen;
    }

    test('connects: connecting then connected', () async {
      final link = makeLink();
      final seen = record(link);
      final s = link.request(sub('A')).listen((_) {});
      await settle();
      expect(seen, [
        SubscriptionConnectionStatus.connecting,
        SubscriptionConnectionStatus.connected,
      ]);
      await s.cancel();
      await link.dispose();
    });

    test('stream drop: reconnecting then connected, error cleared', () async {
      final link = makeLink();
      final seen = record(link);
      final s = link.request(sub('A')).listen((_) {});
      await settle();
      await server.streams['tok1']!.close();
      await settle(500);
      expect(seen, [
        SubscriptionConnectionStatus.connecting,
        SubscriptionConnectionStatus.connected,
        SubscriptionConnectionStatus.reconnecting,
        SubscriptionConnectionStatus.connected,
      ]);
      expect(link.connectionStatus.value.lastError, isNull);
      await s.cancel();
      await link.dispose();
    });

    test('exhausted retries is error and sticky', () async {
      server.failPuts = true;
      final link = SseSingleConnectionLink(
        server.url,
        reconnectInterval: const Duration(milliseconds: 20),
        maxReconnectAttempts: 1,
      );
      final s = link.request(sub('A')).listen((_) {}, onError: (_) {});
      await settle(500);
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.error,
      );
      expect(link.connectionStatus.value.lastError, isNotNull);
      await s.cancel();
      await link.dispose();
    });

    test('last subscription cancelled is disconnected, not error', () async {
      final link = makeLink();
      final s = link.request(sub('A')).listen((_) {});
      await settle();
      await s.cancel();
      await settle(500);
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.disconnected,
      );
      expect(link.connectionStatus.value.lastError, isNull);
      await link.dispose();
    });

    test('dispose leaves disconnected and closes the stream', () async {
      final link = makeLink();
      final done = link.connectionStatus.stream.drain<void>();
      link.request(sub('A')).listen((_) {});
      await settle();
      await link.dispose();
      await done.timeout(const Duration(seconds: 2));
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.disconnected,
      );
    });
  });

  test('a subscription reports its own status to its notifier', () async {
    final link = makeLink();
    final n = ConnectionStatusNotifier();
    final seen = <SubscriptionConnectionStatus>[];
    n.stream.listen((s) => seen.add(s.status));
    final s = link
        .request(
          Request(
            operation: Operation(
              document: parseString('subscription A { s }'),
              operationName: 'A',
            ),
            context: Context().withEntry(ConnectionStatusContextEntry(n)),
          ),
        )
        .listen((_) {});
    await settle();
    expect(seen, [
      SubscriptionConnectionStatus.connecting,
      SubscriptionConnectionStatus.connected,
    ]);
    await s.cancel();
    expect(n.value.status, SubscriptionConnectionStatus.disconnected);
    await link.dispose();
  });
}
