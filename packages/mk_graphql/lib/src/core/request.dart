import 'package:dio/dio.dart';
import 'fetch_policy.dart';

/// Represents an immutable typed GraphQL request.
///
/// Extend this class to define a specific operation. The code generator
/// produces concrete subclasses automatically from `.graphql`/`.gql` files.
abstract class GraphQLRequest<TData, TVars> {
  // ---- Abstract interface ---------------------------------------------------

  /// The raw GraphQL document string (query / mutation / subscription body).
  String get document;

  /// Name of the operation to execute within [document].
  String get operationName;

  /// Typed variables for the operation.
  TVars get variables;

  /// Serializes [vars] into a JSON-compatible map for transport.
  Map<String, dynamic> toJsonVars(TVars vars);

  /// Deserializes the raw JSON response payload into strongly-typed [TData].
  TData parseData(Map<String, dynamic> json);

  // ---- Optional per-request knobs ------------------------------------------

  /// Fetch policy override for this specific request.
  /// When null the client's [defaultFetchPolicy] is used.
  final FetchPolicy? fetchPolicy;

  /// Additional HTTP headers to attach to this request only.
  final Map<String, String>? headers;

  /// Optimistic data applied to cache immediately before the network responds.
  final TData? optimisticResponse;

  /// CancelToken for cancelling the request (e.g. via Dio).
  final CancelToken? cancelToken;

  final String? _requestId;

  /// Unique identifier used for cache keying and optimistic-response tracking.
  String get requestId => _requestId ?? identityHashCode(this).toString();

  const GraphQLRequest({
    this.fetchPolicy,
    this.headers,
    this.optimisticResponse,
    this.cancelToken,
    String? requestId,
  }) : _requestId = requestId;

  /// Creates a copy of this request with the given fields replaced.
  GraphQLRequest<TData, TVars> copyWithRequest({
    TVars? variables,
    FetchPolicy? fetchPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    TData? optimisticResponse,
  });

  /// Convenient helper to copy this request with a new [fetchPolicy].
  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy) =>
      copyWithRequest(fetchPolicy: policy);
}
