import 'dart:async';

import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackgroundWorker', () {
    test('runs the task and drops it from pending when done', () async {
      final w = BackgroundWorker(stats: Stats());
      var ran = false;
      expect(w.perform(() async => ran = true), isTrue);
      await w.flush();
      expect(ran, isTrue);
      expect(w.inFlight, 0);
    });

    test('full queue → drop, stats.dropped, returns false', () async {
      final stats = Stats();
      final w = BackgroundWorker(stats: stats, maxQueue: 1);
      final blocker = Completer<void>();

      expect(w.perform(() => blocker.future), isTrue); // takes the only slot
      expect(w.perform(() async {}), isFalse); // dropped
      expect(stats[StatKey.dropped], 1);
      expect(stats.drops(DropReason.queueFull), 1); // structured reason

      blocker.complete();
      await w.flush();
    });

    test('frees the slot when done → accepts again', () async {
      final w = BackgroundWorker(stats: Stats(), maxQueue: 1);
      expect(w.perform(() async {}), isTrue);
      await w.flush();
      expect(w.perform(() async {}), isTrue);
      await w.flush();
    });

    test('a task that throws does NOT propagate and frees the slot', () async {
      final w = BackgroundWorker(stats: Stats(), maxQueue: 1);
      expect(w.perform(() async => throw Exception('boom')), isTrue);
      await w.flush();
      expect(w.inFlight, 0);
      expect(w.perform(() async {}), isTrue); // slot free again
      await w.flush();
    });

    test('flush does not wait past flushTimeout if a send hangs', () async {
      final w = BackgroundWorker(
        stats: Stats(),
        flushTimeout: const Duration(milliseconds: 50),
      );
      final blocker = Completer<void>();
      addTearDown(blocker.complete);

      expect(w.perform(() => blocker.future), isTrue);
      await w.flush(); // must return: without a limit shutdown would never end

      expect(w.inFlight, 1); // the task stays in flight, it is not aborted
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('flush still waits for sends that finish within the limit', () async {
      final w = BackgroundWorker(
        stats: Stats(),
        flushTimeout: const Duration(seconds: 5),
      );
      var ran = false;
      expect(
        w.perform(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          ran = true;
        }),
        isTrue,
      );

      await w.flush();

      expect(ran, isTrue);
      expect(w.inFlight, 0);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
