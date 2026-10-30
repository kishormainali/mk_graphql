import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/backoff.dart';
import '../../core/connection_status.dart';
import '../../core/document_print_cache.dart';
import '../../core/error.dart' show RevokeTokenException;

typedef WebSocketPayloadCallback = FutureOr<dynamic> Function();

/// Universal WebSocket [Link] for GraphQL Subscriptions.
///
/// Implements both the modern `graphql-transport-ws` (`graphql-ws`) specification
/// and legacy `subscriptions-transport-ws` specification.
class WebSocketLink extends Link implements ConnectionStatusSource {
  final String url;
  final dynamic initialPayload;
  final Iterable<String> subprotocols;

  /// Delay before the first reconnect attempt after a drop. Each further
  /// consecutive failed attempt multiplies this by
  /// [reconnectBackoffMultiplier], capped at [maxReconnectInterval] — a
  /// fixed interval here would otherwise retry a dead server or absent
  /// network forever at full speed, needlessly draining battery and
  /// spamming the network every [reconnectInterval] indefinitely.
  final Duration reconnectInterval;

  /// Upper bound the backed-off reconnect delay is clamped to, however many
  /// consecutive attempts have failed.
  final Duration maxReconnectInterval;

  final double reconnectBackoffMultiplier;

  /// Randomizes each computed reconnect delay by up to this fraction
  /// (`0.0`–`1.0`) in either direction, so many clients disconnected by the
  /// same event (a server restart, a network blip) don't all reconnect in
  /// the same instant and re-cause the spike that dropped them.
  final double reconnectJitter;

  /// How long to wait for the server's `connection_ack` before giving up on
  /// the socket (and reconnecting, if [autoReconnect]). `subscribe` is only
  /// sent after the ack — servers that authenticate in `connection_init`
  /// close the socket (`4401`) on a `subscribe` that arrives before it.
  /// `null` skips the wait and subscribes immediately, for the rare server
  /// that never acks.
  final Duration? connectionAckTimeout;

  /// When set, a subscribe on a socket older than this opens a fresh one
  /// (re-resolving [initialPayload]) first. For servers that read the token
  /// once per socket and reject a long-lived socket's stale one, when no
  /// token-changed signal is available to recycle it sooner.
  final Duration? maxConnectionAge;

  /// How often a `ping` is sent on an idle `graphql-transport-ws` socket to
  /// prove the connection is still alive. A socket that dies silently (a
  /// NAT/proxy timeout, a phone switching networks) raises no error on its
  /// own, so without this a long-running subscription just stops delivering.
  /// `null` disables the heartbeat. Not sent on the legacy
  /// `subscriptions-transport-ws` protocol, which has no client `ping`.
  final Duration? pingInterval;

  /// How long past [pingInterval] the socket may stay completely silent (no
  /// `pong`, no data) before it is considered dead, dropped and reconnected.
  final Duration pongTimeout;

  /// How long the socket stays open after the last subscription is
  /// cancelled before it is closed (code `1000`). The delay lets a screen
  /// that unsubscribes and immediately re-subscribes reuse the socket. The
  /// next subscription opens a fresh one. `null` keeps the socket open until
  /// [dispose].
  final Duration? idleCloseDelay;

  /// While connected with an [initialPayload] callback, how often the payload
  /// is re-resolved (which refreshes an expired token) so an open socket is
  /// replaced with one carrying the new token *before* the server rejects the
  /// old one — rather than only noticing on the next `subscribe`. Active
  /// subscriptions are re-sent on the new socket. `null` disables the check.
  final Duration? payloadCheckInterval;

  final bool autoReconnect;
  final ResponseParser parser;

  /// Current connection status — see [SubscriptionConnectionStatus].
  @override
  final ConnectionStatusNotifier connectionStatus = ConnectionStatusNotifier();

  void _report(SubscriptionConnectionStatus status, [Object? error]) =>
      connectionStatus.report(this, status, error: error);

  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  bool _connected = false;
  bool _isDisposed = false;
  int _nextId = 0;

  /// Set after the first successful connect. Distinguishes a reconnect
  /// (where [_activeRequests] must be resent, since the server has no
  /// memory of them on the new socket) from the initial connect (where each
  /// subscription's own [_sendSubscribe] call already sends it exactly
  /// once — resending here too would send a duplicate `subscribe` for the
  /// same id).
  bool _hasConnectedOnce = false;

