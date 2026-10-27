import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart' show ServerException;
import 'package:mk_graphql/mk_graphql.dart';

void main() {
  late HttpServer server;
  late String url;

  Request subscription() => Request(
    operation: Operation(
      document: parseString('subscription S { s }'),
      operationName: 'S',
    ),
  );

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.host}:${server.port}/';
  });

  tearDown(() => server.close(force: true));

  test('reconnects a dropped stream, sending Last-Event-ID', () async {
    var connections = 0;
    final lastEventIds = <String?>[];
    server.listen((request) async {
      connections++;
      lastEventIds.add(request.headers.value('last-event-id'));
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      if (connections == 1) {
        // Drops without the mandatory `complete` event.
        request.response.write(
          'id: 7\nevent: next\ndata: {"data":{"s":1}}\n\n',
        );
      } else {
        request.response.write(
          'event: next\ndata: {"data":{"s":2}}\n\nevent: complete\n\n',
        );
      }
      await request.response.close();
    });

    final link = SseLink(
      url,
      reconnectInterval: const Duration(milliseconds: 10),
    );
    final data = await link.request(subscription()).map((r) => r.data).toList();

    expect(data, [
      {'s': 1},
      {'s': 2},
    ]);
    expect(connections, 2);
    expect(lastEventIds, [null, '7']);
  });

  test('cancelling the subscription closes the connection', () async {
    var closed = false;
    server.listen((request) async {
      request.response.headers.chunkedTransferEncoding = false;
      final socket = await request.response.detachSocket(writeHeaders: true);
      socket.listen(
        (_) {},
        onDone: () => closed = true,
        onError: (_) => closed = true,
      );
      socket.add('event: next\ndata: {"data":{"s":1}}\n\n'.codeUnits);
    });

    final link = SseLink(url);
    final sub = link.request(subscription()).listen((_) {});
    await Future.delayed(const Duration(milliseconds: 300));
    await sub.cancel().timeout(const Duration(seconds: 5));
    await Future.delayed(const Duration(milliseconds: 300));

    expect(closed, isTrue);
  });

  test('a 401 is surfaced for AuthLink, not retried by the link', () async {
    var connections = 0;
    server.listen((request) async {
      connections++;
      await request.drain<void>();
      request.response.statusCode = 401;
      await request.response.close();
    });

    final link = SseLink(
      url,
      reconnectInterval: const Duration(milliseconds: 10),
    );
    final error = await link
        .request(subscription())
        .toList()
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ServerException>());
    expect((error as ServerException).statusCode, 401);
    expect(connections, 1);
  });

  test('gives up after maxReconnectAttempts on a failing server', () async {
    var connections = 0;
    server.listen((request) async {
      connections++;
      await request.drain<void>();
      request.response.statusCode = 503;
      await request.response.close();
    });

    final link = SseLink(
      url,
      reconnectInterval: const Duration(milliseconds: 10),
      maxReconnectAttempts: 2,
    );
    final error = await link
        .request(subscription())
        .toList()
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ServerException>());
    expect(connections, 3);
  });

  test('keeps the GraphQL errors from a rejected request body', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"errors":[{"message":"Cannot query field \\"x\\"","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}',
      );
      await request.response.close();
    });

    final link = SseLink(url);
    final error = await link
        .request(subscription())
        .toList()
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<ServerException>());
    final parsed = (error as ServerException).parsedResponse;
    expect(
      parsed?.errors?.single.extensions?['code'],
      'GRAPHQL_VALIDATION_FAILED',
    );
  });
}
