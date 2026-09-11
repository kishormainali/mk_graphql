import 'error.dart';

/// Indicates where the response data originated from.
enum ResponseSource { cache, network, optimistic }

/// A typed response emitted by [GraphQLClient.request].
class GraphQLResponse<TData> {
  /// Strongly-typed response data. Null when [hasErrors] is true or data is
  /// not yet available (e.g. still [loading]).
  final TData? data;

  /// GraphQL field-level errors returned from the server.
  final List<GraphQLError>? errors;

  /// Network or link-level exception when execution failed at transport layer.
  final GraphQLException? linkException;

  /// Origin of this response.
  final ResponseSource source;

  /// True when this is an optimistic or stale-while-revalidate emission and
  /// a network response is still in flight.
  final bool loading;

  const GraphQLResponse({
    this.data,
    this.errors,
    this.linkException,
    required this.source,
    this.loading = false,
  });

  /// Whether the response carries any error (GraphQL errors or link exception).
  bool get hasErrors =>
      (errors != null && errors!.isNotEmpty) || linkException != null;

  GraphQLResponse<TData> copyWith({
    TData? data,
    List<GraphQLError>? errors,
    GraphQLException? linkException,
    ResponseSource? source,
    bool? loading,
  }) =>
      GraphQLResponse<TData>(
        data: data ?? this.data,
        errors: errors ?? this.errors,
        linkException: linkException ?? this.linkException,
        source: source ?? this.source,
        loading: loading ?? this.loading,
      );

  @override
  String toString() =>
      'GraphQLResponse(source: $source, hasData: ${data != null}, hasErrors: $hasErrors, loading: $loading)';
}
