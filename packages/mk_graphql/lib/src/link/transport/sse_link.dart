import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:meta/meta.dart';
import 'dio_link.dart';
import '../auth/auth_link.dart';
import 'package:token_storage/token_storage.dart';
import '../../core/backoff.dart';
import '../../core/document_print_cache.dart';

/// Terminating [Link] for GraphQL over Server-Sent Events (SSE).
///
/// Implements the GraphQL over Server-Sent Events Protocol, consuming
/// `text/event-stream` responses from GraphQL servers via HTTP streaming.
///
/// Unauthorized responses (401/403) are surfaced as a [ServerException] —
/// same as [DioLink] — rather than retried here: wrap this link with
/// [AuthLink] (as `GraphQLClient`'s own pipeline does for `sseUrl`) to get
/// refresh-and-retry, deduped against every other in-flight request through
/// [AuthLink]'s single-flight refresh lock. This link has no refresh logic
/// of its own on purpose — two independent, non-deduped refresh attempts
/// racing each other was the bug.
class SseLink extends Link {
  final String url;
  final dio.Dio client;
  final Map<String, String> defaultHeaders;

  /// Callback that supplies the current auth headers, merged into every
  /// request. Optional — [AuthLink] (when this link is used through
  /// `GraphQLClient`) already attaches the current token via the request
  /// context; this is for standalone use of [SseLink] without an [AuthLink]
  /// in front of it.
  final TokenHeaderCallback? tokenHeader;
  final bool useGetForQueries;
  final ResponseParser parser;

  /// Whether a *subscription* stream that drops (network error, 5xx, or the
  /// connection closing without a `complete` event) is re-opened with
  /// backoff, sending `Last-Event-ID` when the server supplied event ids.
  /// 4xx responses are never retried here — a 401 is surfaced for [AuthLink]
  /// to refresh and re-subscribe, and a 403/400 won't be fixed by retrying.
  final bool autoReconnect;

  /// Backoff for [autoReconnect]: first delay, growth factor and ceiling.
  final Duration reconnectInterval;
  final Duration maxReconnectInterval;
  final double reconnectBackoffMultiplier;

  /// Consecutive failed reconnects after which the error is surfaced instead
  /// of retried again. `null` retries indefinitely. Reset whenever the stream
  /// delivers an event.
  final int? maxReconnectAttempts;

  /// If nothing at all (events or `:` keep-alive comments) arrives for this
  /// long, the connection is considered dead and torn down — then reconnected
  /// per [autoReconnect]. `null` (default) waits forever; set it above your
  /// server's heartbeat interval.
  final Duration? idleTimeout;

  /// Whether [client] was created by this [SseLink] itself (no `client:`
  /// argument was supplied) — if so, [dispose] closes it; a caller-supplied
  /// client stays theirs to close.
  final bool _ownsClient;

  SseLink(
    this.url, {
    dio.Dio? client,
    this.defaultHeaders = const {},
    this.tokenHeader,
    this.useGetForQueries = false,
    this.parser = const ResponseParser(),
    this.autoReconnect = true,
    this.reconnectInterval = const Duration(seconds: 3),
    this.maxReconnectInterval = const Duration(seconds: 30),
    this.reconnectBackoffMultiplier = 1.5,
    this.maxReconnectAttempts,
    this.idleTimeout,
  }) : client = client ?? dio.Dio(),
       _ownsClient = client == null;

