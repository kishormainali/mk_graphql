import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:gql/ast.dart';
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'dio_link.dart';
import '../auth/auth_link.dart';
import 'package:token_storage/token_storage.dart';
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
  }) : client = client ?? dio.Dio(),
       _ownsClient = client == null;

  /// Closes [client] only if this [SseLink] created it itself.
  @override
  Future<void> dispose() async {
    if (_ownsClient) client.close();
  }

  @override
  Stream<Response> request(Request req, [NextLink? forward]) async* {
    final contextHeaders =
        req.context.entry<HttpLinkHeaders>()?.headers ?? const {};
    final cancelToken = req.context
        .entry<DioLinkCancelTokenContextEntry>()
        ?.token;

    Map<String, String> authHeaders = const {};
    if (tokenHeader != null) {
      final token = await TokenStorage.i.accessToken;
      if (token != null) authHeaders = await tokenHeader!(token);
    }

    final headers = <String, String>{
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      ...defaultHeaders,
      ...authHeaders,
      ...contextHeaders,
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
      throw classifyDioException(e, st);
    } catch (e, st) {
      throw ServerException(originalException: e, originalStackTrace: st);
    }

    final statusCode = dioResponse.statusCode ?? 200;
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
      await for (final line
          in stream
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
        final parsed = _parseEventData(
          dataBuffer.toString().trim(),
          currentEvent,
        );
        if (parsed != null) {
          yield parsed;
        }
      }
    } on dio.DioException catch (e, st) {
      throw classifyDioException(e, st);
    }
  }

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
