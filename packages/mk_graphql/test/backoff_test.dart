import 'package:flutter_test/flutter_test.dart';
import 'package:mk_graphql/mk_graphql.dart';

void main() {
  group('cappedBackoffDelay', () {
    test('attempt 0 returns initialDelay', () {
      expect(
        cappedBackoffDelay(
          attempt: 0,
          initialDelay: const Duration(seconds: 3),
          maxDelay: const Duration(seconds: 30),
          multiplier: 1.5,
        ),
        const Duration(seconds: 3),
      );
    });

    test('multiplies by multiplier once per attempt', () {
      expect(
        cappedBackoffDelay(
          attempt: 1,
          initialDelay: const Duration(seconds: 3),
          maxDelay: const Duration(seconds: 30),
          multiplier: 1.5,
        ),
        const Duration(milliseconds: 4500),
      );
      expect(
        cappedBackoffDelay(
          attempt: 2,
          initialDelay: const Duration(seconds: 3),
          maxDelay: const Duration(seconds: 30),
          multiplier: 1.5,
        ),
        const Duration(milliseconds: 6750),
      );
    });

    test(
        'clamps at maxDelay so a long outage settles into a bounded retry '
        'cadence instead of growing forever', () {
      final delay = cappedBackoffDelay(
        attempt: 50,
        initialDelay: const Duration(seconds: 3),
        maxDelay: const Duration(seconds: 30),
        multiplier: 1.5,
      );
      expect(delay, const Duration(seconds: 30));
    });

    test('initialDelay already above maxDelay is clamped even at attempt 0',
        () {
      final delay = cappedBackoffDelay(
        attempt: 0,
        initialDelay: const Duration(seconds: 60),
        maxDelay: const Duration(seconds: 30),
        multiplier: 1.5,
      );
      expect(delay, const Duration(seconds: 30));
    });
  });

  group('RetryOptions jitter', () {
    test('jitter: 0.0 (the default) reproduces the exact prior formula', () {
      const options = RetryOptions(
        initialDelay: Duration(milliseconds: 200),
        backoffMultiplier: 2.0,
      );
      expect(options.delayForAttempt(1), const Duration(milliseconds: 200));
      expect(options.delayForAttempt(2), const Duration(milliseconds: 400));
      expect(options.delayForAttempt(3), const Duration(milliseconds: 800));
    });

    test(
        'a positive jitter keeps every sampled delay within the spread '
        'around the base delay, never negative', () {
      const options = RetryOptions(
        initialDelay: Duration(milliseconds: 200),
        backoffMultiplier: 2.0,
        jitter: 0.3,
      );
      // base for attempt 2 is 400ms; jitter: 0.3 spreads it across
      // [400*0.7, 400*1.3] = [280, 520].
      for (var i = 0; i < 200; i++) {
        final delay = options.delayForAttempt(2).inMilliseconds;
        expect(delay, inInclusiveRange(280, 520));
      }
    });

    test('jitter actually varies the delay across samples (not a no-op)', () {
      const options = RetryOptions(
        initialDelay: Duration(milliseconds: 200),
        backoffMultiplier: 2.0,
        jitter: 0.3,
      );
      final samples = {
        for (var i = 0; i < 50; i++) options.delayForAttempt(2).inMilliseconds
      };
      expect(samples.length, greaterThan(1),
          reason: '50 samples should not all land on the exact same '
              'millisecond if jitter is actually randomizing anything');
    });
  });
}
