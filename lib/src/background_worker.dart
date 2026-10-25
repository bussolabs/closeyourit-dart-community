import 'dart:async';

import 'stats.dart';

/// Fire-and-forget executor for sends.
///
/// Mirrors `CloseYourIt::BackgroundWorker`: Dart needs no thread pool
/// (I/O is asynchronous), it is enough not to await the task. Caps in-flight
/// sends at [maxQueue]; beyond that, it drops (never backpressure on the app).
/// Never throws.
class BackgroundWorker {
  BackgroundWorker({
    required this.stats,
    this.maxQueue = 30,
    this.flushTimeout = const Duration(seconds: 10),
  });

  final Stats stats;
  final int maxQueue;

  /// Maximum time [flush] waits for in-flight sends. It guarantees that
  /// shutdown ends: a send that never finishes (hung network, response
  /// never completed) would otherwise block [flush] — and with it the client's
  /// `close()` — forever. Sends that are no longer awaited are neither aborted
  /// nor counted as dropped: they carry on, and persisted events stay on
  /// disk until confirmed (replayed on the next start).
  final Duration flushTimeout;

  final Set<Future<void>> _pending = <Future<void>>{};

  /// Number of sends currently in flight.
  int get inFlight => _pending.length;

  /// Enqueues [task]. Returns `true` if accepted, `false` if dropped (queue full).
  bool perform(Future<void> Function() task) {
    if (_pending.length >= maxQueue) {
      // Structured reason: in-flight queue full. Aggregates StatKey.dropped.
      stats.recordDrop(DropReason.queueFull);
      return false;
    }
    late final Future<void> future;
    future = Future<void>(() async {
      try {
        await task();
      } on Object {
        // Silent telemetry: never propagate.
      } finally {
        _pending.remove(future);
      }
    });
    _pending.add(future);
    return true;
  }

  /// Waits for in-flight sends to complete, for at most [flushTimeout].
  /// It returns even with sends still running once the limit is exceeded: this
  /// guarantees that `flush()` and `close()` always end.
  Future<void> flush() async {
    final elapsed = Stopwatch()..start();
    while (_pending.isNotEmpty) {
      final remaining = flushTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) return;
      try {
        await Future.wait(_pending.toList()).timeout(remaining);
      } on TimeoutException {
        return;
      }
    }
  }
}