  /// Completes `true` on the current socket's `connection_ack`, `false` if it
  /// closes or errors first.
  Completer<bool>? _ack;

  /// When the current socket was acknowledged — see [maxConnectionAge].
  DateTime? _connectedAt;

  /// Payload the current socket's `connection_init` was sent with. A later
  /// subscribe that resolves a different one (the token was refreshed since)
  /// replaces the socket, because GraphQL-over-WebSocket servers authenticate
  /// the connection once, at `connection_init`.
  dynamic _connectedPayload;

  /// Ids whose `subscribe` was already sent on the current socket — stops a
  /// reconnect's resend and a request's own send from both sending the same
  /// id (servers close the socket on a duplicate id).
  final _sentIds = <String>{};

  /// Close codes servers use for a rejected `connection_init` (graphql-ws
  /// `4401 Unauthorized` / `4403 Forbidden`). Both are surfaced as HTTP 401,
  /// so `AuthLink` refreshes the token and re-subscribes (and revokes the
  /// session if the refresh fails), same as for queries and mutations.
  static const _unauthorizedCloseCodes = {4401, 4403};

  /// Close codes `graphql-ws` servers use for a failure that reconnecting
  /// can't fix — `4400` bad request, `4406` subprotocol not acceptable,
  /// `4409` duplicate subscriber id, `4429` too many init requests, `4500`
  /// internal error. Reconnecting would just be rejected the same way, so
  /// subscribers get the error instead.
  static const _fatalCloseCodes = {4400, 4406, 4409, 4429, 4500};

  /// Consecutive failed reconnect attempts since the last successful
  /// `connection_ack` — drives the exponential backoff in
  /// [_reconnectDelay]. Reset to `0` on every `connection_ack`.
  int _reconnectAttempt = 0;

  static final Random _random = Random();

  /// Last time anything (data, `pong`, `ping`, ack) arrived on the current
  /// socket — what the heartbeat judges liveness by.
  DateTime _lastMessageAt = DateTime.now();
  Timer? _heartbeatTimer;
  Timer? _payloadTimer;
  Timer? _reconnectTimer;
  Timer? _idleTimer;
  bool _rechecking = false;

  final _activeSubscriptions = <String, StreamController<Response>>{};

  /// The original [Request] behind each entry in [_activeSubscriptions],
  /// kept so a reconnect can resend `subscribe` for every subscription that
  /// survived the drop — the server has no memory of them across a new
  /// socket, so without this a resumed connection silently stops delivering
  /// data to callers who never cancelled.
  final _activeRequests = <String, Request>{};

