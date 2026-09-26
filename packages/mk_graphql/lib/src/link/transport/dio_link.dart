import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:meta/meta.dart';

import '../../core/document_print_cache.dart';

/// Context entry for attaching a [dio.CancelToken] to a [Request].
@immutable
class DioLinkCancelTokenContextEntry extends ContextEntry {
  final dio.CancelToken? token;

  const DioLinkCancelTokenContextEntry(this.token);

  @override
  List<Object?> get fieldsForEquality => [token];
}

// -----------------------------------------------------------------------------
// Exceptions
// -----------------------------------------------------------------------------

/// Exception thrown when response parsing fails in [DioLink].
@immutable
class DioLinkParserException extends ResponseFormatException {
  final dio.Response response;

  const DioLinkParserException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
    required this.response,
  }) : super(
          originalException: originalException,
          originalStackTrace: originalStackTrace,
        );
}

/// Exception thrown when a server error occurs in [DioLink].
@immutable
class DioLinkServerException extends ServerException {
  final dio.Response response;

  const DioLinkServerException({
    required this.response,
    required Response? parsedResponse,
    Object? originalException,
    StackTrace? originalStackTrace,
    int? statusCode,
  }) : super(
          parsedResponse: parsedResponse,
          statusCode: statusCode,
          originalException: originalException,
          originalStackTrace: originalStackTrace,
        );

  @override
  String toString() {
    final dynamic data = response.data;
    String plain = '...';
    if (data is String) {
      plain =
          data.length > 80 ? data.replaceRange(80, data.length, '...') : data;
    }
    return 'DioLinkServerException(status: ${response.statusCode}, response: ${parsedResponse ?? plain})';
  }
}

/// Exception thrown on generic unknown network errors in [DioLink].
@immutable
class DioLinkUnkownException extends LinkException {
  const DioLinkUnkownException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Exception thrown when a network timeout occurs in [DioLink].
@immutable
class DioLinkTimeoutException extends LinkException {
  final dio.DioExceptionType type;

