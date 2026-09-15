import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TokenStorage {
  TokenStorage._();

  static TokenStorage _instance = TokenStorage._();
  static TokenStorage get i => _instance;

  static const String _accessTokenKey = '__access_token__';
  static const String _refreshTokenKey = '__refresh_token_key__';

  final String _hasRunBeforeKey = '_has_run_before';

  final FlutterSecureStorage _storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
        synchronizable: false,
      ),
      aOptions: AndroidOptions());

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  void setTokenListener(void Function(String?) listener) {
    return _storage.registerListener(key: _accessTokenKey, listener: listener);
  }

  void removeTokenListener() {
    return _storage.unregisterAllListenersForKey(key: _accessTokenKey);
  }

  Future<TokenPair?> getToken() async {
    final [accessToken, refreshToken] = await Future.wait([
      _storage.read(key: _accessTokenKey),
      _storage.read(key: _refreshTokenKey)
    ]);
    if (accessToken.emptyOrNull) return Future.value(null);
    return TokenPair(accessToken: accessToken!, refreshToken: refreshToken);
  }

  Future<String?> get accessToken async {
    final token = await getToken();
    return token?.accessToken;
  }

  Future<String?> get refreshToken async {
    final token = await getToken();
    return token?.refreshToken;
  }

  Future<void> saveToken(TokenPair pair) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: pair.accessToken),
      _storage.write(key: _refreshTokenKey, value: pair.refreshToken)
    ]);
  }

  Future<void> deleteToken() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
    ]);
  }

  void clearOnInstall() async {
    final _hasRunBefore = await _prefs.getBool(_hasRunBeforeKey) ?? false;
    if (!_hasRunBefore) {
      _storage.deleteAll();
      await _prefs.setBool(_hasRunBeforeKey, true);
    }
  }
}

extension on String? {
  bool get emptyOrNull => this == null || this!.isEmpty;
}
