import 'package:dio/dio.dart';
import '../core/fetch_policy.dart';
import '../core/request.dart';

/// Combines multiple [GraphQLRequest] instances into a single composed request.
///
/// Useful for batching several operations into one network round-trip when
/// used with [BatchLink].
class CompositeGraphQLRequest
    extends GraphQLRequest<Map<String, dynamic>, Map<String, dynamic>> {
  final List<GraphQLRequest> requests;

  CompositeGraphQLRequest(
    this.requests, {
    FetchPolicy? fetchPolicy,
    Map<String, String>? headers,
  }) : super(
          fetchPolicy: fetchPolicy,
          headers: headers,
          requestId: requests.map((r) => r.requestId).join('_'),
        );

  @override
  String get document => requests.map((r) => r.document).join('\n');

  @override
  String get operationName => requests.map((r) => r.operationName).join('_');

  @override
  Map<String, dynamic> get variables => {
        for (final r in requests) r.operationName: r.toJsonVars(r.variables),
      };

  @override
  Map<String, dynamic> toJsonVars(Map<String, dynamic> vars) => vars;

  @override
  Map<String, dynamic> parseData(Map<String, dynamic> json) => {
        for (final r in requests)
          r.operationName: r.parseData(
            json.containsKey(r.operationName)
                ? json[r.operationName] as Map<String, dynamic>
                : json,
          ),
      };

  @override
  CompositeGraphQLRequest copyWithRequest({
    Map<String, dynamic>? variables,
    FetchPolicy? fetchPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    Map<String, dynamic>? optimisticResponse,
  }) {
    return CompositeGraphQLRequest(
      requests,
      fetchPolicy: fetchPolicy ?? this.fetchPolicy,
      headers: headers ?? this.headers,
    );
  }
}

