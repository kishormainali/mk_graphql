/// Configuration options for logging GraphQL operations.
class LoggerOptions {
  const LoggerOptions({
    this.authHeader = false,
    this.requestBody = true,
    this.requestHeader = false,
    this.responseBody = true,
    this.responseHeader = false,
    this.error = true,
    this.redact = true,
    this.useAnsiColors = false,
  });

  /// Whether to output ANSI color codes in console logs.
  /// Defaults to `false` so console output does not show escape artifacts like `\^[[34m`.
  final bool useAnsiColors;

  /// Whether to log authentication headers (e.g. `Authorization`).
  final bool authHeader;

  /// Whether to log request bodies (GraphQL query document and variables).
  final bool requestBody;

  /// Whether to log outgoing request headers.
  final bool requestHeader;

  /// Whether to log response data payloads.
  final bool responseBody;

  /// Whether to log incoming response headers.
  final bool responseHeader;

  /// Whether to log GraphQL and transport errors.
  final bool error;

  /// Whether to redact sensitive keys (passwords, tokens) in log output.
  final bool redact;
}
