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

  /// Overrides the default transient-failure classification. Receives the
  /// mapped [GraphQLException] (via [GraphQLExceptionExtension]) for the
  /// failed attempt.
  final bool Function(Object error)? retryIf;

  const RetryOptions({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.backoffMultiplier = 2.0,
    this.retryIf,
  });

  /// A single attempt, no retry — pass this to a request to opt a query out
  /// of the client's `defaultRetry`.
  static const RetryOptions none = RetryOptions(maxAttempts: 1);

  bool shouldRetry(Object error) {
    if (retryIf != null) return retryIf!(error);
    return error is NetworkException || error is TimeoutException;
  }

  Duration delayForAttempt(int attempt) {
    if (attempt <= 1) return initialDelay;
    var multiplier = 1.0;
    for (var i = 1; i < attempt; i++) {
      multiplier *= backoffMultiplier;
    }
    return Duration(
        milliseconds: (initialDelay.inMilliseconds * multiplier).round());
  }
}
