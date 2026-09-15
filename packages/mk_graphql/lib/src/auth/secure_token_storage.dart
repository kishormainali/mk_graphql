import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_token.dart';
import 'token_storage.dart';

/// [TokenStorage] backed by [FlutterSecureStorage] (Keychain on iOS/macOS,
/// Keystore-backed EncryptedSharedPreferences on Android).
///
/// [onChange] is driven by [FlutterSecureStorage]'s own `registerListener`
/// (fires on every `write`/`delete` made through this [_storage] instance,
/// including ones not routed through [save]/[clear]) rather than a
/// hand-rolled notification in [save]/[clear].
class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage({
    FlutterSecureStorage? storage,
    String keyPrefix = 'mk_graphql',
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _accessKey = '${keyPrefix}_access_token',
        _refreshKey = '${keyPrefix}_refresh_token' {
    _storage.registerListener(
      key: _accessKey,
      listener: _onAccessTokenChanged,
    );
  }

  final FlutterSecureStorage _storage;
  final String _accessKey;
  final String _refreshKey;
  final _changes = StreamController<AuthToken?>.broadcast();

  @override
  Future<String?> get accessToken => _storage.read(key: _accessKey);

  @override
  Future<String?> get refreshToken => _storage.read(key: _refreshKey);

  @override
  Stream<AuthToken?> get onChange => _changes.stream;

  // The access token is the "are we logged in" signal, so only its listener
  // is wired to `onChange`. [refreshToken] is read back here rather than
  // threaded through, relying on the write ordering in [save] below so it's
  // already up to date by the time this fires.
  void _onAccessTokenChanged(String? value) {
    if (value == null) {
      if (!_changes.isClosed) _changes.add(null);
      return;
    }
    // Async gap: [dispose] may close `_changes` before this resolves.
    refreshToken.then((rt) {
      if (!_changes.isClosed) {
        _changes.add(AuthToken(accessToken: value, refreshToken: rt));
      }
    });
  }

  @override
  Future<void> save(AuthToken token) async {
    // Write the refresh token first so the accessToken-change listener
    // (triggered by the write below) reads it back up to date.
    if (token.refreshToken != null) {
      await _storage.write(key: _refreshKey, value: token.refreshToken);
    }
    await _storage.write(key: _accessKey, value: token.accessToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }

  @override
  Future<void> dispose() async {
    _storage.unregisterListener(
      key: _accessKey,
      listener: _onAccessTokenChanged,
    );
    await _changes.close();
  }
}
