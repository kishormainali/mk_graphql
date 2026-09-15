import 'dart:convert';
import 'package:dio/dio.dart' as dio;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:http/http.dart' as http;
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

/// Terminating [Link] for executing HTTP POST GraphQL requests.
///
/// Supports standard JSON bodies and multipart file uploads
/// (GraphQL Multipart Request Spec).
class HttpLink extends Link {
  final Uri uri;
  final http.Client _client;
  final Map<String, String> defaultHeaders;

  /// Whether [_client] was created by this [HttpLink] itself (no `client:`
  /// argument was supplied) — if so, [dispose] closes it; a caller-supplied
  /// client stays theirs to close.
  final bool _ownsClient;

  HttpLink(
    String url, {
    http.Client? client,
    this.defaultHeaders = const {},
  })  : uri = Uri.parse(url),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Closes the underlying HTTP client only if this [HttpLink] created it
  /// itself.
  @override
  Future<void> dispose() async {
    if (_ownsClient) _client.close();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    final cancelToken =
        req.context.entry<DioLinkCancelTokenContextEntry>()?.token;

    http.Response httpResponse;
    try {
      final variablesMap = req.variables;

      // Check for file uploads (GraphQL Multipart Spec)
      final uploads = <String, http.MultipartFile>{};
      final cleanedVars = _extractMultipartFiles(variablesMap, '', uploads);

      final contextHeaders =
          req.context.entry<HttpLinkHeaders>()?.headers ?? const {};

      final headers = <String, String>{
        'Accept': 'application/json',
        ...defaultHeaders,
        ...contextHeaders,
      };

      if (uploads.isNotEmpty) {
        // Multipart request for file uploads
        final multipartReq = http.MultipartRequest('POST', uri);
        multipartReq.headers.addAll(headers);

        final operations = jsonEncode({
          'query': printDocumentCached(req.operation.document),
          'operationName': req.operation.operationName,
          'variables': cleanedVars,
        });

        multipartReq.fields['operations'] = operations;

        final map = <String, List<String>>{};
        int i = 0;
        uploads.forEach((path, file) {
          final key = i.toString();
          map[key] = [path];
          multipartReq.files.add(http.MultipartFile(
            key,
            file.finalize(),
            file.length,
            filename: file.filename,
            contentType: file.contentType,
          ));
          i++;
        });

        multipartReq.fields['map'] = jsonEncode(map);
        final streamedResponse =
            await _sendCancellable(_client.send(multipartReq), cancelToken);
        httpResponse = await http.Response.fromStream(streamedResponse);
      } else {
        headers['Content-Type'] = 'application/json';
        final body = jsonEncode({
          'query': printDocumentCached(req.operation.document),
          'operationName': req.operation.operationName,
          'variables': cleanedVars,
        });
        httpResponse = await _sendCancellable(
          _client.post(uri, headers: headers, body: body),
          cancelToken,
        );
      }
    } on http.ClientException catch (e, stack) {
      throw HttpLinkConnectionException(
          originalException: e, originalStackTrace: stack);
    } catch (e, stack) {
      if (e is LinkException) rethrow;
      throw ServerException(originalException: e, originalStackTrace: stack);
    }

    if (httpResponse.statusCode >= 400 && httpResponse.body.isEmpty) {
      throw ServerException(statusCode: httpResponse.statusCode);
    }

    late final Map<String, dynamic> bodyJson;
    try {
      bodyJson = jsonDecode(httpResponse.body) as Map<String, dynamic>;
    } catch (e, stack) {
      throw ResponseFormatException(
          originalException: e, originalStackTrace: stack);
    }

    yield Response(
      data: bodyJson['data'] as Map<String, dynamic>?,
      errors: (bodyJson['errors'] as List<dynamic>?)
          ?.map((e) => GraphQLError(
                message: (e as Map<String, dynamic>)['message'] as String,
              ))
          .toList(),
      response: bodyJson,
    );
  }

  /// Races [future] against [cancelToken]'s cancellation signal.
  ///
  /// `package:http`'s [http.Client] has no per-request cancel primitive (no
  /// `CancelToken` equivalent), so a cancelled request cannot actually be
  /// aborted mid-flight — [future] keeps running in the background and its
  /// result is discarded. This just stops the caller from waiting on it.
  // ponytail: doesn't free the underlying socket early; a real abort would
  // need an IOClient-specific HttpClientRequest.abort(), not worth it for
  // the "intentionally lightweight" alternative to DioLink.
  Future<T> _sendCancellable<T>(
      Future<T> future, dio.CancelToken? cancelToken) {
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
    Map<String, http.MultipartFile> uploads,
  ) {
    if (value is http.MultipartFile) {
      uploads['variables.$path'] = value;
      return null;
    } else if (value is Map) {
      final newMap = <String, dynamic>{};
      value.forEach((key, val) {
        final currentPath = path.isEmpty ? '$key' : '$path.$key';
        newMap[key as String] =
            _extractMultipartFiles(val, currentPath, uploads);
      });
      return newMap;
    } else if (value is List) {
      final newList = [];
      for (int i = 0; i < value.length; i++) {
        final currentPath = path.isEmpty ? '$i' : '$path.$i';
        newList.add(_extractMultipartFiles(value[i], currentPath, uploads));
      }
      return newList;
    }
    return value;
  }
}
