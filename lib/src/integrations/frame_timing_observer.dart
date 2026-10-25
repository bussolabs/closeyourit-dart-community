import 'package:flutter/scheduler.dart';

import '../client.dart';

/// Observes frame timings (`SchedulerBinding.addTimingsCallback`) and emits a
/// `jank` verdict when a frame exceeds the budget. Attributed by `currentRoute`.
///
/// Installed by `CloseYourIt.init` when `detectPerformanceIssues && detectJank`.
/// `client.recordJank` applies the threshold; here only the total duration is forwarded.
class CloseYourItFrameTimingObserver {
  CloseYourItFrameTimingObserver(this._client);

  final CloseYourItClient _client;
  TimingsCallback? _callback;

  /// Registers the callback on the binding (no-op if detection is OFF).
  void install() {
    final o = _client.options;
    if (!o.detectPerformanceIssues || !o.detectJank) return;
    final cb = _onTimings;
    _callback = cb;
    SchedulerBinding.instance.addTimingsCallback(cb);
  }

  /// Removes the callback.
  void dispose() {
    final cb = _callback;
    if (cb != null) {
      SchedulerBinding.instance.removeTimingsCallback(cb);
      _callback = null;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      handleFrame(timing.totalSpan.inMicroseconds / 1000.0);
    }
  }

  /// Forwards a frame duration (ms) to the client (testable in isolation).
  void handleFrame(double frameMs) {
    _client.recordJank(frameMs: frameMs);
  }
}
