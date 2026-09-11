import 'package:dio/dio.dart';
import 'package:gql_link/gql_link.dart';
import '../link/transport/dio_link.dart';

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

  const GraphQLException({
    required this.message,
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
    super.originalException,
    super.originalStackTrace,
  });
}

/// Unauthorized / Unauthenticated exception.
class UnAuthorizedException extends GraphQLException {
  const UnAuthorizedException({
    required super.message,
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
    super.originalException,
    super.originalStackTrace,
  });
}

/// Resource not found exception.
class NotFoundException extends GraphQLException {
  const NotFoundException({
    required super.message,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Parse exception.
class ParseException extends GraphQLException {
  const ParseException({
    required super.message,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Exception thrown when a GraphQL request is cancelled.
class RequestCancelledException extends GraphQLException {
  const RequestCancelledException({
    required super.message,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Network connection exception.
class NetworkException extends GraphQLException {
  const NetworkException({
    required super.message,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Request timeout exception.
class TimeoutException extends GraphQLException {
  const TimeoutException({
    required super.message,
    super.originalException,
    super.originalStackTrace,
  });
}

/// Thrown internally when the auth token must be revoked.
class RevokeTokenException extends GraphQLException {
  const RevokeTokenException({
    String message = 'Token has been revoked or refresh failed.',
    super.originalException,
    super.originalStackTrace,
  }) : super(message: message);
}

/// Helper extension to map GraphQL errors / exceptions to structured types.
extension GraphQLExceptionExtension on GraphQLException {
  static GraphQLException fromGraphQLErrors(List<GraphQLError> errors) {
    if (errors.isEmpty) {
      return const AppServerException(
          message: 'Something went wrong, please try again later.');
    }
    final error = errors.first;
    final extensions = error.extensions;
    if (extensions != null) {
      final code = extensions['code'];
      if (code == 'UNAUTHORIZED' ||
          code == 'UNAUTHENTICATED' ||
          code == 'FORBIDDEN') {
        return UnAuthorizedException(message: error.message);
      } else if (code == 'BAD_USER_INPUT' ||
          code == 'GRAPHQL_VALIDATION_FAILED') {
        return BadRequestException(
          message: error.message,
          errors: extensions['errors'] as List<dynamic>?,
          originalStackTrace: StackTrace.current,
        );
      } else if (code == 'QUERY_NOT_FOUND' || code == 'NOT_FOUND') {
        return NotFoundException(message: error.message);
      } else if (code == 'GRAPHQL_PARSE_FAILED') {
        return ParseException(message: error.message);
      }
    }
    return AppServerException(message: error.message);
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
        final gErrors = exception.parsedResponse!.errors!
            .map((e) => GraphQLError(
                  message: e.message,
                  locations: e.locations
                      ?.map((loc) => GraphQLErrorLocation(
                            line: loc.line,
                            column: loc.column,
                          ))
                      .toList(),
                  path: e.path?.cast<Object>(),
                  extensions: e.extensions,
                ))
            .toList();
        return GraphQLExceptionExtension.fromGraphQLErrors(gErrors);
      }
      return AppServerException(
        message: exception.response.statusMessage ??
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
    } else if (exception is DioLinkUnkownException) {
      final error = exception.originalException;
      if (error is DioException) {
        if (error.type == DioExceptionType.connectionError) {
          return NetworkException(
            message:
                'Something went wrong with your connection. Please check your internet connection and try again.',
            originalStackTrace: exception.originalStackTrace,
            originalException: error,
          );
        }
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
        message: exception.message ??
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
      Object exception, StackTrace stackTrace) {
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
