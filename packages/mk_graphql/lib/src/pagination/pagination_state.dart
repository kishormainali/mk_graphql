const Object _undefined = Object();

/// Immutable state holding the current items and status of a paginated query.
class PaginationState<TItem> {
  /// Accumulated list of items across all loaded pages.
  final List<TItem> items;

  /// True when the initial page or a refetch is in flight.
  final bool isLoading;

  /// True when a subsequent page is being fetched.
  final bool isLoadingMore;

  /// True if more pages can be requested.
  final bool hasMore;

  /// The error encountered during the last fetch, or null if none.
  final Object? error;

  const PaginationState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.error,
  });

  /// Whether an error occurred.
  bool get hasError => error != null;

  /// Whether no items are present and not actively loading.
  bool get isEmpty => items.isEmpty && !isLoading;

  /// Whether any items have been loaded.
  bool get isNotEmpty => items.isNotEmpty;

  /// Total number of loaded items.
  int get count => items.length;

  PaginationState<TItem> copyWith({
    List<TItem>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error = _undefined,
  }) {
    return PaginationState<TItem>(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: identical(error, _undefined) ? this.error : error,
    );
  }

  @override
  String toString() =>
      'PaginationState(items: ${items.length}, isLoading: $isLoading, isLoadingMore: $isLoadingMore, hasMore: $hasMore, hasError: $hasError)';
}
