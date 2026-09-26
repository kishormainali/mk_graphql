import 'package:dio/dio.dart';
import 'package:injectable/injectable.dart';

/// One entry in [NetworkActivityMonitor.log] — a single HTTP call that
/// actually left the device, independent of how many [GraphQLClient] calls
/// asked for it. Used by the optimizations demo to make request
/// deduplication and retry-with-backoff visible: e.g. firing 5 concurrent
/// identical queries should still only ever produce one [sent]/[succeeded]
/// pair here.
class NetworkActivityEntry {
  final int id;
  final DateTime time;
  final String operationName;
  final String event; // sent | succeeded | failed (chaos)

  NetworkActivityEntry({
    required this.id,
    required this.time,
    required this.operationName,
    required this.event,
  });
}

/// A [Dio] interceptor that (1) counts every request that actually reaches
/// the network — the ground truth for demonstrating [GraphQLClient]'s
/// request deduplication — and (2) can be told to fail the next N requests
/// for a given operation, to demonstrate [RetryOptions] retry-with-backoff
/// against a real (if synthetic) transient failure.
///
/// This lives at the [Dio] layer rather than as a custom `Link` because
/// `GraphQLClient`'s factory doesn't expose a hook for inserting arbitrary
/// links into its built-in pipeline — intercepting the `Dio` it's handed is
/// the only observation point available from outside the package.
@lazySingleton
class NetworkActivityMonitor extends Interceptor {
  final List<NetworkActivityEntry> log = [];
  int _nextId = 1;

  final _chaosRemaining = <String, int>{};

  final _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  int get totalSent => log.where((e) => e.event == 'sent').length;

  /// The next [count] requests whose GraphQL operationName is
  /// [operationName] will fail with a synthetic [DioException] instead of
  /// reaching the network — simulating a flaky connection so
  /// [RetryOptions]'s retry-with-backoff has something real to recover from.
  void simulateFailures(String operationName, int count) {
    _chaosRemaining[operationName] = count;
  }

  void clear() {
    log.clear();
    _nextId = 1;
    _chaosRemaining.clear();
    _notify();
  }

  String _operationNameOf(RequestOptions options) {
    final body = options.data;
    if (body is Map && body['operationName'] is String) {
      return body['operationName'] as String;
    }
    return 'unknown';
  }

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) {
    final operationName = _operationNameOf(options);
    final id = _nextId++;
    options.extra['activityId'] = id;
    log.add(NetworkActivityEntry(
      id: id,
      time: DateTime.now(),
      operationName: operationName,
      event: 'sent',
    ));
    _notify();

    final remaining = _chaosRemaining[operationName] ?? 0;
    if (remaining > 0) {
      _chaosRemaining[operationName] = remaining - 1;
      log.add(NetworkActivityEntry(
        id: id,
        time: DateTime.now(),
        operationName: operationName,
        event: 'failed (simulated)',
      ));
      _notify();
      handler.reject(
        DioException.connectionError(
          requestOptions: options,
          reason: 'Simulated transient network failure for demo purposes',
        ),
      );
      return;
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final id = response.requestOptions.extra['activityId'];
    log.add(NetworkActivityEntry(
      id: id is int ? id : _nextId++,
      time: DateTime.now(),
      operationName: _operationNameOf(response.requestOptions),
      event: 'succeeded',
    ));
    _notify();
    handler.next(response);
  }
}
