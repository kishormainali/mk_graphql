import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart' as dio;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import '../../core/document_print_cache.dart';

class _BatchItem {
  final Request request;
  final Completer<Map<String, dynamic>> completer;
  _BatchItem(this.request, this.completer);
}

/// Terminating [Link] that batches multiple concurrent GraphQL HTTP POST
/// queries into a single HTTP array payload, via [dio.Dio].
class BatchLink extends Link {
  final Uri uri;
  final dio.Dio _client;
  final Map<String, String> defaultHeaders;
  final Duration batchTimeout;
  final int maxBatchSize;

  final _queue = <_BatchItem>[];
  Timer? _timer;

  /// Whether [_client] was created by this [BatchLink] itself (no `client:`
  /// argument was supplied) — if so, [dispose] closes it; a caller-supplied
  /// client stays theirs to close.
  final bool _ownsClient;

  BatchLink(
    String url, {
    dio.Dio? client,
    this.defaultHeaders = const {},
    this.batchTimeout = const Duration(milliseconds: 10),
    this.maxBatchSize = 10,
  }) : uri = Uri.parse(url),
       _client = client ?? dio.Dio(),
       _ownsClient = client == null;

  /// Cancels any pending batch timer, fails queued-but-undispatched requests
  /// so their `future`/`stream` callers don't hang forever, and closes the
  /// underlying [dio.Dio] client only if this [BatchLink] created it itself.
  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    for (final item in _queue) {
      item.completer.completeError(
        const ServerException(
          originalException:
              'BatchLink was disposed before this request '
              'could be dispatched.',
        ),
      );
    }
    _queue.clear();
    if (_ownsClient) _client.close();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    final completer = Completer<Map<String, dynamic>>();
    _queue.add(_BatchItem(req, completer));

    if (_queue.length >= maxBatchSize) {
      _dispatchBatch();
    } else {
      _timer ??= Timer(batchTimeout, _dispatchBatch);
    }

    try {
      final bodyJson = await completer.future;
      // The same ResponseParser as every other terminating link, so
      // errors[].extensions.code survives parsing — AuthLink's unauthorized
      // detection and GraphQLExceptionExtension both key off it.
      yield const ResponseParser().parseResponse(bodyJson);
    } catch (e, stack) {
      throw ServerException(originalException: e, originalStackTrace: stack);
    }
  }

  void _dispatchBatch() async {
    _timer?.cancel();
    _timer = null;
    if (_queue.isEmpty) return;

    final batch = List<_BatchItem>.from(_queue);
    _queue.clear();

    final payload = batch.map((item) {
      return {
        'query': printDocumentCached(item.request.operation.document),
        'operationName': item.request.operation.operationName,
        'variables': item.request.variables,
      };
    }).toList();

    try {
      final response = await _client.post<String>(
        uri.toString(),
        data: jsonEncode(payload),
        options: dio.Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            ...defaultHeaders,
          },
          responseType: dio.ResponseType.plain,
          // Never let Dio throw for a non-2xx status — handled explicitly
          // below so every queued item completes with a proper
          // ServerException instead of the send itself throwing.
          validateStatus: (_) => true,
        ),
      );

      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 400) {
        final ex = ServerException(statusCode: statusCode);
        for (final item in batch) {
          item.completer.completeError(ex);
        }
        return;
      }

      final List<dynamic> listJson =
          jsonDecode(response.data ?? '') as List<dynamic>;
      for (int i = 0; i < batch.length; i++) {
        if (i < listJson.length) {
          batch[i].completer.complete(listJson[i] as Map<String, dynamic>);
        } else {
          batch[i].completer.completeError(const ServerException());
        }
      }
    } catch (e, stack) {
      final ex = ServerException(
        originalException: e,
        originalStackTrace: stack,
      );
      for (final item in batch) {
        item.completer.completeError(ex);
      }
    }
  }
}
