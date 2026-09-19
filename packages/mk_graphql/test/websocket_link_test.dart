import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:mk_graphql/mk_graphql.dart';

void main() {
  group('WebSocketLink reconnect backoff', () {
    late HttpServer server;
    late List<DateTime> connectionTimes;
    late String url;

    setUp(() async {
      connectionTimes = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'ws://${server.address.host}:${server.port}';
      // A server that accepts every WebSocket upgrade and immediately drops
      // it, before ever sending `connection_ack` — so every reconnect
      // attempt fails and the attempt counter is never reset.
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        connectionTimes.add(DateTime.now());
        await socket.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('successive reconnect gaps grow instead of staying fixed', () async {
      final link = WebSocketLink(
        url,
        reconnectInterval: const Duration(milliseconds: 60),
        reconnectBackoffMultiplier: 3,
        maxReconnectInterval: const Duration(seconds: 5),
        reconnectJitter: 0,
      );

      final request = Request(
        operation: Operation(
          document: parseString('subscription S { s }'),
          operationName: 'S',
        ),
      );
      final sub = link.request(request).listen((_) {}, onError: (_) {});

      // Expected gaps with a 60ms base and 3x multiplier: ~60ms, ~180ms,
      // ~540ms. Wait long enough for at least four connections.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (connectionTimes.length < 4 && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      await sub.cancel();
      await link.dispose();

      expect(connectionTimes.length, greaterThanOrEqualTo(4));
      final gaps = <int>[
        for (var i = 1; i < connectionTimes.length; i++)
          connectionTimes[i].difference(connectionTimes[i - 1]).inMilliseconds,
      ];
      // A fixed 60ms interval would keep every gap near 60ms; with backoff
      // each gap is meaningfully longer than the last (generous margin so a
      // loaded CI machine doesn't flake this).
      expect(gaps[1], greaterThan(gaps[0] * 1.5), reason: 'gaps: $gaps');
      expect(gaps[2], greaterThan(gaps[1] * 1.5), reason: 'gaps: $gaps');
    });
  });
}
