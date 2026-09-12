import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:meta/meta.dart';

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
    this.serializer = const RequestSerializer(),
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
      throw DioLinkServerException(
        response: dioResponse,
        parsedResponse: _parseDioResponse(dioResponse),
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
          effectiveHeaders.remove(dio.Headers.contentTypeHeader);
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
    } on dio.DioException catch (e, stackTrace) {
      switch (e.type) {
        case dio.DioExceptionType.connectionTimeout:
        case dio.DioExceptionType.receiveTimeout:
        case dio.DioExceptionType.sendTimeout:
          throw DioLinkTimeoutException(
            type: e.type,
            originalException: e,
            originalStackTrace: stackTrace,
          );
        case dio.DioExceptionType.cancel:
          throw DioLinkCanceledException(
            originalException: e,
            originalStackTrace: stackTrace,
          );
        case dio.DioExceptionType.badResponse:
          final res = e.response;
          if (res != null && res.data is Map<String, dynamic>) {
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
          throw DioLinkServerException(
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
          throw DioLinkUnkownException(
            originalException: e,
            originalStackTrace: stackTrace,
          );
      }
    } catch (e, stackTrace) {
      if (e is LinkException) rethrow;
      throw DioLinkUnkownException(
        originalException: e,
        originalStackTrace: stackTrace,
      );
    }
  }

  Response _parseDioResponse(dio.Response<Map<String, dynamic>> res) =>
      parser.parseResponse(res.data!);

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
