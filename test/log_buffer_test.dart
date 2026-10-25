import 'package:closeyourit/src/events/log_event.dart';
import 'package:closeyourit/src/log_buffer.dart';
import 'package:closeyourit/src/log_level.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

LogEvent _log(String message) => LogEvent(
    message: message, level: LogLevel.info, environment: 'development');

void main() {
  group('LogBuffer', () {
    test('flushes immediately when batchSize is reached', () {
      final batches = <List<LogEvent>>[];
      final buf = LogBuffer(onFlush: batches.add, batchSize: 2);
      buf.add(_log('a'));
      expect(batches, isEmpty);
      buf.add(_log('b')); // reaches 2 → flush
      expect(batches.length, 1);
      expect(batches.single.length, 2);
      expect(buf.length, 0);
    });

    test('flushes periodically when flushInterval expires', () {
      fakeAsync((async) {
        final batches = <List<LogEvent>>[];
        final buf = LogBuffer(
          onFlush: batches.add,
          batchSize: 100,
          flushInterval: const Duration(seconds: 5),
        );
        buf.add(_log('a'));
        async.elapse(const Duration(seconds: 5));
        expect(batches.length, 1);
        expect(batches.single.single.message, 'a');
        buf.dispose();
      });
    });

    test('an empty flush is a no-op', () {
      final batches = <List<LogEvent>>[];
      LogBuffer(onFlush: batches.add).flush();
      expect(batches, isEmpty);
    });

    test('dispose flushes the rest and stops the timer', () {
      fakeAsync((async) {
        final batches = <List<LogEvent>>[];
        final buf = LogBuffer(onFlush: batches.add, batchSize: 100)
          ..add(_log('a'));
        buf.dispose();
        expect(batches.length, 1); // remainder flushed
        buf.add(_log('b')); // after dispose → no-op
        async.elapse(const Duration(minutes: 1));
        expect(batches.length, 1); // no further flush
      });
    });
  });
}