  /// Closes [client] only if this [SseLink] created it itself.
  @override
  Future<void> dispose() async {
    if (_ownsClient) client.close();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) {
    // A plain `async*` generator can't be cancelled while it is awaiting the
    // next network read — `cancel()` only takes effect at its next `yield`,
    // so a quiet subscription would hold its HTTP connection open
    // indefinitely after the subscriber left. The controller below aborts
    // the connection directly on cancel instead.
    final token = dio.CancelToken();
    final callerToken = req.context
        .entry<DioLinkCancelTokenContextEntry>()
        ?.token;
    callerToken?.whenCancel.then((e) {
      if (!token.isCancelled) token.cancel(e.error);
    });

    late final StreamController<Response> controller;
    StreamSubscription<Response>? running;
    controller = StreamController<Response>(
      onListen: () {
        running = _run(req, token).listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => running?.pause(),
      onResume: () => running?.resume(),
      onCancel: () {
        if (!token.isCancelled) token.cancel('Subscription cancelled');
        final sub = running;
        if (sub != null) unawaited(sub.cancel().catchError((_) {}));
      },
    );
    return controller.stream;
  }

  Stream<Response> _run(Request req, dio.CancelToken token) async* {
    final isSubscription = req.operation.document.definitions
        .whereType<OperationDefinitionNode>()
        .any((def) => def.type == OperationType.subscription);
    final state = _SseState();
    var attempt = 0;

    while (true) {
      Object? failure;
      StackTrace? failureStack;
      try {
        await for (final response in _connect(req, state, token)) {
          attempt = 0;
          yield response;
        }
        if (state.completed || !isSubscription || !autoReconnect) return;
        // Ended without the mandatory `complete` event: dropped mid-stream.
      } on LinkException catch (e, st) {
        if (!isSubscription || !autoReconnect || !isRetryableLinkError(e)) {
          rethrow;
        }
        failure = e;
        failureStack = st;
      }

      if (state.receivedData) attempt = 0;
      final max = maxReconnectAttempts;
      if (max != null && attempt >= max) {
        throw failure ??
            ServerException(
              originalException: 'SSE stream closed without completing',
              originalStackTrace: failureStack,
            );
      }
      await Future.any<void>([
        Future<void>.delayed(
          cappedBackoffDelay(
            attempt: attempt,
            initialDelay: reconnectInterval,
            maxDelay: maxReconnectInterval,
            multiplier: reconnectBackoffMultiplier,
          ),
        ),
        token.whenCancel,
      ]);
      if (token.isCancelled) return;
      attempt++;
      state.receivedData = false;
    }
  }

  /// One connection attempt: opens the stream and yields its events. The
  /// underlying request is always cancelled when this generator ends — normal
  /// completion, error, or the subscriber cancelling — so no socket is left
  /// open behind a stream nobody listens to.
  Stream<Response> _connect(
    Request req,
    _SseState state,
    dio.CancelToken subscriptionToken,
  ) async* {
    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    // Per connection, so ending one attempt doesn't cancel the next.
    final cancelToken = dio.CancelToken();
    subscriptionToken.whenCancel.then((e) {
      if (!cancelToken.isCancelled) cancelToken.cancel(e.error);
    });

    Map<String, String> authHeaders = const {};
    if (tokenHeader != null) {
      final token = await TokenStorage.i.accessToken;
      if (token != null) authHeaders = await tokenHeader!(token);
    }

    final reconnecting = state.attempts++ > 0;
    final headers = <String, String>{
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...defaultHeaders,
      // A reconnect must not reuse the context's token from when the
      // subscription started — it may have been refreshed or expired since.
      if (!reconnecting) ...authHeaders,
      ...contextHeaders,
      if (reconnecting) ...authHeaders,
      if (state.lastEventId != null) 'Last-Event-ID': state.lastEventId!,
    };

    final queryString = printDocumentCached(req.operation.document);
    final operationName = req.operation.operationName;
    final variables = req.variables;

    final isQuery = req.operation.document.definitions
        .whereType<OperationDefinitionNode>()
        .any((def) => def.type == OperationType.query);

    dio.Response<dio.ResponseBody> dioResponse;
    try {
      if (useGetForQueries && isQuery) {
        dioResponse = await client.get<dio.ResponseBody>(
          url,
          queryParameters: {
            'query': queryString,
            if (operationName != null) 'operationName': operationName,
            if (variables.isNotEmpty) 'variables': jsonEncode(variables),
          },
          options: dio.Options(
            responseType: dio.ResponseType.stream,
            headers: headers,
          ),
          cancelToken: cancelToken,
        );
      } else {
        dioResponse = await client.post<dio.ResponseBody>(
          url,
          data: {
            'query': queryString,
            if (operationName != null) 'operationName': operationName,
            if (variables.isNotEmpty) 'variables': variables,
          },
          options: dio.Options(
            responseType: dio.ResponseType.stream,
            headers: {...headers, 'Content-Type': 'application/json'},
          ),
          cancelToken: cancelToken,
        );
      }
    } on dio.DioException catch (e, st) {
      throw await _classify(e, st);
    } catch (e, st) {
      throw ServerException(originalException: e, originalStackTrace: st);
    }

    final statusCode = dioResponse.statusCode ?? 200;
    if (statusCode >= 300) {
      cancelToken.cancel('SSE request rejected');
      throw ServerException(
        statusCode: statusCode,
        originalException: dioResponse.statusMessage,
      );
    }

    final body = dioResponse.data?.stream;
    if (body == null) {
      state.completed = true;
      return;
    }

    var lines = body
        .cast<List<int>>()
        .map((chunk) {
          state.receivedData = true; // any bytes, keep-alives included
          return chunk;
        })
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

    // Closes the line stream the moment the connection is cancelled, so the
    // loop below wakes up instead of waiting on a read that never comes.
    final woken = StreamController<String>();
    final reading = lines.listen(
      woken.add,
      onError: woken.addError,
      onDone: woken.close,
    );
    cancelToken.whenCancel.then((_) {
      reading.cancel();
      if (!woken.isClosed) woken.close();
    });

    String currentEvent = 'next';
    final dataBuffer = StringBuffer();

    try {
      await for (final line in woken.stream) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          final eventType = currentEvent;
          currentEvent = 'next';
          if (eventType == 'complete') {
            state.completed = true;
            return;
          }
          if (dataBuffer.isNotEmpty) {
            final rawData = dataBuffer.toString().trim();
            dataBuffer.clear();
            final parsed = _parseEventData(rawData, eventType);
            if (parsed != null) yield parsed;
          }
        } else if (trimmed.startsWith(':')) {
          // Comment / keepalive line
          continue;
        } else if (trimmed.startsWith('event:')) {
          currentEvent = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('id:')) {
          final id = trimmed.substring(3).trim();
          if (id.isNotEmpty) state.lastEventId = id;
        } else if (trimmed.startsWith('data:')) {
          dataBuffer.writeln(trimmed.substring(5).trim());
        }
      }

      if (currentEvent == 'complete') {
        state.completed = true;
      } else if (dataBuffer.isNotEmpty) {
        final parsed = _parseEventData(
          dataBuffer.toString().trim(),
          currentEvent,
        );
        if (parsed != null) yield parsed;
      }
    } on dio.DioException catch (e, st) {
      throw classifyDioException(e, st);
    } finally {
      // Closes the HTTP connection whichever way we got here (complete,
      // error, or the subscriber cancelling mid-stream).
      if (!cancelToken.isCancelled) cancelToken.cancel('SSE stream closed');
      unawaited(reading.cancel().catchError((_) {}));
    }
  }

  Future<LinkException> _classify(dio.DioException e, StackTrace st) =>
      classifyRejectedRequest(e, st, parser);

  Response? _parseEventData(String rawData, String eventType) {
    if (rawData.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final Map<String, dynamic> payload =
          decoded.containsKey('payload') &&
              decoded['payload'] is Map<String, dynamic>
          ? decoded['payload'] as Map<String, dynamic>
          : decoded;

      return parser.parseResponse(payload);
    } catch (e, st) {
      throw ServerException(originalException: e, originalStackTrace: st);
    }
  }
}

