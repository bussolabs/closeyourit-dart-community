import 'package:closeyourit/src/usage_registry.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsageRegistry — recording', () {
    test('a symbol seen once ends up in the flush with count 1', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'checkout.coupon')
        ..flush();

      final symbol = flushes.single.symbols.single;
      expect(symbol.kind, 'custom');
      expect(symbol.symbol, 'checkout.coupon');
      expect(symbol.count, 1);
    });

    test(
        'the same symbol seen several times stays one row with a cumulative count',
        () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'checkout.coupon')
        ..record('custom', 'checkout.coupon')
        ..record('custom', 'checkout.coupon')
        ..flush();

      expect(flushes.single.symbols.length, 1);
      expect(flushes.single.symbols.single.count, 3);
    });

    test('kind and symbol together form the key: same name, different kinds',
        () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'Checkout')
        ..record('route', 'Checkout')
        ..flush();

      expect(flushes.single.symbols.length, 2);
      expect(flushes.single.symbols.map((s) => s.kind),
          containsAll(<String>['custom', 'route']));
    });

    test('last_seen_at is the last time the symbol was seen', () {
      final flushes = <UsageFlush>[];
      var now = DateTime.utc(2026, 9, 1, 10);
      final registry = UsageRegistry(onFlush: flushes.add, clock: () => now)
        ..record('custom', 'rare.branch');
      now = DateTime.utc(2026, 9, 1, 10, 5);
      registry
        ..record('custom', 'rare.branch')
        ..flush();

      expect(flushes.single.symbols.single.lastSeenAt,
          DateTime.utc(2026, 9, 1, 10, 5));
    });
  });

  group('UsageRegistry — symbol contract', () {
    test('a kind outside the contract is dropped without throwing', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('screen', 'Checkout')
        ..flush();

      expect(flushes, isEmpty);
    });

    test('a symbol with malformed characters is dropped', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        // space and "?" are not allowed: they would let in queries and free text
        ..record('custom', 'checkout?user=7')
        ..record('custom', 'key with spaces')
        ..record('custom', '')
        ..flush();

      expect(flushes, isEmpty);
    });

    test('a symbol over 200 characters is dropped', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'a' * 201)
        ..flush();

      expect(flushes, isEmpty);
    });

    test('accepts the three contract kinds', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'a')
        ..record('route', 'b')
        ..record('job', 'c')
        ..flush();

      expect(flushes.single.symbols.length, 3);
    });
  });

  group('UsageRegistry — cap and truncation', () {
    test('beyond maxSymbols new symbols are dropped and the flush is truncated',
        () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add, maxSymbols: 2)
        ..record('custom', 'a')
        ..record('custom', 'b')
        ..record('custom', 'c')
        ..flush();

      expect(flushes.single.symbols.length, 2);
      expect(flushes.single.truncated, isTrue);
    });

    test('beyond the cap ALREADY known symbols keep counting', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add, maxSymbols: 1)
        ..record('custom', 'a')
        ..record('custom', 'b') // dropped: cap reached
        ..record('custom', 'a') // already known: counts
        ..flush();

      expect(flushes.single.symbols.single.count, 2);
      expect(flushes.single.truncated, isTrue);
    });

    test('maxSymbols does not exceed the backend cap per flush', () {
      final registry =
          UsageRegistry(onFlush: (_) {}, maxSymbols: usageMaxBatch + 5000);
      expect(registry.maxSymbols, usageMaxBatch);
    });

    test('a flush without symbols still goes out if it carries truncated', () {
      final flushes = <UsageFlush>[];
      UsageRegistry(onFlush: flushes.add, maxSymbols: 0)
        ..record('custom', 'a')
        ..flush();

      expect(flushes.single.symbols, isEmpty);
      expect(flushes.single.truncated, isTrue,
          reason:
              'the flag disqualifies the kind on the scanner side: it must not be lost');
    });
  });

  group('UsageRegistry — window', () {
    test('the registry empties on every flush', () {
      final flushes = <UsageFlush>[];
      final registry = UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'a')
        ..flush();
      expect(registry.length, 0);

      registry.flush(); // nothing to send: no second flush
      expect(flushes.length, 1);
    });

    test('the count restarts from zero in the next window', () {
      final flushes = <UsageFlush>[];
      final registry = UsageRegistry(onFlush: flushes.add)
        ..record('custom', 'a')
        ..record('custom', 'a')
        ..flush();
      registry
        ..record('custom', 'a')
        ..flush();

      expect(flushes.first.symbols.single.count, 2);
      expect(flushes.last.symbols.single.count, 1);
    });

    test('truncated resets with the window', () {
      final flushes = <UsageFlush>[];
      final registry = UsageRegistry(onFlush: flushes.add, maxSymbols: 1)
        ..record('custom', 'a')
        ..record('custom', 'b')
        ..flush();
      registry
        ..record('custom', 'c')
        ..flush();

      expect(flushes.first.truncated, isTrue);
      expect(flushes.last.truncated, isFalse);
    });

    test('the declared window spans from the end of the previous one to now',
        () {
      final flushes = <UsageFlush>[];
      var now = DateTime.utc(2026, 9, 1, 10);
      final registry = UsageRegistry(onFlush: flushes.add, clock: () => now)
        ..record('custom', 'a');
      now = DateTime.utc(2026, 9, 1, 10, 5);
      registry.flush();
      now = DateTime.utc(2026, 9, 1, 10, 9);
      registry
        ..record('custom', 'b')
        ..flush();

      expect(flushes.first.windowStartedAt, DateTime.utc(2026, 9, 1, 10));
      expect(flushes.first.windowEndedAt, DateTime.utc(2026, 9, 1, 10, 5));
      expect(flushes.last.windowStartedAt, DateTime.utc(2026, 9, 1, 10, 5));
      expect(flushes.last.windowEndedAt, DateTime.utc(2026, 9, 1, 10, 9));
    });
  });

  group('UsageRegistry — timer and shutdown', () {
    test('periodic flush when flushInterval expires', () {
      fakeAsync((async) {
        final flushes = <UsageFlush>[];
        final registry = UsageRegistry(
          onFlush: flushes.add,
          flushInterval: const Duration(minutes: 5),
        )..record('custom', 'a');

        expect(flushes, isEmpty);
        async.elapse(const Duration(minutes: 5));
        expect(flushes.length, 1);
        registry.dispose();
      });
    });

    test('without records the timer does not start', () {
      fakeAsync((async) {
        final flushes = <UsageFlush>[];
        final registry = UsageRegistry(
          onFlush: flushes.add,
          flushInterval: const Duration(minutes: 5),
        );
        async.elapse(const Duration(hours: 1));
        expect(flushes, isEmpty);
        registry.dispose();
      });
    });

    test('zero (or negative) flushInterval → no periodic timer', () {
      fakeAsync((async) {
        final flushes = <UsageFlush>[];
        UsageRegistry(onFlush: flushes.add, flushInterval: Duration.zero)
            .record('custom', 'a');
        async.elapse(const Duration(hours: 1));
        expect(flushes, isEmpty);
      });
    });

    test('dispose sends the remainder and stops the timer', () {
      fakeAsync((async) {
        final flushes = <UsageFlush>[];
        final registry = UsageRegistry(
          onFlush: flushes.add,
          flushInterval: const Duration(minutes: 5),
        )..record('custom', 'a');

        registry.dispose();
        expect(flushes.length, 1); // remainder flushed

        registry.record('custom', 'b'); // after dispose → no-op
        async.elapse(const Duration(hours: 1));
        expect(flushes.length, 1);
      });
    });

    test('an onFlush that throws neither propagates nor kills the timer', () {
      fakeAsync((async) {
        var calls = 0;
        final registry = UsageRegistry(
          onFlush: (_) {
            calls += 1;
            throw StateError('backend down');
          },
          flushInterval: const Duration(minutes: 5),
        )..record('custom', 'a');

        async.elapse(const Duration(minutes: 5));
        expect(calls, 1);

        registry.record('custom', 'b');
        async.elapse(const Duration(minutes: 5));
        expect(calls, 2, reason: 'the timer must survive the failure');
        registry.dispose();
      });
    });
  });

  group('UsageSymbol — payload', () {
    test('serializes kind, symbol, count and last_seen_at in UTC ISO 8601', () {
      final json = UsageSymbol(
        kind: 'route',
        symbol: 'CheckoutScreen',
        count: 4,
        lastSeenAt: DateTime.utc(2026, 9, 1, 10, 5),
      ).toJson();

      expect(json, <String, Object?>{
        'kind': 'route',
        'symbol': 'CheckoutScreen',
        'count': 4,
        'last_seen_at': '2026-09-01T10:05:00.000Z',
      });
    });
  });
}
