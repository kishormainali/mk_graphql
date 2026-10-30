import 'dart:async';

/// Lifecycle of a subscription transport (WebSocket or SSE).
enum SubscriptionConnectionStatus {
  /// Opening the first connection.
  connecting,

  /// Connection is up (WebSocket `connection_ack` received / SSE stream open).
  connected,

  /// The connection dropped and a retry is pending or in flight.
  reconnecting,

  /// No connection and none wanted (nothing subscribed, or disposed).
  disconnected,

  /// The connection failed and is not being retried, or retries were
  /// exhausted. Stays until the next successful connect.
  error,
}

/// Snapshot of a subscription connection.
class SubscriptionConnectionState {
  final SubscriptionConnectionStatus status;

  /// The most recent failure. Kept through `connecting` / `reconnecting` /
  /// `error` and cleared only when the connection reaches `connected`.
  final Object? lastError;

  /// Consecutive reconnect attempts since the last successful connect.
  final int attempt;

  const SubscriptionConnectionState(
    this.status, {
    this.lastError,
    this.attempt = 0,
  });

  static const disconnected = SubscriptionConnectionState(
    SubscriptionConnectionStatus.disconnected,
  );

  @override
  bool operator ==(Object other) =>
      other is SubscriptionConnectionState &&
      other.status == status &&
      other.lastError == lastError &&
      other.attempt == attempt;

  @override
  int get hashCode => Object.hash(status, lastError, attempt);

  @override
  String toString() =>
      'SubscriptionConnectionState($status, attempt: $attempt, '
      'lastError: $lastError)';
}

/// Implemented by links that can report their connection status.
abstract interface class ConnectionStatusSource {
  ConnectionStatusNotifier get connectionStatus;
}

/// Holds the current [SubscriptionConnectionState] and broadcasts changes.
///
/// Each reporter passes itself (or any unique key) as `source`; the exposed
/// [value] aggregates all sources, which lets a transport with one connection
/// per subscription report as a single connection.
class ConnectionStatusNotifier {
  final _sources =
      <Object, ({SubscriptionConnectionStatus status, int attempt})>{};
  final _controller = StreamController<SubscriptionConnectionState>.broadcast();
  Object? _lastError;
  bool _closed = false;

  SubscriptionConnectionState _value = SubscriptionConnectionState.disconnected;

  SubscriptionConnectionState get value => _value;

  /// Emits on every change. Does not replay — read [value] for the current one.
  Stream<SubscriptionConnectionState> get stream => _controller.stream;

  void report(
    Object source,
    SubscriptionConnectionStatus status, {
    Object? error,
  }) {
    if (_closed) return;
    final prev = _sources[source];
    final attempt = status == SubscriptionConnectionStatus.reconnecting
        ? (prev?.status == SubscriptionConnectionStatus.reconnecting
                  ? prev!.attempt
                  : 0) +
              1
        : 0;
    _sources[source] = (status: status, attempt: attempt);
    if (error != null) _lastError = error;
    _recompute();
  }

  void release(Object source) {
    if (_closed || _sources.remove(source) == null) return;
    _recompute();
  }

  Future<void> close() {
    _closed = true;
    return _controller.close();
  }

  void _recompute() {
    final all = _sources.values;
    bool any(SubscriptionConnectionStatus s) => all.any((e) => e.status == s);
    final status = any(SubscriptionConnectionStatus.connected)
        ? SubscriptionConnectionStatus.connected
        : any(SubscriptionConnectionStatus.reconnecting)
        ? SubscriptionConnectionStatus.reconnecting
        : any(SubscriptionConnectionStatus.connecting)
        ? SubscriptionConnectionStatus.connecting
        : any(SubscriptionConnectionStatus.error)
        ? SubscriptionConnectionStatus.error
        : SubscriptionConnectionStatus.disconnected;
    if (status == SubscriptionConnectionStatus.connected) _lastError = null;
    final attempt = all
        .where((e) => e.status == SubscriptionConnectionStatus.reconnecting)
        .fold(0, (m, e) => e.attempt > m ? e.attempt : m);
    final next = SubscriptionConnectionState(
      status,
      lastError: _lastError,
      attempt: attempt,
    );
    if (next == _value) return;
    _value = next;
    _controller.add(next);
  }
}
