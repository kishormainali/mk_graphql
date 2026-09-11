/// Controls how [GraphQLClient] handles reading from cache vs querying network.
enum FetchPolicy {
  /// Return cache first if available, otherwise fetch from network.
  cacheFirst,

  /// Bypass cache and fetch directly from network.
  networkOnly,

  /// Read strictly from cache. If not found in cache, returns null data.
  cacheOnly,

  /// Emit cache first if available, then perform a network request and emit fresh data.
  cacheAndNetwork,

  /// Fetch from network without updating or reading the cache.
  noCache,
}
