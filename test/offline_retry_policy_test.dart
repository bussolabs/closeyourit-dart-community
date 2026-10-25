import 'package:closeyourit/src/offline_retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OfflineRetryPolicy.backoffFor', () {
    const policy = OfflineRetryPolicy(
      baseDelay: Duration(seconds: 30),
      maxDelay: Duration(hours: 6),
    );

    test('is deterministic: same (id, attempt) → same delay', () {
      // Reproducible jitter (no Random): two invocations match.
      expect(policy.backoffFor('evt-1', 2), policy.backoffFor('evt-1', 2));
      expect(policy.backoffFor('other', 5), policy.backoffFor('other', 5));
    });

    test(
        'falls in the [raw/2, raw] range of the exponential backoff (equal jitter)',
        () {
      for (var attempt = 1; attempt <= 6; attempt++) {
        final rawMs = 30000 * (1 << (attempt - 1)); // 30s * 2^(attempt-1)
        final delayMs = policy.backoffFor('evt', attempt).inMilliseconds;
        expect(delayMs, greaterThanOrEqualTo(rawMs ~/ 2),
            reason: 'attempt $attempt below half of raw');
        expect(delayMs, lessThanOrEqualTo(rawMs),
            reason: 'attempt $attempt above raw');
      }
    });

    test('delays are progressive: they grow with the number of attempts', () {
      final d1 = policy.backoffFor('evt', 1);
      final d3 = policy.backoffFor('evt', 3);
      final d5 = policy.backoffFor('evt', 5);
      expect(d3, greaterThan(d1));
      expect(d5, greaterThan(d3));
    });

    test('the backoff never exceeds maxDelay (predictable cap)', () {
      const maxDelay = Duration(hours: 6);
      for (final attempt in [10, 20, 40, 100]) {
        expect(policy.backoffFor('evt', attempt), lessThanOrEqualTo(maxDelay));
      }
    });

    test('jitter staggers different events at the same attempt', () {
      // Different ids → different fractions → different delays: attempts do not
      // all restart in sync (no burst).
      final delays = {
        for (final id in ['a', 'b', 'c', 'd', 'e'])
          policy.backoffFor(id, 3).inMilliseconds
      };
      expect(delays.length, greaterThan(1));
    });
  });
}
