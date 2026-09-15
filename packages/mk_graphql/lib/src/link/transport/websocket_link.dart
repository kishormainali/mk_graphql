import 'dart:async';
import 'dart:convert';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/document_print_cache.dart';

typedef WebSocketPayloadCallback = FutureOr<dynamic> Function();

/// Universal WebSocket [Link] for GraphQL Subscriptions.
///
/// Implements both the modern `graphql-transport-ws` (`graphql-ws`) specification
/// and legacy `subscriptions-transport-ws` specification.
class WebSocketLink extends Link {
  final String url;
  final dynamic initialPayload;
  final Iterable<String> subprotocols;
  final Duration reconnectInterval;
  final bool autoReconnect;
  final ResponseParser parser;

  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  bool _connected = false;
  bool _isDisposed = false;
  int _nextId = 0;

  final _activeSubscriptions = <String, StreamController<Response>>{};

  WebSocketLink(
    this.url, {
    this.initialPayload,
    this.subprotocols = const ['graphql-transport-ws', 'graphql-ws'],
    this.reconnectInterval = const Duration(seconds: 3),
    this.autoReconnect = true,
    this.parser = const ResponseParser(),
  });

  /// In-flight connection attempt, if any. [_connect] awaits `payload()`
  /// before flipping [_connected], so without this guard two subscriptions
  /// started back-to-back (both seeing `_connected == false` before either
  /// finishes connecting) would each open their own [WebSocketChannel] — the
  /// second silently replacing (and leaking) the first. Single-flight, same
  /// pattern as `AuthLink._ongoingRefresh`.
  Future<void>? _connectFuture;

  Future<void> _connect() {
    if (_connected || _isDisposed) return Future.value();
    return _connectFuture ??=
        _doConnect().whenComplete(() => _connectFuture = null);
  }

  Future<void> _doConnect() async {
    try {
      _channel = WebSocketChannel.connect(
        Uri.parse(url),
        protocols: subprotocols,
      );

      dynamic payload = initialPayload;
      if (payload is Function) {
        payload = await payload();
      }

      _channel!.sink.add(jsonEncode({
        'type': 'connection_init',
        if (payload != null) 'payload': payload,
      }));

      _connected = true;

      _channelSubscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
    } catch (e) {
      _onError(e);
    }
  }

  void _onMessage(dynamic event) {
    try {
      final message = jsonDecode(event as String) as Map<String, dynamic>;
      final type = message['type'] as String?;
      final id = message['id'] as String?;

      if (type == 'ping') {
        _channel?.sink.add(jsonEncode({'type': 'pong'}));
        return;
      }

      if (type == 'connection_ack') {
        return;
      }

      if (id != null && _activeSubscriptions.containsKey(id)) {
        final controller = _activeSubscriptions[id]!;
        if (type == 'next' || type == 'data') {
          final payload =
              message['payload'] as Map<String, dynamic>? ?? message;
          final response = parser.parseResponse(payload);
          controller.add(response);
        } else if (type == 'error') {
          final payload = message['payload'];
          if (payload is List) {
            final errors = payload
                .whereType<Map<String, dynamic>>()
                .map(parser.parseError)
                .toList();
            controller.add(Response(errors: errors, response: message));
          } else {
            controller.addError(
              ServerException(originalException: payload),
            );
          }
        } else if (type == 'complete') {
          controller.close();
          _activeSubscriptions.remove(id);
        }
      }
    } catch (_) {
      // Ignore malformed payloads
    }
  }

  void _onError(dynamic error) {
    _connected = false;
    for (final controller in _activeSubscriptions.values) {
      if (!controller.isClosed) {
        controller.addError(ServerException(originalException: error));
      }
    }
    if (autoReconnect && !_isDisposed) {
      Timer(reconnectInterval, _reconnect);
    }
  }

  void _onDone() {
    _connected = false;
    _channel = null;
    if (autoReconnect && !_isDisposed && _activeSubscriptions.isNotEmpty) {
      Timer(reconnectInterval, _reconnect);
    }
  }

  void _reconnect() {
    if (_isDisposed) return;
    _connect();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) {
    final subId = '${req.operation.operationName ?? 'sub'}_${++_nextId}';
    final controller = StreamController<Response>();

    _activeSubscriptions[subId] = controller;
    _sendSubscribe(subId, req);

    controller.onCancel = () {
      _sendComplete(subId);
      _activeSubscriptions.remove(subId);
      controller.close();
    };

    return controller.stream;
  }

  Future<void> _sendSubscribe(String id, Request req) async {
    await _connect();
    final docString = printDocumentCached(req.operation.document);
    _channel?.sink.add(jsonEncode({
      'id': id,
      'type': 'subscribe',
      'payload': {
        'query': docString,
        if (req.operation.operationName != null)
          'operationName': req.operation.operationName,
        if (req.variables.isNotEmpty) 'variables': req.variables,
      },
    }));
  }

  void _sendComplete(String id) {
    try {
      _channel?.sink.add(jsonEncode({'id': id, 'type': 'complete'}));
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _connected = false;
    for (final controller in _activeSubscriptions.values) {
      await controller.close();
    }
    _activeSubscriptions.clear();
    await _channelSubscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }
}