  const DioLinkTimeoutException({
    required this.type,
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Exception thrown when a request is cancelled in [DioLink].
@immutable
class DioLinkCanceledException extends LinkException {
  const DioLinkCanceledException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Exception thrown when there is no network connectivity, or the
/// connection is refused/reset (DNS failure, socket error, etc).
@immutable
class DioLinkConnectionException extends LinkException {
  const DioLinkConnectionException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

/// Exception thrown when the server's TLS/SSL certificate fails validation.
@immutable
class DioLinkCertificateException extends LinkException {
  const DioLinkCertificateException({
    required Object? originalException,
    required StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);
}

// -----------------------------------------------------------------------------
// Shared Dio exception classification
// -----------------------------------------------------------------------------

/// Classifies a [dio.DioException] into the matching `DioLink*Exception` —
/// shared by every Dio-based terminating link ([DioLink], [SseLink]) so
/// connection failures (timeouts, cancellation, DNS/socket errors, bad TLS
/// certificates, non-2xx statuses) are reported the same, structured way
/// everywhere instead of each transport bucketing most of them into one
/// generic exception.
///
/// Doesn't special-case a `badResponse` whose body might still parse as
/// GraphQL data — only [DioLink]'s non-streamed responses can, so that
/// link checks for it itself before falling back to this.
LinkException classifyDioException(dio.DioException e, StackTrace stackTrace) {
  switch (e.type) {
    case dio.DioExceptionType.connectionTimeout:
    case dio.DioExceptionType.receiveTimeout:
    case dio.DioExceptionType.sendTimeout:
      return DioLinkTimeoutException(
        type: e.type,
        originalException: e,
        originalStackTrace: stackTrace,
      );
    case dio.DioExceptionType.cancel:
      return DioLinkCanceledException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    case dio.DioExceptionType.connectionError:
      return DioLinkConnectionException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    case dio.DioExceptionType.badCertificate:
      return DioLinkCertificateException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    case dio.DioExceptionType.badResponse:
      return DioLinkServerException(
        response: e.response ??
            dio.Response(
              requestOptions: e.requestOptions,
              statusCode: e.response?.statusCode,
            ),
        parsedResponse: null,
        statusCode: e.response?.statusCode,
        originalException: e,
        originalStackTrace: stackTrace,
      );
    default:
      return DioLinkUnkownException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
  }
}

// -----------------------------------------------------------------------------
// Cached request serializer
// -----------------------------------------------------------------------------

/// Mirrors `RequestSerializer.serializeRequest` (`package:gql_link`) except
/// it prints the query document through [printDocumentCached] instead of
/// calling `printNode` directly — this is the actual per-request hot path
/// (every network call serializes its request body), so caching it matters
/// more than caching the AST transform in [TypenameLink] alone would.
///
/// Kept in sync with the upstream method by hand since `gql_link` doesn't
/// expose an overridable seam for just the printing step; re-check this
/// against `RequestSerializer.serializeRequest` on any `gql_link` bump.
class _CachedRequestSerializer extends RequestSerializer {
  const _CachedRequestSerializer();

  @override
  Map<String, dynamic> serializeRequest(Request request) {
    final RequestExtensionsThunk? thunk = request.context.entry();
    return <String, dynamic>{
      'operationName': request.operation.operationName,
      'variables': request.variables,
      'query': printDocumentCached(request.operation.document),
      if (thunk != null) 'extensions': thunk.getRequestExtensions(request),
    };
  }
}

// -----------------------------------------------------------------------------
// DioLink Implementation
// -----------------------------------------------------------------------------

/// HTTP [Link] execution transport powered by [dio.Dio].
///
/// Supports query, mutation, cancellation via [DioLinkCancelTokenContextEntry],
/// and file uploads complying with the GraphQL Multipart Request Specification.
class DioLink extends Link {
  /// The GraphQL service HTTP endpoint.
  final String endpoint;

  /// Underlying [dio.Dio] client instance.
  final dio.Dio client;

  /// Default HTTP headers merged into every request.
  final Map<String, String> defaultHeaders;

  /// Request serializer (converts [Request] to wire map).
  final RequestSerializer serializer;

  /// Response parser (converts wire map to [Response]).
  final ResponseParser parser;

  /// Whether to issue HTTP GET requests for queries.
  final bool useGETForQueries;

  DioLink(
    this.endpoint, {
    required this.client,
    this.defaultHeaders = const {},
    this.serializer = const _CachedRequestSerializer(),
    this.parser = const ResponseParser(),
    this.useGETForQueries = false,
  });

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    final dio.Response<Map<String, dynamic>> dioResponse =
        await _executeDioRequest(
      request: request,
      headers: <String, String>{
        dio.Headers.acceptHeader:
            'application/graphql-response+json, application/json, */*',
        dio.Headers.contentTypeHeader: dio.Headers.jsonContentType,
        ...defaultHeaders,
        ..._getHttpLinkHeaders(request),
      },
      isQuery: _isQuery(request),
    );

    if ((dioResponse.statusCode ?? 200) >= 300 ||
        (dioResponse.data!['data'] == null &&
            dioResponse.data!['errors'] == null)) {
      // Best-effort: an error response with an unparseable body still
      // reports as DioLinkServerException (with the real status code),
      // just without parsedResponse rather than losing that status
      // classification to a parser exception.
      Response? parsedResponse;
      try {
        parsedResponse = _parseDioResponse(dioResponse);
      } on DioLinkParserException {
        parsedResponse = null;
      }
      throw DioLinkServerException(
        response: dioResponse,
        parsedResponse: parsedResponse,
        statusCode: dioResponse.statusCode,
      );
    }

    final gqlResponse = _parseDioResponse(dioResponse);
    yield Response(
      data: gqlResponse.data,
      errors: gqlResponse.errors,
      response: gqlResponse.response,
      context: _updateResponseContext(gqlResponse, dioResponse),
    );
  }

  Map<String, String> _getHttpLinkHeaders(Request request) =>
      request.context.entry<HttpLinkHeaders>()?.headers ?? const {};

  bool _isQuery(Request request) {
    final defs = request.operation.document.definitions
        .whereType<OperationDefinitionNode>();
    if (request.operation.operationName != null) {
      final matching = defs
          .where((node) => node.name?.value == request.operation.operationName);
      if (matching.isNotEmpty) {
        return matching.first.type == OperationType.query;
      }
    }
    return defs.any((def) => def.type == OperationType.query);
  }

  dynamic _prepareRequestBody(Request request) {
    final body = _encodeAttempter(
      request,
      serializer.serializeRequest,
    )(request);

    final fileMap = _extractFlattenedFileMap(body);
    if (fileMap.isEmpty) return body;

    final encodedBody = _encodeAttempter(
      request,
      (Map b) => json.encode(
        b,
        toEncodable: (dynamic obj) {
          if (obj is dio.MultipartFile) return null;
          try {
            return (obj as dynamic).toJson();
          } catch (_) {
            return null;
          }
        },
      ),
    )(body);

    return dio.FormData.fromMap(
      <String, dynamic>{
        'operations': encodedBody,
      }..addAll(_generateFileFormBody(fileMap)),
    );
  }

  Map<String, String> _encodeAsUriParams(Map<String, dynamic> serialized) =>
      serialized.map<String, String>(
        (k, dynamic v) => MapEntry(k, v is String ? v : json.encode(v)),
      );

  T Function(V) _encodeAttempter<T, V>(
    Request request,
    T Function(V) encoder,
  ) =>
      (V input) {
        try {
          return encoder(input);
        } catch (e, stackTrace) {
          throw RequestFormatException(
            originalException: e,
            originalStackTrace: stackTrace,
            request: request,
          );
        }
      };

  Context _updateResponseContext(
    Response response,
    dio.Response httpResponse,
  ) {
    try {
      return response.context.withEntry(
        HttpLinkResponseContext(
          statusCode: httpResponse.statusCode!,
          rawHeaders: httpResponse.headers.map,
        ),
      );
    } catch (e, stackTrace) {
      throw ContextWriteException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  Future<dio.Response<Map<String, dynamic>>> _executeDioRequest({
    required Request request,
    required Map<String, String> headers,
    required bool isQuery,
  }) async {
    try {
      final dynamic body = _prepareRequestBody(request);
      dio.Response<dynamic> res;
      final dio.CancelToken? cancelToken =
          request.context.entry<DioLinkCancelTokenContextEntry>()?.token;

      final useGet =
          useGETForQueries && body is Map<String, dynamic> && isQuery;
      if (useGet) {
        res = await client.getUri<dynamic>(
          Uri.parse(endpoint).replace(
            queryParameters: _encodeAttempter(
              request,
              _encodeAsUriParams,
            )(body),
          ),
          cancelToken: cancelToken,
          options: dio.Options(
            responseType: dio.ResponseType.json,
            headers: headers,
          ),
        );
      } else {
        final effectiveHeaders = Map<String, String>.from(headers);
        if (body is dio.FormData) {
          // Dio sets the multipart Content-Type (with its boundary) itself; a
          // header of any casing here — e.g. one from defaultHeaders — would
          // otherwise be sent instead and break the upload.
          effectiveHeaders.removeWhere(
            (key, _) => key.toLowerCase() == dio.Headers.contentTypeHeader,
          );
        }
        res = await client.post<dynamic>(
          endpoint,
          cancelToken: cancelToken,
          data: body,
          options: dio.Options(
            responseType: dio.ResponseType.json,
            headers: effectiveHeaders,
          ),
        );
      }

      if (res.data is! Map<String, dynamic>) {
        throw DioLinkParserException(
          originalException:
              "Expected response data to be 'Map<String, dynamic>' but found ${res.data.runtimeType}",
          originalStackTrace: StackTrace.current,
          response: res,
        );
      }
      return _asJsonResponse(res);
    } on dio.DioException catch (e, stackTrace) {
      // A badResponse whose body still parsed as JSON might carry a
      // GraphQL error payload — only DioLink's non-streamed responses can,
      // so it's the one link that checks for this before classifying.
      if (e.type == dio.DioExceptionType.badResponse) {
        final res = e.response;
        if (res != null && res.data is Map<String, dynamic>) {
          return _asJsonResponse(res);
        }
      }
      throw classifyDioException(e, stackTrace);
    } catch (e, stackTrace) {
      if (e is LinkException) rethrow;
      throw DioLinkUnkownException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  /// Re-wraps a raw [dio.Response] whose `data` is known to already be a
  /// `Map<String, dynamic>` as a typed [dio.Response<Map<String, dynamic>>],
  /// preserving every other field. Used both for the success path and for
  /// a `badResponse` [dio.DioException] whose body still parsed as JSON.
  static dio.Response<Map<String, dynamic>> _asJsonResponse(
    dio.Response<dynamic> res,
  ) {
    return dio.Response<Map<String, dynamic>>(
      data: res.data as Map<String, dynamic>,
      headers: res.headers,
      requestOptions: res.requestOptions,
      isRedirect: res.isRedirect,
      statusCode: res.statusCode,
      statusMessage: res.statusMessage,
      redirects: res.redirects,
      extra: res.extra,
    );
  }

  /// [ResponseParser.parseResponse] does unchecked casts on the response
  /// body (`errors[].message as String`, `data as Map?`, ...) — a malformed
  /// GraphQL payload (present but wrongly-shaped `data`/`errors`) throws a
  /// raw [TypeError] here rather than a [LinkException]. Wrap it so it's
  /// classified the same way as any other unparseable response.
  Response _parseDioResponse(dio.Response<Map<String, dynamic>> res) {
    try {
      return parser.parseResponse(res.data!);
    } catch (e, stackTrace) {
      throw DioLinkParserException(
        originalException: e,
        originalStackTrace: stackTrace,
        response: res,
      );
    }
  }

  static Map<String, dio.MultipartFile> _extractFlattenedFileMap(
    dynamic body, {
    Map<String, dio.MultipartFile>? currentMap,
    List<String> currentPath = const <String>[],
  }) {
    currentMap ??= <String, dio.MultipartFile>{};
    if (body is Map<String, dynamic>) {
      for (final element in body.entries) {
        currentMap.addAll(_extractFlattenedFileMap(
          element.value,
          currentMap: currentMap,
          currentPath: List<String>.from(currentPath)..add(element.key),
        ));
      }
      return currentMap;
    }
    if (body is List<dynamic>) {
      for (int i = 0; i < body.length; i++) {
        currentMap.addAll(_extractFlattenedFileMap(
          body[i],
          currentMap: currentMap,
          currentPath: List<String>.from(currentPath)..add(i.toString()),
        ));
      }
      return currentMap;
    }
    if (body is dio.MultipartFile) {
      return currentMap..addAll({currentPath.join('.'): body});
    }
    return currentMap;
  }

  static Map<String, dynamic> _generateFileFormBody(
      Map<String, dio.MultipartFile> fileMap) {
    final Map<String, List<String>> fileMapping = {};
    final List<dio.MultipartFile> fileList = [];
    final entries = fileMap.entries.toList(growable: false);
    final Map<String, dynamic> fileFormBody = {};

    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final indexStr = i.toString();
      fileMapping[indexStr] = [entry.key];
      fileList.add(entry.value);
    }

    fileFormBody['map'] = json.encode(fileMapping);
    for (var i = 0; i < fileList.length; i++) {
      fileFormBody[i.toString()] = fileList[i];
    }
    return fileFormBody;
  }
}
