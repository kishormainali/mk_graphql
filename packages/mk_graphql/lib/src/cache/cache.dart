import 'dart:async';
import '../core/request.dart';

typedef KeyGetter = String? Function(Map<String, dynamic> data);

/// Interface for normalized GraphQL cache implementations.
abstract class Cache {
  TData? readQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void writeQuery<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  );

  Map<String, dynamic>? readFragment({
    required String id,
    required String fragmentName,
  });

  void writeFragment({
    required String id,
    required Map<String, dynamic> data,
  });

  void evict(String key);

  /// Evicts the cached root query record corresponding to [request].
  void evictQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void clear();

  Stream<TData?> watchQuery<TData, TVars>(GraphQLRequest<TData, TVars> request);

  void recordOptimistic<TData, TVars>(
    GraphQLRequest<TData, TVars> request,
    TData data,
  );

  void removeOptimistic(String requestId);
}
