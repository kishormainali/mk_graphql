/// Exponential backoff delay for [attempt] (`0` = the first attempt, before
/// any failure), starting at [initialDelay] and multiplying by [multiplier]
/// for each subsequent attempt, capped at [maxDelay] so a long-lived
/// failure (a dead server, no network) settles into a fixed, bounded retry
/// cadence instead of growing forever. Shared by [WebSocketLink]'s
/// reconnect scheduling; [RetryOptions] uses its own attempt-counted
/// variant since it isn't capped the same way.
Duration cappedBackoffDelay({
  required int attempt,
  required Duration initialDelay,
  required Duration maxDelay,
  required double multiplier,
}) {
  if (attempt <= 0) {
    return initialDelay < maxDelay ? initialDelay : maxDelay;
  }
  var ms = initialDelay.inMilliseconds.toDouble();
  for (var i = 0; i < attempt; i++) {
    ms *= multiplier;
    if (ms >= maxDelay.inMilliseconds) return maxDelay;
  }
  return Duration(milliseconds: ms.round());
}
