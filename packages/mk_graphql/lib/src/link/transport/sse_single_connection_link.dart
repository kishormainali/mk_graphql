import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:token_storage/token_storage.dart';

import '../../core/backoff.dart';
import '../../core/connection_status.dart';
import '../../core/document_print_cache.dart';
import '../auth/auth_types.dart';
import 'dio_link.dart' show DioLinkCancelTokenContextEntry;
import 'sse_link.dart';

/// Terminating [Link] for GraphQL over Server-Sent Events in
/// [single connection mode](https://github.com/enisdenjo/graphql-sse/blob/master/PROTOCOL.md#single-connection-mode)
/// (`graphql-sse`).
///
/// Unlike [SseLink] (distinct connections mode: one HTTP connection per
/// operation), every operation here shares **one** event stream:
///
/// 1. `PUT` reserves a stream and returns a token;
/// 2. a `GET` with the token opens the `text/event-stream`;
/// 3. each operation is a `POST` carrying the token and an
///    `extensions.operationId`; the server answers `202` and delivers
///    `next`/`complete` events on the shared stream;
/// 4. cancelling an operation sends `DELETE ?operationId=…`.
///
/// This is the mode to use over HTTP/1.1, where browsers (and some proxies)
/// cap concurrent connections per host and many simultaneous subscriptions
/// would otherwise starve ordinary requests.
///
/// The stream is opened lazily by the first operation and closed
/// [idleCloseDelay] after the last one ends. If it drops, it is re-reserved
/// with backoff and every live operation is re-sent. 401/403 responses are
/// surfaced as a [ServerException] — wrap with [AuthLink] (as
/// `GraphQLClient`'s pipeline does) to refresh the token and re-subscribe.
class SseSingleConnectionLink extends Link implements ConnectionStatusSource {
  final String url;
  final dio.Dio client;
  final Map<String, String> defaultHeaders;

  /// Supplies the current auth headers for the stream, its reservation and
  /// cancellation requests, and for operation re-sends after a reconnect —
  /// always re-read from storage so a token refreshed mid-session is used.
  final TokenHeaderCallback? tokenHeader;
  final ResponseParser parser;

  /// Whether a dropped stream is re-reserved and its live operations
  /// re-sent. 4xx responses are never retried (see [SseLink.autoReconnect]).
  final bool autoReconnect;

  /// Backoff for [autoReconnect]: first delay, growth factor and ceiling.
  final Duration reconnectInterval;
  final Duration maxReconnectInterval;
  final double reconnectBackoffMultiplier;

  /// Consecutive failed reconnects after which every live operation fails
  /// with the last error. `null` retries indefinitely.
  final int? maxReconnectAttempts;

  /// Tears the stream down (and reconnects) if nothing, keep-alive comments
  /// included, arrives for this long. `null` waits forever; set it above the
  /// server's keep-alive interval.
  final Duration? idleTimeout;

  /// How long the stream stays open after the last operation ends, so a
  /// screen that unsubscribes and re-subscribes reuses it. `null` keeps it
  /// open until [dispose].
  final Duration? idleCloseDelay;

  final bool _ownsClient;

  /// Current connection status — see [SubscriptionConnectionStatus].
  @override
  final ConnectionStatusNotifier connectionStatus = ConnectionStatusNotifier();

  /// Reports to the link-wide status and mirrors it to every live
  /// operation's own notifier (they share this one stream).
  void _report(SubscriptionConnectionStatus status, [Object? error]) {
    connectionStatus.report(this, status, error: error);
    for (final op in _ops.values) {
      op.request.subscriptionStatus?.report(op.id, status, error: error);
    }
  }

  SseSingleConnectionLink(
    this.url, {
    dio.Dio? client,
    this.defaultHeaders = const {},
    this.tokenHeader,
    this.parser = const ResponseParser(),
    this.autoReconnect = true,
    this.reconnectInterval = const Duration(seconds: 3),
    this.maxReconnectInterval = const Duration(seconds: 30),
    this.reconnectBackoffMultiplier = 1.5,
    this.maxReconnectAttempts,
    this.idleTimeout,
    this.idleCloseDelay = const Duration(seconds: 5),
  }) : client = client ?? dio.Dio(),
       _ownsClient = client == null;

  static const _tokenHeaderName = 'X-GraphQL-Event-Stream-Token';

