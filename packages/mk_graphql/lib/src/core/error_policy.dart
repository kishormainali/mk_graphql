/// Defines how GraphQL field errors are handled during request execution.
enum ErrorPolicy {
  /// Strict: If any error (GraphQL errors or network exception) occurs,
  /// execution fails immediately and throws, discarding partial data.
  none,

  /// Ignore: All GraphQL field-level errors are ignored. If data is present,
  /// it is returned without throwing. If data is null, the error throws.
  ignore,

  /// All: Both data and errors are preserved. If data is present, it is
  /// returned without throwing, while errors remain accessible on raw responses.
  all,
}
