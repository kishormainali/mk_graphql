import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  // TokenStorage.i lazily constructs a SharedPreferencesAsync on first use.
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();

  late List<String?> notified;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    notified = [];
    TokenStorage.i.setTokenListener(notified.add);
  });

  tearDown(() => TokenStorage.i.removeTokenListener());

  group('saveToken', () {
    test('notifies listeners with the new access token', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));

      expect(notified, equals(['a1']));
    });

    test('stamps createdAt and updatedAt with the same instant', () async {
      final before = DateTime.now();
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));
      final after = DateTime.now();

      final stored = (await TokenStorage.i.getToken())!;
      expect(stored.createdAt, isNotNull);
      expect(stored.updatedAt, equals(stored.createdAt));
      expect(stored.createdAt!.isBefore(before), isFalse);
      expect(stored.createdAt!.isAfter(after), isFalse);
    });

    test('keeps caller-supplied timestamps', () async {
      final created = DateTime.utc(2026, 1, 1);
      final updated = DateTime.utc(2026, 2, 1);
      await TokenStorage.i.saveToken(TokenPair(
        accessToken: 'a1',
        refreshToken: 'r1',
        createdAt: created,
        updatedAt: updated,
      ));

      final stored = (await TokenStorage.i.getToken())!;
      expect(stored.createdAt, equals(created));
      expect(stored.updatedAt, equals(updated));
    });
  });

  group('updateToken (silent refresh)', () {
    test('does not notify listeners', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));
      notified.clear();

      await TokenStorage.i
          .updateToken(const TokenPair(accessToken: 'a2', refreshToken: 'r2'));

      expect(notified, isEmpty);
    });

    test('persists the new tokens so the next read sees them', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));

      await TokenStorage.i
          .updateToken(const TokenPair(accessToken: 'a2', refreshToken: 'r2'));

      expect(await TokenStorage.i.accessToken, equals('a2'));
      expect(await TokenStorage.i.refreshToken, equals('r2'));
    });

    test('preserves createdAt and advances updatedAt', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));
      final first = (await TokenStorage.i.getToken())!;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await TokenStorage.i
          .updateToken(const TokenPair(accessToken: 'a2', refreshToken: 'r2'));
      final second = (await TokenStorage.i.getToken())!;

      expect(second.createdAt, equals(first.createdAt));
      expect(second.updatedAt!.isAfter(first.updatedAt!), isTrue);
    });
  });

  group('deleteToken', () {
    test('notifies listeners with null', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));
      notified.clear();

      await TokenStorage.i.deleteToken();

      expect(notified, equals([null]));
    });

    test('clears the tokens and both timestamps', () async {
      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));

      await TokenStorage.i.deleteToken();

      expect(await TokenStorage.i.getToken(), isNull);
      // A fresh session after logout must not inherit the old createdAt.
      await TokenStorage.i
          .updateToken(const TokenPair(accessToken: 'a2', refreshToken: 'r2'));
      final stored = (await TokenStorage.i.getToken())!;
      expect(stored.createdAt, equals(stored.updatedAt));
    });
  });

  group('listeners', () {
    test('removeTokenListener stops notifications', () async {
      TokenStorage.i.removeTokenListener();

      await TokenStorage.i
          .saveToken(const TokenPair(accessToken: 'a1', refreshToken: 'r1'));
      await TokenStorage.i.deleteToken();

      expect(notified, isEmpty);
    });
  });

  group('sessions stored before timestamps existed', () {
    test('load with null createdAt/updatedAt', () async {
      FlutterSecureStorage.setMockInitialValues({
        '__access_token__': 'legacy-access',
        '__refresh_token_key__': 'legacy-refresh',
      });

      final stored = (await TokenStorage.i.getToken())!;

      expect(stored.accessToken, equals('legacy-access'));
      expect(stored.refreshToken, equals('legacy-refresh'));
      expect(stored.createdAt, isNull);
      expect(stored.updatedAt, isNull);
    });

    test('updateToken backfills createdAt from the refresh time', () async {
      FlutterSecureStorage.setMockInitialValues({
        '__access_token__': 'legacy-access',
        '__refresh_token_key__': 'legacy-refresh',
      });

      await TokenStorage.i
          .updateToken(const TokenPair(accessToken: 'a2', refreshToken: 'r2'));

      final stored = (await TokenStorage.i.getToken())!;
      expect(stored.createdAt, isNotNull);
      expect(stored.updatedAt, equals(stored.createdAt));
      expect(notified, isEmpty);
    });
  });
}
