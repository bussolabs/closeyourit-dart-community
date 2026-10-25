import 'dart:async';

import 'events/log_event.dart';

/// Maximum number of logs per single HTTP request to `/logs`.
///
/// Mirrors the backend's `LOGS_MAX_BATCH`: a batch over this limit is
/// rejected with 413. Larger batches must be split into sequential sends.
const int logsMaxBatch = 1000;

/// Log batch buffer. Mirrors `CloseYourIt::LogBuffer`.
///
/// Accumulates [LogEvent]s and flushes them in batches when: it reaches [batchSize],
/// [flushInterval] expires (periodic timer), or on [dispose] (shutdown). The
/// batch is handed to [onFlush], which takes care of sending it.
class LogBuffer {
  LogBuffer({
    required this.onFlush,
    this.batchSize = 50,
    this.flushInterval = const Duration(seconds: 5),
  });

  /// Callback invoked with the batch to send.
  final void Function(List<LogEvent> batch) onFlush;

  /// Number of logs that forces an immediate flush.
  final int batchSize;

  /// Periodic flush interval (≤ 0 = no timer).
  final Duration flushInterval;

  final List<LogEvent> _events = <LogEvent>[];
  Timer? _timer;
  bool _disposed = false;

  /// Number of logs currently buffered.
  int get length => _events.length;

  /// Adds a log; immediate flush when [batchSize] is reached.
  void add(LogEvent event) {
    if (_disposed) return;
    _events.add(event);
    _ensureTimer();
    if (_events.length >= batchSize) flush();
  }

  /// Empties the buffer by handing the batch to [onFlush] (no-op if empty).
  void flush() {
    if (_events.isEmpty) return;
    final batch = List<LogEvent>.of(_events);
    _events.clear();
    onFlush(batch);
  }

  void _ensureTimer() {
    if (_timer != null || flushInterval <= Duration.zero) return;
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Stops the timer and flushes one last time. Afterwards, [add] is a no-op.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    flush();
  }
}
