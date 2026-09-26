import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';
import 'package:mk_graphql/mk_graphql.dart';

import '../features/optimizations/network_activity_monitor.dart';

@module
abstract class NetworkModule {
  @lazySingleton
  Dio provideDio(NetworkActivityMonitor activityMonitor) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    // Observes/instruments the wire, for the optimizations demo — has no
    // effect on requests it doesn't need to fail (see NetworkActivityMonitor).
    dio.interceptors.add(activityMonitor);
    return dio;
  }

  /// Async because [HiveCache.open] is async — [GraphQLClient.create] awaits
  /// it directly, so the client and its persistent cache come up together
  /// before anything else in the app can touch either.
  @preResolve
  Future<GraphQLClient> provideGraphQLClient(Dio dio) {
    return GraphQLClient.create(
      url: 'https://graphql.anilist.co',
      dio: dio,
      defaultHeaders: const {
        'Referer': 'https://anilist.co/graphiql',
        'Origin': 'https://anilist.co',
      },
      cache: HiveCache.open(boxName: 'anilist_gql_cache'),
      defaultFetchPolicy: FetchPolicy.cacheFirst,
      // 30s fresh window: short enough to see a background revalidation
      // fire in the demo without waiting long, long enough that rapid
      // re-navigation between the list and details pages doesn't spam the
      // API. Override per-request via GraphQLRequest.staleTime.
      defaultStaleTime: const Duration(seconds: 30),
      // Cached results survive 2 minutes after their last watcher cancels
      // before being evicted — long enough to demo cacheTime-driven GC by
      // waiting on the Optimizations page rather than tuning it down to
      // something unrealistically short.
      defaultCacheTime: const Duration(minutes: 2),
      // Every query retries transient failures by default (3 attempts,
      // 200ms initial backoff) — matches TanStack Query's default and gives
      // the "simulate flaky network" demo something real to recover from.
      defaultRetry: const RetryOptions(),
      loggerOptions: const LoggerOptions(
        requestHeader: false,
        responseHeader: false,
        useAnsiColors: false,
      ),
    );
  }
}