  final _ops = <String, _Operation>{};
  int _nextId = 0;
  final String _idPrefix = DateTime.now().microsecondsSinceEpoch.toString();

  bool _isDisposed = false;
  bool _running = false;

  /// Reservation token of the stream currently open (or being opened).
  String? _token;

  /// True once the event stream has answered, i.e. operations may be POSTed.
  bool _streamOpen = false;

  /// Cancels the current stream's HTTP request(s).
  dio.CancelToken? _streamCancel;
  Timer? _idleTimer;

  @override
  Stream<Response> request(Request req, [NextLink? forward]) {
    late final _Operation op;
    final controller = StreamController<Response>(
      onListen: () {
        if (_isDisposed) {
          op.controller
            ..addError(StateError('SseSingleConnectionLink is disposed'))
            ..close();
          return;
        }
        _idleTimer?.cancel();
        _ops[op.id] = op;
        final current = connectionStatus.value;
        req.subscriptionStatus?.report(
          op.id,
          current.status == SubscriptionConnectionStatus.connected ||
                  current.status == SubscriptionConnectionStatus.reconnecting
              ? current.status
              : SubscriptionConnectionStatus.connecting,
          error: current.lastError,
        );
        _ensureRunning();
        _flush();
      },
      onCancel: () => _cancelOperation(op),
    );
    op = _Operation('${_idPrefix}_${++_nextId}', req, controller);
    // Lets a caller stop a subscription that is waiting on a quiet stream,
    // through links in between that can't forward a cancel in time.
    req.context.entry<DioLinkCancelTokenContextEntry>()?.token?.whenCancel.then(
      (_) {
        _cancelOperation(op);
        if (!controller.isClosed) unawaited(controller.close());
      },
    );
    return controller.stream;
  }

  // ---------------------------------------------------------------------------
  // Stream lifecycle
  // ---------------------------------------------------------------------------

  void _ensureRunning() {
    if (_running || _isDisposed) return;
    _running = true;
    unawaited(_loop());
  }

  /// Keeps one stream open while any operation is live: reserve, open, send
  /// the operations, pump events — and on a drop, back off and start over.
  Future<void> _loop() async {
    var attempt = 0;
    try {
      while (!_isDisposed && _ops.isNotEmpty) {
        final cancel = _streamCancel = dio.CancelToken();
        // Everything the new stream must carry again: the server has no
        // memory of operations sent on the previous one.
        for (final op in _ops.values) {
          op.posted = false;
        }
        LinkException? failure;
        var gotData = false;
        if (attempt == 0) _report(SubscriptionConnectionStatus.connecting);
        try {
          final lines = await _openStream(cancel);
          _streamOpen = true;
          _report(SubscriptionConnectionStatus.connected);
          _flush();
          await _pump(lines, cancel, onData: () => gotData = true);
          // Ended: the server closed it, it was idle-closed, or it dropped.
        } catch (e, st) {
          failure = await _asLinkException(e, st);
        } finally {
          _streamOpen = false;
          _token = null;
          if (!cancel.isCancelled) cancel.cancel('SSE stream closed');
        }

        if (_isDisposed || _ops.isEmpty) break;
        if (failure != null &&
            (!autoReconnect || !isRetryableLinkError(failure))) {
          _failAll(failure);
          break;
        }
        if (!autoReconnect) {
          _failAll(
            ServerException(originalException: 'SSE stream closed by server'),
          );
          break;
        }
        if (gotData) attempt = 0;
        final max = maxReconnectAttempts;
        if (max != null && attempt >= max) {
          _failAll(
            failure ??
                ServerException(
                  originalException: 'SSE stream closed without completing',
                ),
          );
          break;
        }
        _report(
          SubscriptionConnectionStatus.reconnecting,
          failure ?? 'SSE stream closed',
        );
        await Future<void>.delayed(
          cappedBackoffDelay(
            attempt: attempt,
            initialDelay: reconnectInterval,
            maxDelay: maxReconnectInterval,
            multiplier: reconnectBackoffMultiplier,
          ),
        );
        attempt++;
      }
    } finally {
      _running = false;
      _token = null;
      _streamOpen = false;
      if ((_isDisposed || _ops.isEmpty) &&
          connectionStatus.value.status != SubscriptionConnectionStatus.error) {
        _report(SubscriptionConnectionStatus.disconnected);
      }
      // An operation added while the loop was winding down still needs one.
      if (!_isDisposed && _ops.isNotEmpty) _ensureRunning();
    }
  }

