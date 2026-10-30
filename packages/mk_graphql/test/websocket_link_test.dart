import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart' show ServerException;
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

  group('WebSocketLink resubscribe on reconnect', () {
    late HttpServer server;
    late String url;

    tearDown(() => server.close(force: true));

    test(
      'resends subscribe for surviving subscriptions after a drop',
      () async {
        var connectionCount = 0;
        // Per-connection count of 'subscribe' messages received, keyed by the
        // subscription id the client actually used, so the test can tell a
        // resend on the *second* socket apart from the original send on the
        // first (and confirm it's the same id both times).
        final subscribeCountsPerConnection = <int, Map<String, int>>{};

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        url = 'ws://${server.address.host}:${server.port}';
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          final connectionIndex = connectionCount++;
          subscribeCountsPerConnection[connectionIndex] = {};

          socket.listen((event) {
            final message = jsonDecode(event as String) as Map<String, dynamic>;
            if (message['type'] == 'connection_init') {
              socket.add(jsonEncode({'type': 'connection_ack'}));
            } else if (message['type'] == 'subscribe') {
              final id = message['id'] as String;
              final counts = subscribeCountsPerConnection[connectionIndex]!;
              counts[id] = (counts[id] ?? 0) + 1;
              if (connectionIndex == 0) {
                // Drop the very first subscription's socket without ever
                // completing it, simulating a network blip.
                socket.close();
              } else {
                // On the reconnect, prove delivery actually resumed.
                socket.add(
                  jsonEncode({
                    'id': id,
                    'type': 'next',
                    'payload': {
                      'data': {'s': 'resumed'},
                    },
                  }),
                );
              }
            }
          });
        });

        final link = WebSocketLink(
          url,
          reconnectInterval: const Duration(milliseconds: 20),
          reconnectJitter: 0,
        );

        final request = Request(
          operation: Operation(
            document: parseString('subscription S { s }'),
            operationName: 'S',
          ),
        );

        final responses = <Response>[];
        final sub = link.request(request).listen(responses.add);

        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (responses.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 20));
        }
        await sub.cancel();
        await link.dispose();

        // The reconnect must have happened, and the resend must have carried
        // the *same* subscription id the server saw on the first, dropped
        // connection — otherwise the server has no way to know what to push.
        expect(connectionCount, greaterThanOrEqualTo(2));
        final firstConnectionIds = subscribeCountsPerConnection[0]!;
        final secondConnectionIds = subscribeCountsPerConnection[1]!;
        expect(firstConnectionIds.keys, hasLength(1));
        expect(secondConnectionIds.keys, equals(firstConnectionIds.keys));
        expect(firstConnectionIds.values.single, 1);
        expect(secondConnectionIds.values.single, 1);
        expect(responses, hasLength(1));
        expect(responses.single.data, {'s': 'resumed'});
      },
    );
  });

  group('WebSocketLink authentication', () {
    late HttpServer server;
    late String url;

    tearDown(() => server.close(force: true));

    Request subRequest(String name) => Request(
      operation: Operation(
        document: parseString('subscription $name { s }'),
        operationName: name,
      ),
    );

    test(
      '4401 close surfaces as a 401 ServerException, no reconnect',
      () async {
        var connections = 0;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        url = 'ws://${server.address.host}:${server.port}';
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          connections++;
          await socket.close(4401, 'Unauthorized');
        });

        final link = WebSocketLink(url, reconnectInterval: Duration.zero);
        final error = await link
            .request(subRequest('A'))
            .first
            .then<Object?>((_) => null, onError: (Object e) => e);
        await Future.delayed(const Duration(milliseconds: 200));
        await link.dispose();

        expect(error, isA<ServerException>());
        expect((error as ServerException).statusCode, 401);
        expect(connections, 1);
      },
    );

    test('a changed payload replaces the socket and resubscribes', () async {
      final initPayloads = <Object?>[];
      final subscribes = <int>[]; // socket index per subscribe message
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'ws://${server.address.host}:${server.port}';
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        final index = initPayloads.length;
        initPayloads.add(null);
        socket.listen((raw) {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'connection_init') {
            initPayloads[index] = m['payload'];
            socket.add(jsonEncode({'type': 'connection_ack'}));
          }
          if (m['type'] == 'subscribe') subscribes.add(index);
        });
      });

      var token = 'old';
      final link = WebSocketLink(url, initialPayload: () => {'t': token});
      final a = link.request(subRequest('A')).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 200));
      token = 'new';
      final b = link.request(subRequest('B')).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 300));
      await a.cancel();
      await b.cancel();
      await link.dispose();

      expect(initPayloads, [
        {'t': 'old'},
        {'t': 'new'},
      ]);
      // A once on the old socket, then A and B (each exactly once) on the new.
      expect(subscribes, [0, 1, 1]);
    });
  });

  group('WebSocketLink connection_ack', () {
    late HttpServer server;
    late String url;

    tearDown(() => server.close(force: true));

    Request subRequest() => Request(
      operation: Operation(
        document: parseString('subscription S { s }'),
        operationName: 'S',
      ),
    );

    test('subscribe is only sent after connection_ack', () async {
      final received = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'ws://${server.address.host}:${server.port}';
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) async {
          final type = (jsonDecode(raw as String) as Map)['type'] as String;
          received.add(type);
          if (type == 'connection_init') {
            await Future.delayed(const Duration(milliseconds: 150));
            received.add('ack_sent');
            socket.add(jsonEncode({'type': 'connection_ack'}));
          }
        });
      });

      final link = WebSocketLink(url);
      final sub = link.request(subRequest()).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      await link.dispose();

      expect(received.take(3), ['connection_init', 'ack_sent', 'subscribe']);
    });

    test(
      'a server that never acks times out and errors the subscriber',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        url = 'ws://${server.address.host}:${server.port}';
        server.listen((request) async {
          await WebSocketTransformer.upgrade(request);
        });

        final link = WebSocketLink(
          url,
          connectionAckTimeout: const Duration(milliseconds: 100),
          autoReconnect: false,
        );
        final error = await link
            .request(subRequest())
            .first
            .then<Object?>((_) => null, onError: (Object e) => e);
        await link.dispose();

        expect(error, isA<ServerException>());
      },
    );

    test(
      'maxConnectionAge opens a fresh socket for a later subscribe',
      () async {
        var connections = 0;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        url = 'ws://${server.address.host}:${server.port}';
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          connections++;
          socket.listen((raw) {
            if ((jsonDecode(raw as String) as Map)['type'] ==
                'connection_init') {
              socket.add(jsonEncode({'type': 'connection_ack'}));
            }
          });
        });

        final link = WebSocketLink(
          url,
          maxConnectionAge: const Duration(milliseconds: 100),
        );
        final a = link.request(subRequest()).listen((_) {}, onError: (_) {});
        await Future.delayed(const Duration(milliseconds: 250));
        final b = link.request(subRequest()).listen((_) {}, onError: (_) {});
        await Future.delayed(const Duration(milliseconds: 250));
        await a.cancel();
        await b.cancel();
        await link.dispose();

        expect(connections, 2);
      },
    );
  });

  group('WebSocketLink long-lived connection', () {
    late HttpServer server;
    late int connections;
    late int pings;
    late int normalCloses;
    late bool answerPings;

    Request subRequest(String name) => Request(
      operation: Operation(
        document: parseString('subscription $name { s }'),
        operationName: name,
      ),
    );

    setUp(() async {
      connections = pings = normalCloses = 0;
      answerPings = true;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) => protocols.first,
        );
        connections++;
        socket.listen(
          (raw) {
            final m = jsonDecode(raw as String) as Map<String, dynamic>;
            if (m['type'] == 'connection_init') {
              socket.add(jsonEncode({'type': 'connection_ack'}));
            } else if (m['type'] == 'ping') {
              pings++;
              if (answerPings) socket.add(jsonEncode({'type': 'pong'}));
            }
          },
          onDone: () {
            if (socket.closeCode == 1000) normalCloses++;
          },
        );
      });
    });

    tearDown(() => server.close(force: true));

    WebSocketLink makeLink() => WebSocketLink(
      'ws://${server.address.host}:${server.port}',
      idleCloseDelay: const Duration(milliseconds: 100),
      pingInterval: const Duration(milliseconds: 100),
      pongTimeout: const Duration(milliseconds: 150),
      reconnectInterval: const Duration(milliseconds: 20),
      reconnectJitter: 0,
    );

    test('keeps one socket alive with pings while answered', () async {
      final link = makeLink();
      final sub = link.request(subRequest('A')).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      await link.dispose();

      expect(connections, 1);
      expect(pings, greaterThanOrEqualTo(2));
    });

    test('replaces a socket that stops answering pings', () async {
      final link = makeLink();
      final sub = link.request(subRequest('A')).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 250));
      answerPings = false;
      await Future.delayed(const Duration(milliseconds: 900));
      await sub.cancel();
      await link.dispose();

      expect(connections, greaterThanOrEqualTo(2));
    });

    test(
      'closes the socket after the last subscription is cancelled',
      () async {
        final link = makeLink();
        final a = link.request(subRequest('A')).listen((_) {}, onError: (_) {});
        await Future.delayed(const Duration(milliseconds: 200));
        await a.cancel();
        await Future.delayed(const Duration(milliseconds: 500));
        expect(normalCloses, 1);

        final before = connections;
        final b = link.request(subRequest('B')).listen((_) {}, onError: (_) {});
        await Future.delayed(const Duration(milliseconds: 300));
        await b.cancel();
        await link.dispose();

        expect(connections, before + 1); // the next subscription reopened it
      },
    );

    test('dispose stops reconnecting', () async {
      final link = makeLink();
      final sub = link.request(subRequest('A')).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      await link.dispose();
      final after = connections;
      await Future.delayed(const Duration(milliseconds: 400));

      expect(connections, after);
    });
  });

  group('WebSocketLink legacy graphql-ws (subscriptions-transport-ws)', () {
    test('uses start/stop and delivers data', () async {
      final received = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) => 'graphql-ws',
        );
        socket.listen((raw) {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          received.add(m['type'] as String);
          if (m['type'] == 'connection_init') {
            socket.add(jsonEncode({'type': 'connection_ack'}));
          } else if (m['type'] == 'start') {
            socket.add(
              jsonEncode({
                'id': m['id'],
                'type': 'data',
                'payload': {
                  'data': {'s': 1},
                },
              }),
            );
          }
        });
      });

      final link = WebSocketLink(
        'ws://${server.address.host}:${server.port}',
        idleCloseDelay: null,
      );
      final request = Request(
        operation: Operation(
          document: parseString('subscription S { s }'),
          operationName: 'S',
        ),
      );
      final first = await link.request(request).first;
      expect(first.data, {'s': 1});

      final sub = link.request(request).listen((_) {});
      await Future.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
      await Future.delayed(const Duration(milliseconds: 100));
      await link.dispose();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(received, containsAllInOrder(['connection_init', 'start']));
      expect(received, contains('stop'));
      expect(received, contains('connection_terminate'));
      expect(received, isNot(contains('subscribe')));
    });
  });

  group('WebSocketLink graphql-ws (graphql-transport-ws) server behavior', () {
    late HttpServer server;
    late int connections;
    late int subscribes;

    Request subRequest() => Request(
      operation: Operation(
        document: parseString('subscription S { s }'),
        operationName: 'S',
      ),
    );

    Future<void> serve(
      void Function(WebSocket, Map<String, dynamic>) onMsg,
    ) async {
      connections = subscribes = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (p) => 'graphql-transport-ws',
        );
        connections++;
        socket.listen((raw) {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'connection_init') {
            socket.add(jsonEncode({'type': 'connection_ack'}));
          } else if (m['type'] == 'subscribe') {
            subscribes++;
          }
          onMsg(socket, m);
        });
      });
    }

    test(
      'an error message ends the operation and is not resubscribed',
      () async {
        await serve((socket, m) {
          if (m['type'] == 'subscribe') {
            socket.add(
              jsonEncode({
                'id': m['id'],
                'type': 'error',
                'payload': [
                  {'message': 'boom'},
                ],
              }),
            );
            // Then the socket drops: nothing must be resubscribed on reconnect.
            Future.delayed(const Duration(milliseconds: 50), socket.close);
          }
        });
        final link = WebSocketLink(
          'ws://${server.address.host}:${server.port}',
          reconnectInterval: const Duration(milliseconds: 20),
          reconnectJitter: 0,
          idleCloseDelay: null,
        );
        final responses = await link.request(subRequest()).toList();
        await Future.delayed(const Duration(milliseconds: 300));
        await link.dispose();

        expect(responses.single.errors!.single.message, 'boom');
        expect(subscribes, 1);
      },
    );

    test(
      'a fatal close code (4400) fails subscribers without reconnecting',
      () async {
        await serve((socket, m) {
          if (m['type'] == 'subscribe') socket.close(4400, 'Bad request');
        });
        final link = WebSocketLink(
          'ws://${server.address.host}:${server.port}',
          reconnectInterval: const Duration(milliseconds: 20),
          idleCloseDelay: null,
        );
        final error = await link
            .request(subRequest())
            .toList()
            .then<Object?>((_) => null, onError: (Object e) => e);
        await Future.delayed(const Duration(milliseconds: 200));
        await link.dispose();

        expect(error, isA<ServerException>());
        expect(connections, 1);
      },
    );
  });

  group('WebSocketLink connection status', () {
    late HttpServer server;
    late int connections;
    late String url;

    Request subRequest() => Request(
      operation: Operation(
        document: parseString('subscription S { s }'),
        operationName: 'S',
      ),
    );

    /// [onConnection] gets the socket and its 0-based connection index and
    /// decides what to do after it acks `connection_init` (acks unless
    /// [ack] is false).
    Future<void> serve(
      void Function(WebSocket socket, int index) onConnection, {
      bool ack = true,
    }) async {
      connections = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      url = 'ws://${server.address.host}:${server.port}';
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (p) => 'graphql-transport-ws',
        );
        final index = connections++;
        socket.listen((raw) {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'connection_init' && ack) {
            socket.add(jsonEncode({'type': 'connection_ack'}));
            onConnection(socket, index);
          }
        });
      });
    }

    List<SubscriptionConnectionStatus> record(WebSocketLink link) {
      final seen = <SubscriptionConnectionStatus>[];
      link.connectionStatus.stream.listen((s) => seen.add(s.status));
      return seen;
    }

    const wait = Duration(milliseconds: 300);

    test('connects: connecting then connected', () async {
      await serve((_, __) {});
      final link = WebSocketLink(url, idleCloseDelay: null);
      final seen = record(link);
      final sub = link.request(subRequest()).listen((_) {});
      await Future.delayed(wait);
      expect(seen, [
        SubscriptionConnectionStatus.connecting,
        SubscriptionConnectionStatus.connected,
      ]);
      await sub.cancel();
      await link.dispose();
    });

    test('drop then reconnect keeps lastError while reconnecting', () async {
      await serve((socket, index) {
        if (index == 0)
          Future.delayed(const Duration(milliseconds: 30), socket.close);
      });
      final link = WebSocketLink(
        url,
        reconnectInterval: const Duration(milliseconds: 150),
        reconnectJitter: 0,
        idleCloseDelay: null,
      );
      final seen = record(link);
      final sub = link.request(subRequest()).listen((_) {}, onError: (_) {});
      await Future.delayed(const Duration(milliseconds: 120));
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.reconnecting,
      );
      expect(link.connectionStatus.value.lastError, isNotNull);
      await Future.delayed(wait);
      expect(seen, [
        SubscriptionConnectionStatus.connecting,
        SubscriptionConnectionStatus.connected,
        SubscriptionConnectionStatus.reconnecting,
        SubscriptionConnectionStatus.connected,
      ]);
      expect(link.connectionStatus.value.lastError, isNull);
      await sub.cancel();
      await link.dispose();
    });

    test('4401 close is error, sticky through the next connecting', () async {
      await serve((socket, index) {
        if (index == 0) socket.close(4401, 'Unauthorized');
      });
      final link = WebSocketLink(url, idleCloseDelay: null);
      final first = link.request(subRequest()).listen((_) {}, onError: (_) {});
      await Future.delayed(wait);
      final state = link.connectionStatus.value;
      expect(state.status, SubscriptionConnectionStatus.error);
      expect((state.lastError as ServerException).statusCode, 401);
      await first.cancel();

      final states = <SubscriptionConnectionState>[];
      link.connectionStatus.stream.listen(states.add);
      final second = link.request(subRequest()).listen((_) {});
      await Future.delayed(wait);
      // The error is still on the first `connecting` state, and only the
      // `connected` one clears it.
      expect(states.first.status, SubscriptionConnectionStatus.connecting);
      expect(states.first.lastError, isNotNull);
      expect(states.last.status, SubscriptionConnectionStatus.connected);
      expect(states.last.lastError, isNull);
      await second.cancel();
      await link.dispose();
    });

    test('autoReconnect false: a drop ends in error', () async {
      await serve((socket, _) => socket.close());
      final link = WebSocketLink(
        url,
        autoReconnect: false,
        idleCloseDelay: null,
      );
      final sub = link.request(subRequest()).listen((_) {}, onError: (_) {});
      await Future.delayed(wait);
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.error,
      );
      await sub.cancel();
      await link.dispose();
    });

    test('idle close is disconnected', () async {
      await serve((_, __) {});
      final link = WebSocketLink(
        url,
        idleCloseDelay: const Duration(milliseconds: 50),
      );
      final sub = link.request(subRequest()).listen((_) {});
      await Future.delayed(const Duration(milliseconds: 150));
      await sub.cancel();
      await Future.delayed(wait);
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.disconnected,
      );
      expect(link.connectionStatus.value.lastError, isNull);
      await link.dispose();
    });

    test('dispose leaves disconnected and closes the stream', () async {
      await serve((_, __) {});
      final link = WebSocketLink(url, idleCloseDelay: null);
      final done = link.connectionStatus.stream.drain<void>();
      final sub = link.request(subRequest()).listen((_) {});
      await Future.delayed(const Duration(milliseconds: 150));
      await link.dispose();
      await done.timeout(const Duration(seconds: 2));
      expect(
        link.connectionStatus.value.status,
        SubscriptionConnectionStatus.disconnected,
      );
      await sub.cancel();
    });
  });
}
