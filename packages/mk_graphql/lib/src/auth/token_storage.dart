import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistent, secure storage for the session's [TokenPair], shared by every
/// [GraphQLClient] in the app through the [i] singleton.
///
/// Tokens (and their timestamps) live in the platform keychain/keystore via
/// `flutter_secure_storage`; a `shared_preferences` flag backs
/// [clearOnInstall]. [GraphQLClient] reads and writes it on its own when
/// `refreshCallback` is configured — the app only touches it directly to log
/// in ([saveToken]), log out ([deleteToken]) or observe the session
/// ([setTokenListener], [getToken]).
///
/// ## Which write notifies listeners
///
/// | Call | Use it for | Listeners |
/// |---|---|---|
/// | [saveToken] | login / a brand-new session | called with the access token |
/// | [updateToken] | a token refresh | **not** called (silent) |
/// | [deleteToken] | logout / revoke | called with `null` |
///
/// The split exists so a refresh doesn't look like an auth-state change to an
/// app that rebuilds routing from [setTokenListener].
class TokenStorage {
  TokenStorage._();

  static TokenStorage _instance = TokenStorage._();

  /// The app-wide instance. All [GraphQLClient]s use this one.
  static TokenStorage get i => _instance;

  static const String _accessTokenKey = '__access_token__';
  static const String _refreshTokenKey = '__refresh_token_key__';
  static const String _createdAtKey = '__token_created_at__';
  static const String _updatedAtKey = '__token_updated_at__';

  final String _hasRunBeforeKey = '_has_run_before';

  final FlutterSecureStorage _storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        synchronizable: false,
      ),
      aOptions: AndroidOptions());

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  // Kept here rather than on FlutterSecureStorage's own key listeners, which
  // fire on every write to the key — that would make a silent refresh
  // (see [updateToken]) impossible.
  final List<void Function(String?)> _listeners = [];

  /// Registers [listener] to be called with the new access token when a
  /// session is saved via [saveToken], and with `null` when it is cleared via
  /// [deleteToken]. Not called on a silent refresh ([updateToken]).
  void setTokenListener(void Function(String?) listener) {
    _listeners.add(listener);
  }

  /// Removes every listener registered with [setTokenListener].
  void removeTokenListener() {
    _listeners.clear();
  }

  void _notify(String? accessToken) {
    for (final listener in List.of(_listeners)) {
      listener(accessToken);
    }
  }

  /// Reads the stored session, or `null` when there is no (non-empty) access
  /// token — i.e. nobody is logged in.
  ///
  /// `createdAt`/`updatedAt` are `null` for a session stored before
  /// timestamps were tracked (until its next refresh backfills them).
  Future<TokenPair?> getToken() async {
    final [accessToken, refreshToken, createdAt, updatedAt] =
        await Future.wait([
      _storage.read(key: _accessTokenKey),
      _storage.read(key: _refreshTokenKey),
      _storage.read(key: _createdAtKey),
      _storage.read(key: _updatedAtKey),
    ]);
    if (accessToken.emptyOrNull) return Future.value(null);
    return TokenPair(
      accessToken: accessToken!,
      refreshToken: refreshToken,
      createdAt: _parseTime(createdAt),
      updatedAt: _parseTime(updatedAt),
    );
  }

  /// The stored access token, or `null` when logged out. Read on every
  /// request, so a token written by [updateToken] is picked up immediately.
  Future<String?> get accessToken async {
    final token = await getToken();
    return token?.accessToken;
  }

  /// The stored refresh token, or `null` when logged out or when the session
  /// has none.
  Future<String?> get refreshToken async {
    final token = await getToken();
    return token?.refreshToken;
  }

  /// Persists a freshly issued session (e.g. on login) and notifies token
  /// listeners. Timestamps default to now.
  Future<void> saveToken(TokenPair pair) async {
    final createdAt = pair.createdAt ?? DateTime.now();
    await _write(pair,
        createdAt: createdAt, updatedAt: pair.updatedAt ?? createdAt);
    _notify(pair.accessToken);
  }

  /// Silently persists a refreshed [pair] — token listeners are NOT notified,
  /// so an app reacting to them (e.g. rebuilding routing) isn't disturbed by
  /// a refresh. The next request simply reads the new tokens from storage.
  ///
  /// Keeps the stored `createdAt` (falling back to now for sessions stored
  /// before timestamps existed) and stamps `updatedAt` with the current time.
  Future<void> updateToken(TokenPair pair) async {
    final now = DateTime.now();
    final storedCreatedAt = _parseTime(await _storage.read(key: _createdAtKey));
    await _write(
      pair,
      createdAt: pair.createdAt ?? storedCreatedAt ?? now,
      updatedAt: pair.updatedAt ?? now,
    );
  }

  Future<void> _write(
    TokenPair pair, {
    required DateTime createdAt,
    required DateTime updatedAt,
  }) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: pair.accessToken),
      _storage.write(key: _refreshTokenKey, value: pair.refreshToken),
      _storage.write(
          key: _createdAtKey, value: createdAt.toUtc().toIso8601String()),
      _storage.write(
          key: _updatedAtKey, value: updatedAt.toUtc().toIso8601String()),
    ]);
  }

  /// Clears the stored session and notifies token listeners with `null`.
  Future<void> deleteToken() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _createdAtKey),
      _storage.delete(key: _updatedAtKey),
    ]);
    _notify(null);
  }

  /// Wipes stored credentials on the first launch after a (re)install.
  ///
  /// iOS keeps keychain items across an uninstall, so a reinstalled app could
  /// otherwise start "logged in" with a stale session. Call it once at
  /// startup, before the first request; it does nothing after the first run,
  /// and — unlike [deleteToken] — never notifies listeners.
  void clearOnInstall() async {
    final _hasRunBefore = await _prefs.getBool(_hasRunBeforeKey) ?? false;
    if (!_hasRunBefore) {
      _storage.deleteAll();
      await _prefs.setBool(_hasRunBeforeKey, true);
    }
  }
}

DateTime? _parseTime(String? value) =>
    value == null ? null : DateTime.tryParse(value);

extension on String? {
  bool get emptyOrNull => this == null || this!.isEmpty;
}