/// Per-subscription state that survives reconnects.
class _SseState {
  /// Connection attempts made so far (the first is `0` before incrementing).
  int attempts = 0;

  /// Last `id:` the server sent, replayed as `Last-Event-ID` on reconnect.
  String? lastEventId;

  /// The server sent the `complete` event — the stream ended on purpose.
  bool completed = false;

  /// Bytes arrived on the current connection (so the attempt counter resets).
  bool receivedData = false;
}

/// Whether a failed streaming connection is worth re-opening: a dropped
/// connection, a timeout or a 5xx/408/429 is; a cancellation, a certificate
/// failure, an unparseable body or any other 4xx is not (a 401 is surfaced
/// for [AuthLink] to refresh and re-subscribe).
@internal
bool isRetryableLinkError(LinkException e) {
  if (e is DioLinkCanceledException ||
      e is DioLinkCertificateException ||
      e is DioLinkParserException) {
    return false;
  }
  if (e is ServerException) {
    final status = e.statusCode;
    return status == null || status >= 500 || status == 408 || status == 429;
  }
  return true;
}

/// [classifyDioException], but for a rejected request also reads the
/// (streamed) error body: `graphql-sse` answers a bad or unauthenticated
/// operation with a normal GraphQL JSON `{ "errors": [...] }` body and a
/// 4xx status, and without parsing it the real message — and the error
/// `code` that [AuthLink] classifies on — would be lost.
@internal
Future<LinkException> classifyRejectedRequest(
  dio.DioException e,
  StackTrace st,
  ResponseParser parser,
) async {
  final classified = classifyDioException(e, st);
  final body = e.response?.data;
  if (classified is! DioLinkServerException || body is! dio.ResponseBody) {
    return classified;
  }
  try {
    final bytes = <int>[];
    await body.stream.forEach(bytes.addAll).timeout(const Duration(seconds: 5));
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic> &&
        (decoded.containsKey('errors') || decoded.containsKey('data'))) {
      return DioLinkServerException(
        response: classified.response,
        parsedResponse: parser.parseResponse(decoded),
        statusCode: classified.statusCode,
        originalException: e,
        originalStackTrace: st,
      );
    }
  } catch (_) {
    // Not a GraphQL JSON body: keep the plain status-based exception.
  }
  return classified;
}
