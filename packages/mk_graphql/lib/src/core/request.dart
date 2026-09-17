import 'package:dio/dio.dart';
import 'package:gql/ast.dart';
import 'document_cache.dart';
import 'error_policy.dart';
import 'fetch_policy.dart';
import 'retry_options.dart';

/// Represents an immutable typed GraphQL request.
///
/// Extend this class to define a specific operation. The code generator
/// produces concrete subclasses automatically from `.graphql`/`.gql` files.
abstract class GraphQLRequest<TData, TVars> {
  // ---- Abstract interface ---------------------------------------------------

  /// The raw GraphQL document string (query / mutation / subscription body).
  String get document;

  /// The parsed AST [GraphQLClient] sends over the wire. Defaults to parsing
  /// [document] through the shared process-wide cache (parsed once per
  /// unique string). The generator overrides this with a `static final`
  /// field computed once per request class instead, skipping even that
  /// cache lookup on every subsequent request.
  DocumentNode get documentNode => getParsedDocument(document);

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

  /// Error policy override for this specific request.
  /// When null the client's [defaultErrorPolicy] is used.
  final ErrorPolicy? errorPolicy;

  /// Additional HTTP headers to attach to this request only.
  final Map<String, String>? headers;

  /// Optimistic data applied to cache immediately before the network responds.
  final TData? optimisticResponse;

  /// CancelToken for cancelling the request (e.g. via Dio).
  final CancelToken? cancelToken;

  /// Overrides [GraphQLClient.defaultStaleTime] for this request. Governs
  /// how long cached data returned by [FetchPolicy.cacheFirst] is
  /// considered fresh before a background network revalidation is
  /// triggered — an active [GraphQLClient.watchQuery] subscription also
  /// revalidates immediately on attach when the cached value is already
  /// stale.
  final Duration? staleTime;

  /// Overrides [GraphQLClient.defaultCacheTime]. How long this query's
  /// cache entry survives after its last active [GraphQLClient.watchQuery]
  /// subscriber cancels, before being garbage-collected. `null` (the
  /// default) means "never garbage-collect".
  final Duration? cacheTime;

  /// Overrides [GraphQLClient.defaultRetry]. `null` uses the client default
  /// (queries/subscriptions retry automatically, mutations never do); pass
  /// [RetryOptions.none] to disable retry, or a [RetryOptions] to opt a
  /// mutation into retry.
  final RetryOptions? retry;

  /// While this request has an active [GraphQLClient.watchQuery]
  /// subscriber, triggers a background network refetch every
  /// [refetchInterval]. `null` (the default) disables interval polling.
  final Duration? refetchInterval;

  final String? _requestId;

  /// Unique identifier used for cache keying and optimistic-response tracking.
  String get requestId => _requestId ?? identityHashCode(this).toString();

  const GraphQLRequest({
    this.fetchPolicy,
    this.errorPolicy,
    this.headers,
    this.optimisticResponse,
    this.cancelToken,
    this.staleTime,
    this.cacheTime,
    this.retry,
    this.refetchInterval,
    String? requestId,
  }) : _requestId = requestId;

  /// Creates a copy of this request with the given fields replaced.
  GraphQLRequest<TData, TVars> copyWithRequest({
    TVars? variables,
    FetchPolicy? fetchPolicy,
    ErrorPolicy? errorPolicy,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    TData? optimisticResponse,
  });

  /// Convenient helper to copy this request with a new [fetchPolicy].
  GraphQLRequest<TData, TVars> copyWithFetchPolicy(FetchPolicy policy) =>
      copyWithRequest(fetchPolicy: policy);

  /// Convenient helper to copy this request with a new [errorPolicy].
  GraphQLRequest<TData, TVars> copyWithErrorPolicy(ErrorPolicy policy) =>
      copyWithRequest(errorPolicy: policy);
}