  WebSocketLink(
    this.url, {
    this.initialPayload,
    this.subprotocols = const ['graphql-transport-ws', 'graphql-ws'],
    this.reconnectInterval = const Duration(seconds: 3),
    this.maxReconnectInterval = const Duration(seconds: 30),
    this.reconnectBackoffMultiplier = 1.5,
    this.reconnectJitter = 0.2,
    this.autoReconnect = true,
    this.connectionAckTimeout = const Duration(seconds: 10),
    this.maxConnectionAge,
    this.pingInterval = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 10),
    this.idleCloseDelay = const Duration(seconds: 5),
    this.payloadCheckInterval = const Duration(minutes: 1),
    this.parser = const ResponseParser(),
  }) : assert(
         reconnectJitter >= 0.0 && reconnectJitter <= 1.0,
         'reconnectJitter must be within 0.0–1.0',
       );

  /// Whether the negotiated subprotocol is the legacy
  /// `subscriptions-transport-ws` (named `graphql-ws`), which spells client
  /// messages differently: `start` / `stop` instead of `subscribe` /
  /// `complete`, and `connection_terminate` before closing.
  bool get _isLegacyProtocol => _channel?.protocol == 'graphql-ws';

  Duration _reconnectDelay() {
    final capped = cappedBackoffDelay(
      attempt: _reconnectAttempt,
      initialDelay: reconnectInterval,
      maxDelay: maxReconnectInterval,
      multiplier: reconnectBackoffMultiplier,
    );
    if (reconnectJitter <= 0.0) return capped;

    final cappedMs = capped.inMilliseconds;
    final spread = cappedMs * reconnectJitter;
    final jitteredMs = cappedMs + spread * (_random.nextDouble() * 2 - 1);
    return Duration(milliseconds: jitteredMs.clamp(0, double.infinity).round());
  }

  /// In-flight connection attempt, if any. [_connect] awaits `payload()`
  /// before flipping [_connected], so without this guard two subscriptions
  /// started back-to-back (both seeing `_connected == false` before either
  /// finishes connecting) would each open their own [WebSocketChannel] — the
  /// second silently replacing (and leaking) the first. Single-flight, same
  /// pattern as `AuthLink._ongoingRefresh`.
  Future<void>? _connectFuture;

  Future<void> _connect() {
    if (_connected || _isDisposed) return Future.value();
    return _connectFuture ??= _doConnect().whenComplete(
      () => _connectFuture = null,
    );
  }

  Future<dynamic> _resolvePayload() async {
    final payload = initialPayload;
    return payload is Function ? await payload() : payload;
  }

  Future<void> _doConnect() async {
    try {
      // Resolved before opening the socket: a failing payload (e.g. a
      // revoked session) must not leave a half-open channel behind.
      final payload = await _resolvePayload();
      if (_isDisposed) return;
      if (_reconnectAttempt == 0) {
        _report(SubscriptionConnectionStatus.connecting);
      }
      _channel = WebSocketChannel.connect(
        Uri.parse(url),
        protocols: subprotocols,
      );
      _connectedPayload = payload;
      _sentIds.clear();

      _channel!.sink.add(
        jsonEncode({
          'type': 'connection_init',
          if (payload != null) 'payload': payload,
        }),
      );

      final ack = _ack = Completer<bool>();
      _channelSubscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      final timeout = connectionAckTimeout;
      if (timeout != null) {
        final acked = await ack.future.timeout(
          timeout,
          onTimeout: () =>
              throw TimeoutException('No connection_ack from server', timeout),
        );
        // Closed/errored before the ack: _onDone/_onError already errored
        // the subscribers and scheduled the reconnect.
        if (!acked) return;
      }
      if (_isDisposed) {
        await _dropConnection();
        return;
      }
      _connected = true;
      _connectedAt = DateTime.now();
      _startTimers();

      if (_hasConnectedOnce) {
        _resendActiveSubscriptions();
      }
      _hasConnectedOnce = true;
    } on RevokeTokenException catch (e) {
      _failAll(e); // reconnecting can't help; the session is gone
    } catch (e) {
      await _dropConnection();
      _onError(e);
    }
  }

  /// Errors and drops every active subscription — used when reconnecting
  /// would just repeat the failure (revoked session, rejected credentials).
  void _failAll(Object error) {
    _report(SubscriptionConnectionStatus.error, error);
    final controllers = _activeSubscriptions.values.toList();
    _activeSubscriptions.clear();
    _activeRequests.clear();
    for (final controller in controllers) {
      if (controller.isClosed) continue;
      controller.addError(error);
      controller.close();
    }
  }

  /// Closes the current socket without triggering [_onDone]'s reconnect, so
  /// the next [_connect] opens a fresh one (re-resolving the payload).
  Future<void> _dropConnection() async {
    final sub = _channelSubscription;
    final channel = _channel;
    _channelSubscription = null;
    _channel = null;
    _connected = false;
    _stopTimers();
    if (_ack?.isCompleted == false) _ack!.complete(false);
    await sub?.cancel();
    if (channel != null) {
      if (channel.protocol == 'graphql-ws') {
        try {
          channel.sink.add(jsonEncode({'type': 'connection_terminate'}));
        } catch (_) {}
      }
      // A normal-closure handshake, bounded: a server that never answers the
      // close frame must not hang dispose or a reconnect.
      try {
        await channel.sink
            .close(1000, 'Normal Closure')
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  void _startTimers() {
    _stopTimers();
    _lastMessageAt = DateTime.now();
    final ping = pingInterval;
    if (ping != null && _channel?.protocol == 'graphql-transport-ws') {
      _heartbeatTimer = Timer.periodic(ping, (_) => _heartbeat(ping));
    }
    final check = payloadCheckInterval;
    if (check != null && initialPayload is Function) {
      _payloadTimer = Timer.periodic(check, (_) => _recheckPayload());
    }
  }

  void _stopTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _payloadTimer?.cancel();
    _payloadTimer = null;
  }

  void _heartbeat(Duration ping) {
    if (!_connected || _isDisposed) return;
    if (DateTime.now().difference(_lastMessageAt) > ping + pongTimeout) {
      // Half-open socket: nothing (not even a pong) came back. Replace it.
      _dropConnection().whenComplete(
        () => _onError(
          TimeoutException('WebSocket heartbeat timed out', ping + pongTimeout),
        ),
      );
      return;
    }
    try {
      _channel?.sink.add(jsonEncode({'type': 'ping'}));
    } catch (_) {}
  }

  /// Replaces the socket when the token behind its `connection_init` has
  /// changed or is about to be rejected — see [payloadCheckInterval].
  Future<void> _recheckPayload() async {
    if (_rechecking || !_connected || _activeSubscriptions.isEmpty) return;
    _rechecking = true;
    try {
      if (await _needsFreshSocket() && !_isDisposed) {
        await _dropConnection();
        await _connect();
      }
    } on RevokeTokenException catch (e) {
      _failAll(e);
      await _dropConnection();
    } catch (_) {
      // A transient failure resolving the payload: try again next tick.
    } finally {
      _rechecking = false;
    }
  }

  void _scheduleReconnect([Object? cause]) {
    if (_isDisposed || _reconnectTimer?.isActive == true) return;
    if (_activeSubscriptions.isEmpty) {
      _report(SubscriptionConnectionStatus.disconnected);
      return;
    }
    if (!autoReconnect) {
      _report(SubscriptionConnectionStatus.error, cause);
      return;
    }
    _report(SubscriptionConnectionStatus.reconnecting, cause);
    _reconnectTimer = Timer(_reconnectDelay(), _reconnect);
    _reconnectAttempt++;
  }

  void _scheduleIdleClose() {
    _idleTimer?.cancel();
    final delay = idleCloseDelay;
    if (delay == null || _isDisposed || _activeSubscriptions.isNotEmpty) return;
    _idleTimer = Timer(delay, () async {
      if (_activeSubscriptions.isEmpty &&
          !_isDisposed &&
          _connectFuture == null) {
        _reconnectTimer?.cancel();
        await _dropConnection();
        if (!_isDisposed) _report(SubscriptionConnectionStatus.disconnected);
      }
    });
  }

  /// Resends `subscribe` for every subscription still in [_activeRequests]
  /// on the new socket after a reconnect, so subscribers that survived the
  /// drop resume delivery instead of hanging forever — the server has no
  /// memory of a `subscribe` sent on the previous, now-dead socket.
  void _resendActiveSubscriptions() {
    for (final entry in _activeRequests.entries) {
      _sendSubscribeMessage(entry.key, entry.value);
    }
  }

  void _onMessage(dynamic event) {
    _lastMessageAt = DateTime.now();
    try {
      final message = jsonDecode(event as String) as Map<String, dynamic>;
      final type = message['type'] as String?;
      final id = message['id'] as String?;

      if (type == 'ping') {
        _channel?.sink.add(jsonEncode({'type': 'pong'}));
        return;
      }
      if (type == 'pong' || type == 'ka') return;

      if (type == 'connection_error') {
        // Legacy servers reject a bad `connection_init` this way (the
        // counterpart of the 4401 close): surface it as unauthorized so
        // AuthLink refreshes the token and re-subscribes.
        _failAll(
          ServerException(
            statusCode: 401,
            originalException: message['payload'] ?? 'connection_error',
          ),
        );
        return;
      }

      if (type == 'connection_ack') {
        _reconnectAttempt = 0;
        _report(SubscriptionConnectionStatus.connected);
        _ack?.complete(true);
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
          } else if (payload is Map<String, dynamic> &&
              payload.containsKey('message')) {
            // Legacy servers send a single error object, not a list.
            controller.add(
              Response(errors: [parser.parseError(payload)], response: message),
            );
          } else {
            controller.addError(ServerException(originalException: payload));
          }
          // An `error` message terminates the operation — the server sends
          // no `complete` after it — so it must not stay registered, or a
          // reconnect would resubscribe an operation the server already ended.
          _finishOperation(id, controller);
        } else if (type == 'complete') {
          _finishOperation(id, controller);
        }
      }
    } catch (_) {
      // Ignore malformed payloads
    }
  }

  void _finishOperation(String id, StreamController<Response> controller) {
    controller.close();
    _activeSubscriptions.remove(id);
    _activeRequests.remove(id);
    _sentIds.remove(id);
    _scheduleIdleClose();
  }

  void _onError(dynamic error) {
    _connected = false;
    if (_ack?.isCompleted == false) _ack!.complete(false);
    for (final controller in _activeSubscriptions.values) {
      if (!controller.isClosed) {
        controller.addError(ServerException(originalException: error));
      }
    }
    _stopTimers();
    _scheduleReconnect(error);
  }

  void _onDone() {
    final closeCode = _channel?.closeCode;
    final closeReason = _channel?.closeReason;
    _connected = false;
    _stopTimers();
    if (_ack?.isCompleted == false) _ack!.complete(false);
    _channel = null;
    if (_fatalCloseCodes.contains(closeCode)) {
      _failAll(
        ServerException(
          originalException:
              'WebSocket closed with code $closeCode '
                      '${closeReason ?? ''}'
                  .trim(),
        ),
      );
      return;
    }
    if (_unauthorizedCloseCodes.contains(closeCode)) {
      _failAll(
        ServerException(
          statusCode: 401,
          originalException: 'WebSocket closed with code $closeCode',
        ),
      );
      return;
    }
    _scheduleReconnect(
      'WebSocket closed${closeCode != null ? ' with code $closeCode' : ''}',
    );
  }

  void _reconnect() {
    if (_isDisposed) return;
    _connect();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) {
    final subId = '${req.operation.operationName ?? 'sub'}_${++_nextId}';
    final controller = StreamController<Response>();
    _idleTimer?.cancel();

    _activeSubscriptions[subId] = controller;
    _activeRequests[subId] = req;
    _sendSubscribe(subId, req);

    controller.onCancel = () {
      _sendComplete(subId);
      _sentIds.remove(subId);
      _activeSubscriptions.remove(subId);
      _activeRequests.remove(subId);
      controller.close();
      _scheduleIdleClose();
    };

    return controller.stream;
  }

  Future<void> _sendSubscribe(String id, Request req) async {
    try {
      if (_connected && await _needsFreshSocket()) await _dropConnection();
      await _connect();
    } on RevokeTokenException catch (e) {
      _failAll(e);
      return;
    }
    _sendSubscribeMessage(id, req);
  }

  /// Whether the live socket should be replaced before another subscribe:
  /// its token changed (a refresh happened) or it outlived [maxConnectionAge].
  Future<bool> _needsFreshSocket() async {
    final age = maxConnectionAge;
    if (age != null &&
        DateTime.now().difference(_connectedAt ?? DateTime.now()) > age) {
      return true;
    }
    return initialPayload is Function &&
        jsonEncode(await _resolvePayload()) != jsonEncode(_connectedPayload);
  }

  void _sendSubscribeMessage(String id, Request req) {
    if (!_connected || _channel == null || !_sentIds.add(id)) return;
    final docString = printDocumentCached(req.operation.document);
    _channel!.sink.add(
      jsonEncode({
        'id': id,
        'type': _isLegacyProtocol ? 'start' : 'subscribe',
        'payload': {
          'query': docString,
          if (req.operation.operationName != null)
            'operationName': req.operation.operationName,
          if (req.variables.isNotEmpty) 'variables': req.variables,
        },
      }),
    );
  }

  void _sendComplete(String id) {
    try {
      _channel?.sink.add(
        jsonEncode({'id': id, 'type': _isLegacyProtocol ? 'stop' : 'complete'}),
      );
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _idleTimer?.cancel();
    final controllers = _activeSubscriptions.values.toList();
    _activeSubscriptions.clear();
    _activeRequests.clear();
    for (final controller in controllers) {
      await controller.close();
    }
    await _dropConnection();
    _report(SubscriptionConnectionStatus.disconnected);
    await connectionStatus.close();
  }
}
