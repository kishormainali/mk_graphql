import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'dio_link.dart';
import '../auth/auth_link.dart';
import '../../client/client.dart';
import '../../core/error.dart';

/// Terminating [Link] for GraphQL over Server-Sent Events (SSE).
///
/// Implements the GraphQL over Server-Sent Events Protocol, consuming
/// `text/event-stream` responses from GraphQL servers via HTTP streaming.
class SseLink extends Link {
  final String url;
  final dio.Dio client;
  final Map<String, String> defaultHeaders;
  final AccessTokenCallback? tokenHeader;
  final OnRefreshCallback? onTokenRefresh;
  final bool useGetForQueries;
  final ResponseParser parser;

  /// Internal [GraphQLClient] (no auth link) used exclusively for refresh requests.
  late final GraphQLClient _refreshClient;

  SseLink(
    this.url, {
    dio.Dio? client,
    this.defaultHeaders = const {},
    this.tokenHeader,
    this.onTokenRefresh,
    this.useGetForQueries = false,
    this.parser = const ResponseParser(),
  }) : client = client ?? dio.Dio() {
    _refreshClient = GraphQLClient.fromLink(DioLink(url, client: this.client));
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    final cancelToken =
        req.context.entry<DioLinkCancelTokenContextEntry>()?.token;

    final authHeaders = await tokenHeader?.call() ?? const {};

    var headers = <String, String>{
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...defaultHeaders,
      ...authHeaders,
      ...contextHeaders,
    };

    final queryString = printNode(req.operation.document);
    final operationName = req.operation.operationName;
    final variables = req.variables;

    final body = {
      'query': queryString,
      if (operationName != null) 'operationName': operationName,
      if (variables.isNotEmpty) 'variables': variables,
    };

    final isQuery = req.operation.document.definitions
        .whereType<OperationDefinitionNode>()
        .any((def) => def.type == OperationType.query);

    Future<dio.Response<dio.ResponseBody>> sendRequest(
        Map<String, String> hdrs) {
      if (useGetForQueries && isQuery) {
        return client.get<dio.ResponseBody>(
          url,
          queryParameters: {
            'query': queryString,
            if (operationName != null) 'operationName': operationName,
            if (variables.isNotEmpty) 'variables': jsonEncode(variables),
          },
          options: dio.Options(
            responseType: dio.ResponseType.stream,
            headers: hdrs,
          ),
          cancelToken: cancelToken,
        );
      } else {
        return client.post<dio.ResponseBody>(
          url,
          data: body,
          options: dio.Options(
            responseType: dio.ResponseType.stream,
            headers: {
              ...hdrs,
              'Content-Type': 'application/json',
            },
          ),
          cancelToken: cancelToken,
        );
      }
    }

    dio.Response<dio.ResponseBody> dioResponse;
    try {
      try {
        dioResponse = await sendRequest(headers);
        if (dioResponse.statusCode == 401 && onTokenRefresh != null) {
          final newHeaders = await onTokenRefresh!(_refreshClient);
          if (newHeaders != null && newHeaders.isNotEmpty) {
            headers = {
              ...headers,
              ...newHeaders,
            };
            dioResponse = await sendRequest(headers);
          }
        }
      } on dio.DioException catch (e) {
        if (e.response?.statusCode == 401 && onTokenRefresh != null) {
          final newHeaders = await onTokenRefresh!(_refreshClient);
          if (newHeaders != null && newHeaders.isNotEmpty) {
            headers = {
              ...headers,
              ...newHeaders,
            };
            dioResponse = await sendRequest(headers);
          } else {
            rethrow;
          }
        } else {
          rethrow;
        }
      }
    } on dio.DioException catch (e, st) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw DioLinkCanceledException(
          originalException: e,
          originalStackTrace: st,
        );
      }
      if (e.response?.statusCode == 401) {
        throw const UnAuthorizedException(message: 'Unauthorized');
      }
      throw ServerException(
        originalException: e,
        originalStackTrace: st,
        statusCode: e.response?.statusCode,
      );
    } catch (e, st) {
      if (e is UnAuthorizedException) rethrow;
      throw ServerException(
        originalException: e,
        originalStackTrace: st,
      );
    }

    final statusCode = dioResponse.statusCode ?? 200;
    if (statusCode == 401) {
      throw const UnAuthorizedException(message: 'Unauthorized');
    }
    if (statusCode >= 300) {
      throw ServerException(
        statusCode: statusCode,
        originalException: dioResponse.statusMessage,
      );
    }

    final stream = dioResponse.data?.stream;
    if (stream == null) return;

    String currentEvent = 'next';
    final dataBuffer = StringBuffer();

    try {
      await for (final line in stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          if (dataBuffer.isNotEmpty) {
            final rawData = dataBuffer.toString().trim();
            dataBuffer.clear();

            if (currentEvent == 'complete') {
              break;
            }

            final parsed = _parseEventData(rawData, currentEvent);
            if (parsed != null) {
              yield parsed;
            }
            currentEvent = 'next';
          }
        } else if (trimmed.startsWith(':')) {
          // Comment / keepalive line
          continue;
        } else if (trimmed.startsWith('event:')) {
          currentEvent = trimmed.substring(6).trim();
        } else if (trimmed.startsWith('data:')) {
          dataBuffer.writeln(trimmed.substring(5).trim());
        }
      }

      if (dataBuffer.isNotEmpty && currentEvent != 'complete') {
        final parsed =
            _parseEventData(dataBuffer.toString().trim(), currentEvent);
        if (parsed != null) {
          yield parsed;
        }
      }
    } on dio.DioException catch (e, st) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw DioLinkCanceledException(
          originalException: e,
          originalStackTrace: st,
        );
      }
      throw ServerException(
        originalException: e,
        originalStackTrace: st,
      );
    }
  }

  Response? _parseEventData(String rawData, String eventType) {
    if (rawData.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final Map<String, dynamic> payload = decoded.containsKey('payload') &&
              decoded['payload'] is Map<String, dynamic>
          ? decoded['payload'] as Map<String, dynamic>
          : decoded;

      return parser.parseResponse(payload);
    } catch (e, st) {
      throw ServerException(
        originalException: e,
        originalStackTrace: st,
      );
    }
  }
}
