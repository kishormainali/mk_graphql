import 'dart:convert';

import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';

import '../../core/document_print_cache.dart';
import 'logger.dart';
import 'logger_options.dart';

/// A [Link] that logs GraphQL requests, responses, and errors.
class LoggerLink extends Link {
  final LoggerOptions options;

  const LoggerLink({this.options = const LoggerOptions()});

  static const _encoder = JsonEncoder.withIndent('  ');

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    assert(forward != null, 'LoggerLink must be followed by another link.');

    Logger.useAnsiColors = options.useAnsiColors;

    final operationName = request.operation.operationName ?? 'Unknown';
    final start = DateTime.now();

    _logRequest(request, operationName, start);

    try {
      await for (final response in forward!(request)) {
        final duration = DateTime.now().difference(start);

        if (response.errors != null && response.errors!.isNotEmpty) {
          _logGraphQLError(response, operationName, duration);
          yield response;
          continue;
        }

        _logResponse(response, operationName, duration);
        yield response;
      }
    } on LinkException catch (e, stackTrace) {
      final duration = DateTime.now().difference(start);
      _logLinkException(e, operationName, duration, stackTrace);
      rethrow;
    } catch (e, stackTrace) {
      final duration = DateTime.now().difference(start);
      _logException('Exception', e, operationName, duration, stackTrace);
      rethrow;
    }
  }

  void _logRequest(Request request, String operationName, DateTime start) {
    try {
      final messages = <String>[
        'GraphQL Request $operationName started at ${start.toIso8601String()}',
      ];

      _addHeadersToMessages(request, messages);
      _addQueryToMessages(request, messages);
      _addVariablesToMessages(request, messages);

      Logger.boxed(
        messages,
        tag: 'LoggerLink | Request',
        redact: options.redact,
      );
    } catch (e, stackTrace) {
      Logger.e(
        'Failed to log request: $operationName',
        error: e,
        stackTrace: stackTrace,
        tag: 'LoggerLink | LogError',
      );
    }
  }

  void _addHeadersToMessages(Request request, List<String> messages) {
    try {
      final headers = request.context.entry<HttpLinkHeaders>()?.headers;
      if (headers != null && headers.isNotEmpty && options.requestHeader) {
        final copy = Map<String, String>.from(headers);
        if (!options.authHeader) {
          copy.removeWhere(
            (key, _) => key.toLowerCase() == 'authorization',
          );
        }
        messages.add(_encoder.convert(copy));
      }
    } catch (_) {
      messages.add('Headers::: [Failed to encode]');
    }
  }

  void _addQueryToMessages(Request request, List<String> messages) {
    try {
      if (options.requestBody) {
        messages.add(printDocumentCached(request.operation.document));
      }
    } catch (_) {
      messages.add('Query::: [Failed to encode]');
    }
  }

  void _addVariablesToMessages(Request request, List<String> messages) {
    try {
      final variables = request.variables;
      if (variables.isNotEmpty && options.requestBody) {
        messages.add(_encoder.convert(variables));
      }
    } catch (_) {
      messages.add('Variables::: [Failed to encode]');
    }
  }

  void _logResponse(
      Response response, String operationName, Duration duration) {
    try {
      final messages = <String>[
        'GraphQL Request $operationName succeeded in ${duration.inMilliseconds}ms',
      ];
      if (options.responseHeader) {
        _addResponseHeaders(response, messages);
      }

      if (options.responseBody && response.data != null) {
        try {
          messages.add(_encoder.convert(response.data));
        } catch (_) {
          messages.add('Data::: [Failed to encode]');
        }
      }

      Logger.boxed(
        messages,
        tag: 'LoggerLink | Response',
        redact: options.redact,
      );
    } catch (e, stackTrace) {
      Logger.e(
        'Failed to log response: $operationName',
        error: e,
        stackTrace: stackTrace,
        tag: 'LoggerLink | LogError',
      );
    }
  }

  void _addResponseHeaders(Response response, List<String> messages) {
    try {
      final headers =
          response.context.entry<HttpLinkResponseContext>()?.rawHeaders;
      if (headers != null && headers.isNotEmpty) {
        messages.add(_encoder.convert(headers));
      }
    } catch (_) {
      messages.add('Response Headers::: [Failed to encode]');
    }
  }

  void _logGraphQLError(
      Response response, String operationName, Duration duration) {
    try {
      final errors = response.errors!;
      final errorMessages = errors.map((e) => e.message).join('; ');

      final messages = <String>[
        'GraphQL Request $operationName failed with $errorMessages in ${duration.inMilliseconds}ms',
      ];

      if (options.error) {
        try {
          final errorData = errors
              .map((e) => {
                    'message': e.message,
                    if (e.locations != null)
                      'locations': e.locations!
                          .map((l) => {'line': l.line, 'column': l.column})
                          .toList(),
                    if (e.path != null) 'path': e.path,
                    if (e.extensions != null) 'extensions': e.extensions,
                  })
              .toList();
          messages.add(_encoder.convert(errorData));
        } catch (_) {
          messages.add('Errors::: [Failed to encode]');
        }
      }

      Logger.boxed(
        messages,
        tag: 'LoggerLink | GraphQLError',
        redact: options.redact,
      );
    } catch (e, stackTrace) {
      Logger.e(
        'Failed to log GraphQL error: $operationName',
        error: e,
        stackTrace: stackTrace,
        tag: 'LoggerLink | LogError',
      );
    }
  }

  void _logLinkException(LinkException exception, String operationName,
      Duration duration, StackTrace stackTrace) {
    Logger.e(
      'GraphQL Request $operationName failed at link level in ${duration.inMilliseconds}ms',
      error: exception,
      stackTrace: stackTrace,
      tag: 'LoggerLink | LinkException',
    );
  }

  void _logException(String type, Object exception, String operationName,
      Duration duration, StackTrace stackTrace) {
    Logger.e(
      'GraphQL Request $operationName failed with $type in ${duration.inMilliseconds}ms',
      error: exception,
      stackTrace: stackTrace,
      tag: 'LoggerLink | $type',
    );
  }
}
