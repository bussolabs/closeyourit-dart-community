import 'package:closeyourit/src/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Stats', () {
    test('starts from zero on every key', () {
      final s = Stats();
      for (final k in StatKey.values) {
        expect(s[k], 0);
      }
    });

    test('increment + operator[]', () {
      final s = Stats()
        ..increment(StatKey.sent)
        ..increment(StatKey.sent)
        ..increment(StatKey.dropped);
      expect(s[StatKey.sent], 2);
      expect(s[StatKey.dropped], 1);
    });

    test('toMap uses the key names', () {
      final s = Stats()..increment(StatKey.enqueued);
      expect(s.toMap(), {
        'enqueued': 1,
        'dropped': 0,
        'sent': 0,
        'failed': 0,
        'persisted': 0,
        'replayed': 0,
        'discarded': 0,
      });
    });

    test('reset clears everything', () {
      final s = Stats()
        ..increment(StatKey.sent)
        ..increment(StatKey.failed)
        ..recordDrop(DropReason.sampled)
        ..reset();
      expect(s.toMap().values.every((v) => v == 0), isTrue);
      expect(s.drops(DropReason.sampled), 0);
    });
  });

  group('Stats.recordDrop (structured reasons)', () {
    test('starts from zero on every reason', () {
      final s = Stats();
      for (final r in DropReason.values) {
        expect(s.drops(r), 0);
      }
    });

    test('counts the reason and aggregates its associated StatKey counter', () {
      final s = Stats()
        ..recordDrop(DropReason.queueFull)
        ..recordDrop(DropReason.permanentReject)
        ..recordDrop(DropReason.maxAttempts)
        ..recordDrop(DropReason.tooLarge)
        ..recordDrop(DropReason.timeout);
      // Granular reasons.
      expect(s.drops(DropReason.queueFull), 1);
      expect(s.drops(DropReason.permanentReject), 1);
      expect(s.drops(DropReason.maxAttempts), 1);
      expect(s.drops(DropReason.tooLarge), 1);
      expect(s.drops(DropReason.timeout), 1);
      // Backward-compatible StatKey aggregates.
      expect(s[StatKey.dropped], 1); // queueFull
      expect(
          s[StatKey.discarded], 3); // permanentReject + maxAttempts + tooLarge
      expect(s[StatKey.failed], 1); // timeout
    });

    test(
        'a reason without an aggregate StatKey does not touch the flow counters',
        () {
      final s = Stats()
        ..recordDrop(DropReason.sampled)
        ..recordDrop(DropReason.beforeSend)
        ..recordDrop(DropReason.expired);
      expect(s.drops(DropReason.sampled), 1);
      expect(s.drops(DropReason.beforeSend), 1);
      expect(s.drops(DropReason.expired), 1);
      // No flow counter altered.
      expect(s.toMap().values.every((v) => v == 0), isTrue);
    });
  });

  group('Stats.snapshot (immutable)', () {
    test('exposes counts and reasons with typed lookup', () {
      final s = Stats()
        ..increment(StatKey.sent)
        ..recordDrop(DropReason.sampled)
        ..recordDrop(DropReason.sampled);
      final snap = s.snapshot();
      expect(snap[StatKey.sent], 1);
      expect(snap.reason(DropReason.sampled), 2);
    });

    test('is a picture: it does not reflect later increments', () {
      final s = Stats()..increment(StatKey.sent);
      final snap = s.snapshot();
      s
        ..increment(StatKey.sent)
        ..recordDrop(DropReason.sampled);
      expect(snap[StatKey.sent], 1);
      expect(snap.reason(DropReason.sampled), 0);
    });

    test('the exposed maps are read-only', () {
      final snap = (Stats()..increment(StatKey.sent)).snapshot();
      expect(() => snap.counts[StatKey.sent] = 9, throwsUnsupportedError);
      expect(
          () => snap.reasons[DropReason.sampled] = 9, throwsUnsupportedError);
    });

    test('toMap serializes the flat counts and only the non-zero reasons', () {
      final s = Stats()
        ..increment(StatKey.sent)
        ..recordDrop(DropReason.sampled);
      final map = s.snapshot().toMap();
      expect(map['sent'], 1);
      expect(map['enqueued'], 0);
      expect(map['reasons'], {'sampled': 1});
    });

    test('without reasons, toMap does not include the reasons section', () {
      final map = (Stats()..increment(StatKey.sent)).snapshot().toMap();
      expect(map.containsKey('reasons'), isFalse);
    });
  });

  group('Stats diagnostic callback', () {
    test('reports increment as a flow signal', () {
      final events = <DiagnosticEvent>[];
      Stats(onEvent: events.add).increment(StatKey.sent);
      expect(events.single.stat, StatKey.sent);
      expect(events.single.reason, isNull);
      expect(events.single.isDrop, isFalse);
    });

    test('reports recordDrop as a drop signal with the reason', () {
      final events = <DiagnosticEvent>[];
      Stats(onEvent: events.add).recordDrop(DropReason.queueFull);
      expect(events.single.reason, DropReason.queueFull);
      expect(events.single.stat, isNull);
      expect(events.single.isDrop, isTrue);
    });

    test('a callback that throws does not propagate (never crashes the host)',
        () {
      final s = Stats(onEvent: (_) => throw StateError('boom'));
      expect(() => s.increment(StatKey.sent), returnsNormally);
      expect(() => s.recordDrop(DropReason.sampled), returnsNormally);
      // Counters stay consistent despite the failed callback.
      expect(s[StatKey.sent], 1);
      expect(s.drops(DropReason.sampled), 1);
    });

    test('a callback that generates telemetry does not recurse forever', () {
      late Stats s;
      var calls = 0;
      s = Stats(onEvent: (_) {
        calls++;
        // Simulates a capturing callback: it would try to re-notify.
        if (calls < 1000) s.increment(StatKey.sent);
      });
      s.increment(StatKey.sent);
      // The reentrant notification is suppressed: a single callback invocation…
      expect(calls, 1);
      // …but the counters still reflect the increments that happened.
      expect(s[StatKey.sent], 2);
    });
  });
}
