import 'dart:math';

import 'error.dart';

/// Configures automatic retry-with-backoff for a query (and, when explicitly
/// set on the request, a mutation or subscription) on transient network
/// failures.
class RetryOptions {
  /// Total attempts including the first — `1` means "no retry".
  final int maxAttempts;

  /// Delay before the first retry (attempt 2). Subsequent retries multiply
  /// this by [backoffMultiplier] for each additional attempt.
  final Duration initialDelay;

  final double backoffMultiplier;

  /// Randomizes each computed delay by up to this fraction (`0.0`–`1.0`) in
  /// either direction, so many clients that failed at the same moment (e.g.
  /// a shared server blip) don't all retry in lockstep and re-cause the
  /// spike that failed them the first time. `0.0` (the default) disables
  /// jitter — the exact backoff curve prior versions produced.
  final double jitter;

  /// Overrides the default transient-failure classification. Receives the
  /// mapped [GraphQLException] (via [GraphQLExceptionExtension]) for the
  /// failed attempt.
  final bool Function(Object error)? retryIf;

  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.backoffMultiplier = 2.0,
    this.jitter = 0.0,
    this.retryIf,
  }) : assert(jitter >= 0.0 && jitter <= 1.0, 'jitter must be within 0.0–1.0');

  /// A single attempt, no retry — pass this to a request to opt a query out
  /// of the client's `defaultRetry`.
  static const RetryOptions none = RetryOptions(maxAttempts: 1);

  static final Random _random = Random();

  bool shouldRetry(Object error) {
    if (retryIf != null) return retryIf!(error);
    return error is NetworkException || error is TimeoutException;
  }

  Duration delayForAttempt(int attempt) {
    final base = _baseDelayForAttempt(attempt);
    if (jitter <= 0.0) return base;

    // Spread uniformly across [base * (1 - jitter), base * (1 + jitter)]
    // rather than only ever shortening or only ever lengthening the delay,
    // so jitter doesn't skew the average backoff curve.
    final spread = base.inMilliseconds * jitter;
    final offsetMs = (spread * (_random.nextDouble() * 2 - 1)).round();
    final jitteredMs = base.inMilliseconds + offsetMs;
    return Duration(milliseconds: jitteredMs < 0 ? 0 : jitteredMs);
  }

  Duration _baseDelayForAttempt(int attempt) {
    if (attempt <= 1) return initialDelay;
    var multiplier = 1.0;
    for (var i = 1; i < attempt; i++) {
      multiplier *= backoffMultiplier;
    }
    return Duration(
        milliseconds: (initialDelay.inMilliseconds * multiplier).round());
  }
}