  Future<LinkException> _asLinkException(Object e, StackTrace st) async {
    if (e is dio.DioException) return classifyRejectedRequest(e, st, parser);
    if (e is LinkException) return e;
    return ServerException(originalException: e, originalStackTrace: st);
  }

  /// Reserves a stream (`PUT` → token) and opens it (`GET` + token),
  /// returning its decoded lines once the server has answered.
  Future<Stream<String>> _openStream(dio.CancelToken cancel) async {
    final auth = await _freshAuthHeaders();
    final base = <String, String>{...defaultHeaders, ...auth};

    final reservation = await client.put<String>(
      url,
      options: dio.Options(headers: base, responseType: dio.ResponseType.plain),
      cancelToken: cancel,
    );
    final token = reservation.data?.trim();
    if (token == null || token.isEmpty) {
      throw ServerException(
        statusCode: reservation.statusCode,
        originalException: 'graphql-sse stream reservation returned no token',
      );
    }
    _token = token;

    final response = await client.get<dio.ResponseBody>(
      url,
      options: dio.Options(
        responseType: dio.ResponseType.stream,
        headers: {
          ...base,
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          _tokenHeaderName: token,
        },
      ),
      cancelToken: cancel,
    );
    final body = response.data?.stream;
    if (body == null) {
      throw ServerException(originalException: 'SSE stream has no body');
    }

    var lines = body
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final idle = idleTimeout;
    if (idle != null) {
      lines = lines.timeout(
        idle,
        onTimeout: (sink) => sink
          ..addError(
            ServerException(
              originalException: TimeoutException(
                'No SSE data or keep-alive for $idle',
                idle,
              ),
            ),
          )
          ..close(),
      );
    }
    return lines;
  }

