import 'package:dio/dio.dart';
import 'package:gql_link/gql_link.dart';
import '../link/transport/dio_link.dart';
import '../link/transport/http_link.dart';
import 'graphql_error_mapper.dart';

/// Represents a single GraphQL Error returned in a GraphQL response payload.
class GraphQLError {
  final String message;
  final List<GraphQLErrorLocation>? locations;
  final List<Object>? path;
  final Map<String, dynamic>? extensions;

  const GraphQLError({
    required this.message,
    this.locations,
    this.path,
    this.extensions,
  });

  factory GraphQLError.fromJson(Map<String, dynamic> json) {
    return GraphQLError(
      message: json['message'] as String? ?? 'Unknown GraphQL error',
      locations: (json['locations'] as List<dynamic>?)
          ?.map((e) => GraphQLErrorLocation.fromJson(e as Map<String, dynamic>))
          .toList(),
      path: (json['path'] as List<dynamic>?)?.cast<Object>(),
      extensions: json['extensions'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() => {
    'message': message,
    if (locations != null)
      'locations': locations!.map((e) => e.toJson()).toList(),
    if (path != null) 'path': path,
    if (extensions != null) 'extensions': extensions,
  };

  @override
  String toString() => 'GraphQLError(message: $message, path: $path)';
}

/// Represents location coordinates of an error inside a GraphQL query document.
class GraphQLErrorLocation {
  final int line;
  final int column;

  const GraphQLErrorLocation({required this.line, required this.column});

  factory GraphQLErrorLocation.fromJson(Map<String, dynamic> json) {
    return GraphQLErrorLocation(
      line: json['line'] as int? ?? 0,
      column: json['column'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'line': line, 'column': column};

  @override
  String toString() => '($line:$column)';
}

/// Base class for all structured GraphQL exceptions.
///
/// Extends [gql_link.LinkException] so it flows naturally through the
/// gql_link pipeline error handlers.
abstract class GraphQLException extends LinkException {
  final String message;
  final List<GraphQLError>? graphqlErrors;

  const GraphQLException({
    required this.message,
    this.graphqlErrors,
    Object? originalException,
    StackTrace? originalStackTrace,
  }) : super(originalException, originalStackTrace);

  @override
  String toString() => '$runtimeType: $message';
}

/// General server-side exception.
class AppServerException extends GraphQLException {
  final int? code;
  const AppServerException({
    required super.message,
    this.code,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Unauthorized / Unauthenticated exception.
class UnAuthorizedException extends GraphQLException {
  const UnAuthorizedException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Bad request / Validation failed exception.
class BadRequestException extends GraphQLException {
  final List<dynamic>? errors;
  const BadRequestException({
    required super.message,
    this.errors,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Thrown when GraphQL input or query validation fails.
///
/// Inherits from [BadRequestException] so existing code catching [BadRequestException]
/// continues to work, while allowing granular `on ValidationException catch (e)`.
class ValidationException extends BadRequestException {
  /// Normalized map of field/property name to list of error messages.
  /// E.g. `{'email': ['Invalid email format', 'Already taken'], 'password': ['Too short']}`.
  final Map<String, List<String>> validationErrors;

  /// Combined flat list of all error messages across all fields.
  final List<String> allMessages;

  const ValidationException({
    required super.message,
    this.validationErrors = const {},
    this.allMessages = const [],
    super.errors,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });

  /// Returns all error messages associated with [field], or an empty list if none.
  List<String> getErrors(String field) => validationErrors[field] ?? const [];

  /// Returns the first error message associated with [field], or `null` if none.
  String? getFirstError(String field) => validationErrors[field]?.firstOrNull;

  /// Whether [field] has any validation error.
  bool hasError(String field) => validationErrors.containsKey(field);

  /// All field names that have validation errors.
  Set<String> get fields => validationErrors.keys.toSet();

  @override
  String toString() {
    if (validationErrors.isNotEmpty) {
      final details = validationErrors.entries
          .map((e) => '  ${e.key}: ${e.value.join(', ')}')
          .join('\n');
      return 'ValidationException: $message\n$details';
    }
    return 'ValidationException: $message';
  }
}

/// Resource not found exception.
class NotFoundException extends GraphQLException {
  const NotFoundException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Parse exception.
class ParseException extends GraphQLException {
  const ParseException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Exception thrown when a GraphQL request is cancelled.
class RequestCancelledException extends GraphQLException {
  const RequestCancelledException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Network connection exception.
class NetworkException extends GraphQLException {
  const NetworkException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Request timeout exception.
class TimeoutException extends GraphQLException {
  const TimeoutException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// The server's TLS/SSL certificate failed validation.
class CertificateException extends GraphQLException {
  const CertificateException({
    required super.message,
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Thrown internally when the auth token must be revoked.
class RevokeTokenException extends GraphQLException {
  const RevokeTokenException({
    String message = 'Token has been revoked or refresh failed.',
    super.graphqlErrors,
    super.originalException,
    super.originalStackTrace,
  }) : super(message: message);
}

/// Helper extension to map GraphQL errors / exceptions to structured types.
extension GraphQLExceptionExtension on GraphQLException {
  static GraphQLException fromGraphQLErrors(List<GraphQLError> errors) {
    if (errors.isEmpty) {
      return const AppServerException(
        message: 'Something went wrong, please try again later.',
      );
    }

    // 1. Check if any error is a validation error
    final hasValidation = errors.any(_isValidationError);

    if (hasValidation) {
      final validationErrorsMap = <String, List<String>>{};
      final allMessages = <String>[];
      final rawErrors = <dynamic>[];

      for (final err in errors) {
        _extractValidationDetails(
          error: err,
          map: validationErrorsMap,
          allMessages: allMessages,
          rawErrors: rawErrors,
        );
      }

      final primaryMessage = _resolveValidationMessage(errors, allMessages);

      return ValidationException(
        message: primaryMessage,
        validationErrors: Map.unmodifiable(validationErrorsMap),
        allMessages: List.unmodifiable(allMessages),
        errors: rawErrors.isNotEmpty ? rawErrors : null,
        graphqlErrors: errors,
        originalStackTrace: StackTrace.current,
      );
    }

    // 2. Check for other standard error types across the error list
    for (final err in errors) {
      final code = extractErrorCode(err.extensions);
      if (code == 'UNAUTHORIZED' ||
          code == 'UNAUTHENTICATED' ||
          code == 'FORBIDDEN') {
        return UnAuthorizedException(
          message: err.message,
          graphqlErrors: errors,
          originalStackTrace: StackTrace.current,
        );
      }
      if (code == 'QUERY_NOT_FOUND' || code == 'NOT_FOUND') {
        return NotFoundException(
          message: err.message,
          graphqlErrors: errors,
          originalStackTrace: StackTrace.current,
        );
      }
      if (code == 'GRAPHQL_PARSE_FAILED') {
        return ParseException(
          message: err.message,
          graphqlErrors: errors,
          originalStackTrace: StackTrace.current,
        );
      }
    }

    final combinedMessage = errors.map((e) => e.message).toSet().join('; ');
    return AppServerException(
      message: combinedMessage.isNotEmpty
          ? combinedMessage
          : 'Something went wrong, please try again later.',
      graphqlErrors: errors,
    );
  }

  static bool _isValidationError(GraphQLError error) {
    final ext = error.extensions;
    if (ext != null) {
      final code = extractErrorCode(ext);
      if (code == 'BAD_USER_INPUT' ||
          code == 'GRAPHQL_VALIDATION_FAILED' ||
          code == 'VALIDATION_FAILED' ||
          code == 'VALIDATION_ERROR' ||
          code == 'UNPROCESSABLE_ENTITY' ||
          code == 'CONSTRAINT_VIOLATION' ||
          code == 'FIELD_VALIDATION_FAILED') {
        return true;
      }

      final category = ext['category']?.toString().toLowerCase();
      if (category == 'validation') return true;

      final classification = ext['classification']?.toString().toLowerCase();
      if (classification == 'validationerror' ||
          classification == 'badrequest' ||
          classification == 'validation') {
        return true;
      }

      if (ext.containsKey('validation') ||
          ext.containsKey('validationErrors') ||
          ext.containsKey('fieldErrors') ||
          ext.containsKey('invalidArgs')) {
        return true;
      }
    }

    final lower = error.message.toLowerCase();
    if (lower.contains('validation failed') ||
        lower.contains('validation error') ||
        lower.contains('got invalid value') ||
        (lower.contains('variable') && lower.contains('invalid'))) {
      return true;
    }

    return false;
  }

  static void _extractValidationDetails({
    required GraphQLError error,
    required Map<String, List<String>> map,
    required List<String> allMessages,
    required List<dynamic> rawErrors,
  }) {
    if (!allMessages.contains(error.message)) {
      allMessages.add(error.message);
    }

    final ext = error.extensions;
    if (ext != null) {
      if (ext.containsKey('errors')) {
        rawErrors.add(ext['errors']);
      }

      // Pattern 1: Laravel Lighthouse / PHP:
      // extensions: { validation: { "input.email": ["The email has already been taken."] } }
      final validation = ext['validation'];
      if (validation is Map) {
        validation.forEach((key, val) {
          final k = key.toString();
          if (val is List) {
            for (final m in val) {
              if (m != null) {
                final str = m.toString();
                map.putIfAbsent(k, () => []).add(str);
                if (!allMessages.contains(str)) allMessages.add(str);
              }
            }
          } else if (val != null) {
            final str = val.toString();
            map.putIfAbsent(k, () => []).add(str);
            if (!allMessages.contains(str)) allMessages.add(str);
          }
        });
      }

      // Pattern 2: Apollo / class-validator / NestJS:
      // extensions: { validationErrors: [ { field: 'email', messages: ['...'] } ] }
      // or { property: 'email', constraints: { isEmail: '...' } }
      final validationErrors = ext['validationErrors'] ?? ext['errors'];
      if (validationErrors is List) {
        for (final item in validationErrors) {
          if (item is Map) {
            final field =
                item['field'] ??
                item['property'] ??
                (item['path'] is List
                    ? (item['path'] as List).join('.')
                    : item['path']);
            final fieldName = field?.toString();

            final itemMessages = <String>[];
            if (item['messages'] is List) {
              itemMessages.addAll(
                (item['messages'] as List).map((e) => e.toString()),
              );
            } else if (item['message'] != null) {
              itemMessages.add(item['message'].toString());
            } else if (item['constraints'] is Map) {
              itemMessages.addAll(
                (item['constraints'] as Map).values.map((e) => e.toString()),
              );
            }

            if (fieldName != null && itemMessages.isNotEmpty) {
              map.putIfAbsent(fieldName, () => []).addAll(itemMessages);
              for (final m in itemMessages) {
                if (!allMessages.contains(m)) allMessages.add(m);
              }
            }
          }
        }
      }

      // Pattern 3: fieldErrors map
      // extensions: { fieldErrors: { "email": ["Invalid"] } }
      final fieldErrors = ext['fieldErrors'];
      if (fieldErrors is Map) {
        fieldErrors.forEach((key, val) {
          final k = key.toString();
          if (val is List) {
            for (final m in val) {
              if (m != null) {
                final str = m.toString();
                map.putIfAbsent(k, () => []).add(str);
                if (!allMessages.contains(str)) allMessages.add(str);
              }
            }
          } else if (val != null) {
            final str = val.toString();
            map.putIfAbsent(k, () => []).add(str);
            if (!allMessages.contains(str)) allMessages.add(str);
          }
        });
      }

      // Pattern 4: Apollo invalidArgs:
      // extensions: { invalidArgs: ["email", "password"] }
      final invalidArgs = ext['invalidArgs'];
      if (invalidArgs is List) {
        for (final arg in invalidArgs) {
          final k = arg.toString();
          map.putIfAbsent(k, () => []).add(error.message);
        }
      }

      // Pattern 5: NestJS response object:
      // extensions: { response: { message: ["email must be an email"] } }
      final responseObj = ext['response'];
      if (responseObj is Map && responseObj['message'] is List) {
        for (final m in responseObj['message'] as List) {
          if (m != null) {
            final str = m.toString();
            if (!allMessages.contains(str)) allMessages.add(str);
          }
        }
      }

      // Pattern 6: Single field in extensions:
      // extensions: { field: "email" }
      final singleField = ext['field']?.toString();
      if (singleField != null && singleField.isNotEmpty) {
        map.putIfAbsent(singleField, () => []).add(error.message);
      }
    }

    // Pattern 7: GraphQL path attribute:
    // path: ["createUser", "email"] -> field: "email"
    if (error.path != null && error.path!.isNotEmpty) {
      final field = error.path!.last.toString();
      if (!map.containsKey(field)) {
        map.putIfAbsent(field, () => []).add(error.message);
      }
    }
  }

  static String _resolveValidationMessage(
    List<GraphQLError> errors,
    List<String> allMessages,
  ) {
    if (errors.length == 1) {
      return errors.first.message;
    }
    final first = errors.first.message;
    if (first.toLowerCase().contains('validation failed') ||
        first.toLowerCase().contains('bad request')) {
      return first;
    }
    return errors.map((e) => e.message).toSet().join('; ');
  }

  static GraphQLException fromLinkException(Object exception) {
    if (exception is GraphQLException) return exception;

    if (exception is DioLinkParserException) {
      return ParseException(
        message: 'An error occurred while parsing the response.',
        originalException: exception.originalException,
        originalStackTrace: exception.originalStackTrace,
      );
    } else if (exception is DioLinkServerException) {
      if (exception.parsedResponse != null &&
          exception.parsedResponse!.errors != null &&
          exception.parsedResponse!.errors!.isNotEmpty) {
        final gErrors = mapGraphQLErrors(exception.parsedResponse!.errors)!;
        return GraphQLExceptionExtension.fromGraphQLErrors(gErrors);
      }
      return AppServerException(
        message:
            exception.response.statusMessage ??
            'Something went wrong, please try again later.',
        code: exception.response.statusCode,
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioLinkTimeoutException) {
      return TimeoutException(
        message:
            'Server is taking too long to respond. Please try again later.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioLinkCanceledException) {
      return RequestCancelledException(
        message: 'The request was cancelled.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioLinkConnectionException) {
      return NetworkException(
        message:
            'Something went wrong with your connection. Please check your internet connection and try again.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioLinkCertificateException) {
      return CertificateException(
        message: 'Could not establish a secure connection to the server.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is HttpLinkCanceledException) {
      return RequestCancelledException(
        message: 'The request was cancelled.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is HttpLinkConnectionException) {
      return NetworkException(
        message:
            'Something went wrong with your connection. Please check your internet connection and try again.',
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioLinkUnkownException) {
      final error = exception.originalException;
      if (error is DioException) {
        return AppServerException(
          message:
              error.message ?? 'Something went wrong, please try again later.',
          originalStackTrace: exception.originalStackTrace,
          originalException: exception.originalException,
        );
      }
      return AppServerException(
        message: exception.toString(),
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    } else if (exception is DioException) {
      if (exception.type == DioExceptionType.connectionError) {
        return NetworkException(
          message:
              'Something went wrong with your connection. Please check your internet connection and try again.',
          originalException: exception,
        );
      } else if (exception.type == DioExceptionType.cancel) {
        return RequestCancelledException(
          message: 'The request was cancelled.',
          originalException: exception,
        );
      }
      return AppServerException(
        message:
            exception.message ??
            'Something went wrong, please try again later.',
        originalException: exception,
      );
    } else if (exception is LinkException) {
      return AppServerException(
        message: exception.toString(),
        originalStackTrace: exception.originalStackTrace,
        originalException: exception.originalException,
      );
    }

    return AppServerException(message: exception.toString());
  }

  static GraphQLException fromException(
    Object exception,
    StackTrace stackTrace,
  ) {
    if (exception is GraphQLException) return exception;
    if (exception is FormatException ||
        exception.toString().contains('is not a subtype of')) {
      return ParseException(
        message: 'An error occurred while parsing the response.',
        originalException: exception,
        originalStackTrace: stackTrace,
      );
    }
    return AppServerException(
      message: exception.toString(),
      originalStackTrace: stackTrace,
      originalException: exception,
    );
  }
}
