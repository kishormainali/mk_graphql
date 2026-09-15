import 'auth_token.dart';

/// Interface [GraphQLClient] uses to persist the [AuthToken] it manages on
/// the app's behalf when constructed with `refreshCallback`.
///
/// Defaults to [SecureTokenStorage]; inject a custom implementation (e.g. an
/// in-memory fake) via `GraphQLClient(tokenStorage: ...)` for testing.
abstract class TokenStorage {
  Future<String?> get accessToken;
  Future<String?> get refreshToken;

  /// Emits the new [AuthToken] whenever [save] is called, and `null`
  /// whenever [clear] is called — including a failed refresh being revoked.
  /// Only emits changes made through this instance during the app session;
  /// it does not replay the token already on disk at construction time.
  /// See `GraphQLClient.onAuthTokenChange`.
  Stream<AuthToken?> get onChange;

  /// Persists [token]. Implementations should keep the previous refresh
  /// token when [AuthToken.refreshToken] is null (a refresh response that
  /// only rotates the access token).
  Future<void> save(AuthToken token);

  Future<void> clear();

  /// Releases resources backing [onChange]. Called by [GraphQLClient.dispose].
  Future<void> dispose();
}
