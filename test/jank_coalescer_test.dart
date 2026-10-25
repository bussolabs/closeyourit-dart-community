import 'package:closeyourit/src/jank_coalescer.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Jank coalescing (CYDA-2).
///
/// A janky scroll produces dozens of over-budget frames in a fraction of a
/// second. Without coalescing each one becomes a POST: the shared queue saturates
/// and starves concurrent errors. [JankCoalescer] aggregates the frames of the
/// same route in a fixed window and emits ONE verdict (count +
/// worst + avg) when the window ends.
void main() {
  group('JankCoalescer', () {
    test('40 frames of a route in a window → a single aggregated rollup', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 1000, onFlush: rollups.add);

        // ~40 consecutive over-budget frames in the same window.
        for (var i = 0; i < 40; i++) {
          coalescer.record(40 + i.toDouble(), 'FeedScreen');
        }
        // Trailing: nothing emitted until the window closes.
        expect(rollups, isEmpty);

        async.elapse(const Duration(milliseconds: 1000));

        expect(rollups.length, 1);
        final rollup = rollups.single;
        expect(rollup.route, 'FeedScreen');
        expect(rollup.frames, 40); // janky frame count
        expect(rollup.worstMs, 79); // the worst frame (40 + 39)
        expect(rollup.avgMs, closeTo(59.5, 0.001)); // average of 40..79
      });
    });

    test('different routes aggregate in separate windows', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 1000, onFlush: rollups.add);

        coalescer.record(50, 'A');
        coalescer.record(60, 'B');
        coalescer.record(70, 'A');

        async.elapse(const Duration(milliseconds: 1000));

        expect(rollups.length, 2);
        final a = rollups.firstWhere((r) => r.route == 'A');
        final b = rollups.firstWhere((r) => r.route == 'B');
        expect(a.frames, 2);
        expect(a.worstMs, 70);
        expect(b.frames, 1);
        expect(b.worstMs, 60);
      });
    });

    test('a new window starts after the previous one closes', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 1000, onFlush: rollups.add);

        coalescer.record(40, 'Feed');
        async.elapse(const Duration(milliseconds: 1000)); // closes window 1
        expect(rollups.length, 1);

        coalescer.record(50, 'Feed'); // opens window 2
        async.elapse(const Duration(milliseconds: 1000));

        expect(rollups.length, 2);
        expect(rollups[1].frames, 1);
        expect(rollups[1].worstMs, 50);
      });
    });

    test('a null route is kept in the rollup', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 500, onFlush: rollups.add);

        coalescer.record(40, null);
        async.elapse(const Duration(milliseconds: 500));

        expect(rollups.single.route, isNull);
        expect(rollups.single.frames, 1);
      });
    });

    test('the window is fixed: late frames do not move the deadline', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 1000, onFlush: rollups.add);

        coalescer.record(40, 'Feed');
        async.elapse(const Duration(milliseconds: 900));
        coalescer.record(50, 'Feed'); // must not extend the window
        async.elapse(const Duration(milliseconds: 100)); // t = 1000 → closes

        expect(rollups.length, 1);
        expect(rollups.single.frames, 2);
      });
    });

    test('flush() emits pending rollups right away and stops the timers', () {
      fakeAsync((async) {
        final rollups = <JankRollup>[];
        final coalescer = JankCoalescer(windowMs: 1000, onFlush: rollups.add);

        coalescer.record(40, 'Feed');
        coalescer.record(60, 'Feed');
        coalescer.flush();

        expect(rollups.length, 1);
        expect(rollups.single.frames, 2);
        expect(rollups.single.worstMs, 60);

        // Timers stopped: no further rollup when they would expire.
        async.elapse(const Duration(minutes: 1));
        expect(rollups.length, 1);
      });
    });

    test('flush() without pending windows is a no-op', () {
      final rollups = <JankRollup>[];
      JankCoalescer(windowMs: 1000, onFlush: rollups.add).flush();
      expect(rollups, isEmpty);
    });
  });
}
