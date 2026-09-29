import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:meta/meta.dart';

import '../../core/document_print_cache.dart';
import 'dio_link.dart' show DioLinkCancelTokenContextEntry;

/// Exception thrown when a request is cancelled in [HttpLink] via
/// [DioLinkCancelTokenContextEntry].
@immutable
class HttpLinkCanceledException extends LinkException {
  const HttpLinkCanceledException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Exception thrown when there is no network connectivity, or the
/// connection is refused/reset (DNS failure, socket error, etc) in
/// [HttpLink].
@immutable
class HttpLinkConnectionException extends LinkException {
  const HttpLinkConnectionException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Terminating [Link] for executing HTTP POST GraphQL requests via [dio.Dio]
/// — an intentionally lightweight alternative to [DioLink] (no proactive
/// GET-for-queries, no response-context headers, best-effort cancellation).
///
/// Supports standard JSON bodies and multipart file uploads
/// (GraphQL Multipart Request Spec, via [Upload]/[dio.MultipartFile]).
class HttpLink extends Link {
  final Uri uri;
  final dio.Dio _client;
  final Map<String, String> defaultHeaders;

  /// Whether [_client] was created by this [HttpLink] itself (no `client:`
  /// argument was supplied) — if so, [dispose] closes it; a caller-supplied
  /// client stays theirs to close.
  final bool _ownsClient;

  HttpLink(String url, {dio.Dio? client, this.defaultHeaders = const {}})
    : uri = Uri.parse(url),
      _client = client ?? dio.Dio(),
      _ownsClient = client == null;

  /// Closes the underlying [dio.Dio] client only if this [HttpLink] created
  /// it itself.
  @override
  Future<void> dispose() async {
    if (_ownsClient) _client.close();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    final cancelToken = req.context
        .entry<DioLinkCancelTokenContextEntry>()
        ?.token;

    final variablesMap = req.variables;

    // Check for file uploads (GraphQL Multipart Spec)
    final uploads = <String, dio.MultipartFile>{};
    final cleanedVars = _extractMultipartFiles(variablesMap, '', uploads);

    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};

    final headers = <String, String>{
      'Accept': 'application/json',
      ...defaultHeaders,
      ...contextHeaders,
    };

    dynamic body;
    if (uploads.isNotEmpty) {
      // Multipart request for file uploads
      final operations = jsonEncode({
        'query': printDocumentCached(req.operation.document),
        'operationName': req.operation.operationName,
        'variables': cleanedVars,
      });

      final map = <String, List<String>>{};
      final files = <String, dio.MultipartFile>{};
      var i = 0;
      uploads.forEach((path, file) {
        final key = i.toString();
        map[key] = [path];
        files[key] = file;
        i++;
      });

      body = dio.FormData.fromMap(<String, dynamic>{
        'operations': operations,
        'map': jsonEncode(map),
        ...files,
      });
    } else {
      headers['Content-Type'] = 'application/json';
      body = jsonEncode({
        'query': printDocumentCached(req.operation.document),
        'operationName': req.operation.operationName,
        'variables': cleanedVars,
      });
    }

    dio.Response<String> dioResponse;
    try {
      dioResponse = await _sendCancellable(
        _client.post<String>(
          uri.toString(),
          data: body,
          options: dio.Options(
            headers: headers,
            responseType: dio.ResponseType.plain,
            // Never let Dio throw for a non-2xx status — a GraphQL error
            // payload can ride along a 4xx/5xx just as validly as a 200,
            // so the body is always parsed and classified below instead.
            validateStatus: (_) => true,
          ),
        ),
        cancelToken,
      );
    } on dio.DioException catch (e, stack) {
      if (e.type == dio.DioExceptionType.connectionError) {
        throw HttpLinkConnectionException(
          originalException: e,
          originalStackTrace: stack,
        );
      }
      throw ServerException(originalException: e, originalStackTrace: stack);
    } catch (e, stack) {
      if (e is LinkException) rethrow;
      throw ServerException(originalException: e, originalStackTrace: stack);
    }

    final statusCode = dioResponse.statusCode ?? 0;
    final responseBody = dioResponse.data ?? '';

    if (statusCode >= 400 && responseBody.isEmpty) {
      throw ServerException(statusCode: statusCode);
    }

    late final Map<String, dynamic> bodyJson;
    try {
      bodyJson = jsonDecode(responseBody) as Map<String, dynamic>;
    } catch (e, stack) {
      throw ResponseFormatException(
        originalException: e,
        originalStackTrace: stack,
      );
    }

    // Uses the same ResponseParser as DioLink/SseLink/WebSocketLink so
    // errors[].locations/path/extensions survive parsing here too —
    // AuthLink's unauthorized detection and GraphQLExceptionExtension both
    // rely on extensions.code being present.
    yield const ResponseParser().parseResponse(bodyJson);
  }

  /// Races [future] against [cancelToken]'s cancellation signal.
  ///
  /// [dio.Dio]'s own `cancelToken:` request parameter needs the underlying
  /// [dio.HttpClientAdapter] to cooperate with cancellation to actually abort
  /// anything — not guaranteed across every adapter/platform. This manual
  /// race works regardless: it just stops the caller from waiting on the
  /// response; the underlying request itself keeps running in the
  /// background and its result is discarded.
  Future<T> _sendCancellable<T>(
    Future<T> future,
    dio.CancelToken? cancelToken,
  ) {
    if (cancelToken == null) return future;
    if (cancelToken.isCancelled) {
      throw HttpLinkCanceledException(
        originalException: cancelToken.cancelError,
        originalStackTrace: StackTrace.current,
      );
    }
    return Future.any([
      future,
      cancelToken.whenCancel.then<T>((cancelError) {
        throw HttpLinkCanceledException(
          originalException: cancelError,
          originalStackTrace: StackTrace.current,
        );
      }),
    ]);
  }

  dynamic _extractMultipartFiles(
    dynamic value,
    String path,
    Map<String, dio.MultipartFile> uploads,
  ) {
    if (value is dio.MultipartFile) {
      uploads['variables.$path'] = value;
      return null;
    } else if (value is Map) {
      final newMap = <String, dynamic>{};
      value.forEach((key, val) {
        final currentPath = path.isEmpty ? '$key' : '$path.$key';
        newMap[key as String] = _extractMultipartFiles(
          val,
          currentPath,
          uploads,
        );
      });
      return newMap;
    } else if (value is List) {
      final newList = [];
      for (var i = 0; i < value.length; i++) {
        final currentPath = path.isEmpty ? '$i' : '$path.$i';
        newList.add(_extractMultipartFiles(value[i], currentPath, uploads));
      }
      return newList;
    }
    return value;
  }
}
