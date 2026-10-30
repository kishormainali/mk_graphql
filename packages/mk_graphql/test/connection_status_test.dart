import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';

void main() {
  group('ConnectionStatusNotifier', () {
    late ConnectionStatusNotifier n;
    final a = Object();
    final b = Object();
    setUp(() => n = ConnectionStatusNotifier());

    test('starts disconnected', () {
      expect(n.value, SubscriptionConnectionState.disconnected);
    });

    test('reconnecting counts attempts and keeps error', () {
      n.report(a, SubscriptionConnectionStatus.reconnecting, error: 'x');
      n.report(a, SubscriptionConnectionStatus.reconnecting, error: 'x');
      expect(n.value.attempt, 2);
      expect(n.value.lastError, 'x');
      n.report(a, SubscriptionConnectionStatus.connecting);
      expect(n.value.lastError, 'x');
      expect(n.value.attempt, 0);
    });

    test('connected clears lastError', () {
      n.report(a, SubscriptionConnectionStatus.error, error: 'x');
      n.report(a, SubscriptionConnectionStatus.connected);
      expect(n.value.lastError, isNull);
      expect(n.value.status, SubscriptionConnectionStatus.connected);
    });

    test('error is sticky through connecting', () {
      n.report(a, SubscriptionConnectionStatus.error, error: 'e');
      n.report(a, SubscriptionConnectionStatus.connecting);
      expect(n.value.status, SubscriptionConnectionStatus.connecting);
      expect(n.value.lastError, 'e');
    });

    test('aggregates across sources', () {
      n.report(a, SubscriptionConnectionStatus.connected);
      n.report(b, SubscriptionConnectionStatus.error, error: 'e');
      expect(n.value.status, SubscriptionConnectionStatus.connected);
      n.release(a);
      expect(n.value.status, SubscriptionConnectionStatus.error);
      n.release(b);
      expect(n.value.status, SubscriptionConnectionStatus.disconnected);
    });

    test('stream emits only changes', () async {
      final seen = <SubscriptionConnectionStatus>[];
      n.stream.listen((s) => seen.add(s.status));
      n.report(a, SubscriptionConnectionStatus.connecting);
      n.report(a, SubscriptionConnectionStatus.connecting);
      n.report(a, SubscriptionConnectionStatus.connected);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        SubscriptionConnectionStatus.connecting,
        SubscriptionConnectionStatus.connected,
      ]);
    });

    test('close ends stream and ignores later reports', () async {
      final done = n.stream.drain<void>();
      await n.close();
      n.report(a, SubscriptionConnectionStatus.connected);
      n.release(a);
      await done;
      expect(n.value.status, SubscriptionConnectionStatus.disconnected);
    });
  });
}