  /// Reads the shared stream, routing each event to its operation. Returns
  /// when the stream ends — including the moment [cancel] fires, even while
  /// no data is arriving.
  Future<void> _pump(
    Stream<String> lines,
    dio.CancelToken cancel, {
    required void Function() onData,
  }) async {
    final woken = StreamController<String>();
    final reading = lines.listen(
      (line) {
        onData();
        woken.add(line);
      },
      onError: woken.addError,
      onDone: woken.close,
    );
    unawaited(
      cancel.whenCancel.then((_) {
        reading.cancel();
        if (!woken.isClosed) woken.close();
      }),
    );

    var event = 'message';
    final data = StringBuffer();
    try {
      await for (final line in woken.stream) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          final type = event;
          event = 'message';
          if (data.isNotEmpty) {
            final raw = data.toString().trim();
            data.clear();
            _dispatch(type, raw);
          }
        } else if (trimmed.startsWith(':')) {
          continue; // keep-alive comment
        } else if (trimmed.startsWith('event:')) {
          event = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('data:')) {
          data.writeln(trimmed.substring(5).trim());
        }
      }
    } finally {
      unawaited(reading.cancel().catchError((_) {}));
    }
  }

  void _dispatch(String type, String raw) {
    if (type != 'next' && type != 'complete') return;
    try {
      final message = jsonDecode(raw);
      if (message is! Map<String, dynamic>) return;
      final op = _ops[message['id']];
      if (op == null) return; // cancelled meanwhile, or not ours
      if (type == 'next') {
        final payload = message['payload'];
        if (payload is Map<String, dynamic>) {
          op.controller.add(parser.parseResponse(payload));
        }
      } else {
        _finish(op);
      }
    } catch (e, st) {
      final id = RegExp(r'"id"\s*:\s*"([^"]*)"').firstMatch(raw)?.group(1);
      final op = id == null ? null : _ops[id];
      if (op != null) {
        op.controller.addError(
          ServerException(originalException: e, originalStackTrace: st),
        );
        _finish(op);
      }
    }
  }

  /// Ends [op] normally (server `complete`) or after a terminal error.
  void _finish(_Operation op) {
    if (_ops.remove(op.id) == null) return;
    op.request.subscriptionStatus?.report(
      op.id,
      SubscriptionConnectionStatus.disconnected,
    );
    op.cancel.cancel('finished');
    op.controller.close();
    _scheduleIdleClose();
  }

  void _failAll(LinkException error) {
    _report(SubscriptionConnectionStatus.error, error);
    final ops = _ops.values.toList();
    _ops.clear();
    for (final op in ops) {
      op.cancel.cancel('stream failed');
      if (!op.controller.isClosed) {
        op.controller.addError(error);
        op.controller.close();
      }
    }
  }

  void _scheduleIdleClose() {
    _idleTimer?.cancel();
    final delay = idleCloseDelay;
    if (delay == null || _isDisposed || _ops.isNotEmpty) return;
    _idleTimer = Timer(delay, () {
      if (_ops.isEmpty) _streamCancel?.cancel('idle');
    });
  }

  // ---------------------------------------------------------------------------
  // Operations
  // ---------------------------------------------------------------------------

  /// Sends every operation not yet sent on the open stream.
  void _flush() {
    if (!_streamOpen) return;
    for (final op in _ops.values.toList()) {
      if (!op.posted) {
        op.posted = true;
        unawaited(_post(op));
      }
    }
  }

  Future<void> _post(_Operation op) async {
    final token = _token;
    if (token == null) return;
    final req = op.request;
    final context = req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    final auth = await _freshAuthHeaders();
    // First send: the headers AuthLink just attached win (they reflect a
    // refresh it just performed). A re-send after a reconnect prefers fresh
    // storage — the context's token may be hours old by then.
    final resend = op.sentOnce;
    op.sentOnce = true;
    final headers = <String, String>{
      ...defaultHeaders,
      if (!resend) ...auth,
      ...context,
      if (resend) ...auth,
      _tokenHeaderName: token,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    final variables = req.variables;
    final name = req.operation.operationName;
    try {
      await client.post<void>(
        url,
        data: {
          'query': printDocumentCached(req.operation.document),
          if (name != null) 'operationName': name,
          if (variables.isNotEmpty) 'variables': variables,
          'extensions': {'operationId': op.id},
        },
        options: dio.Options(
          headers: headers,
          responseType: dio.ResponseType.plain,
        ),
        cancelToken: op.cancel,
      );
    } catch (e, st) {
      if (!_ops.containsKey(op.id)) return; // cancelled or finished meanwhile
      final error = await _asLinkException(e, st);
      if (error is ServerException && _isStaleStream(error.statusCode)) {
        // The server forgot this reservation (restart, expiry): reopen.
        _streamCancel?.cancel('stale stream');
        return;
      }
      op.controller.addError(error);
      _finish(op);
    }
  }

  /// 404/409/410 on an operation POST: unknown or already-used reservation.
  bool _isStaleStream(int? status) =>
      status == 404 || status == 409 || status == 410;

  void _cancelOperation(_Operation op) {
    if (_ops.remove(op.id) == null) return;
    op.request.subscriptionStatus?.report(
      op.id,
      SubscriptionConnectionStatus.disconnected,
    );
    final wasSent = op.posted;
    op.cancel.cancel('Subscription cancelled');
    if (wasSent && _streamOpen) unawaited(_delete(op));
    _scheduleIdleClose();
  }

  /// Tells the server to stop [op]; best effort — if it fails the server
  /// stops it when the stream closes anyway.
  Future<void> _delete(_Operation op) async {
    final token = _token;
    if (token == null) return;
    try {
      final auth = await _freshAuthHeaders();
      await client.delete<void>(
        url,
        queryParameters: {'operationId': op.id},
        options: dio.Options(
          headers: {...defaultHeaders, ...auth, _tokenHeaderName: token},
          responseType: dio.ResponseType.plain,
        ),
      );
    } catch (_) {}
  }

  Future<Map<String, String>> _freshAuthHeaders() async {
    final callback = tokenHeader;
    if (callback == null) return const {};
    final token = await TokenStorage.i.accessToken;
    return token == null ? const {} : await callback(token);
  }

  /// Closes the stream and every live operation; closes [client] only if
  /// this link created it.
  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _idleTimer?.cancel();
    _streamCancel?.cancel('disposed');
    _report(SubscriptionConnectionStatus.disconnected);
    final ops = _ops.values.toList();
    _ops.clear();
    for (final op in ops) {
      op.cancel.cancel('disposed');
      await op.controller.close();
    }
    if (_ownsClient) client.close();
    await connectionStatus.close();
  }
}

class _Operation {
  _Operation(this.id, this.request, this.controller);

  final String id;
  final Request request;
  final StreamController<Response> controller;
  final cancel = dio.CancelToken();

  /// Sent on the current stream.
  bool posted = false;

  /// Sent at least once on any stream.
  bool sentOnce = false;
}
