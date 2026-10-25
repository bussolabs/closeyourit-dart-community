import 'dart:async';

/// Jank aggregate of a route over a window: how many frames exceeded the
/// budget, the worst and the average. Produced by [JankCoalescer] when the window ends.
class JankRollup {
  const JankRollup({
    required this.route,
    required this.frames,
    required this.worstMs,
    required this.avgMs,
  });

  /// Route/screen the jank is attributed to (may be `null`).
  final String? route;

  /// Number of over-budget frames merged into the verdict.
  final int frames;

  /// Duration of the window's worst frame (ms).
  final double worstMs;

  /// Average frame duration in the window (ms).
  final double avgMs;
}

/// Coalesces `jank` verdicts in the SDK instead of emitting one per frame.
///
/// A janky scroll produces dozens of over-budget frames in a fraction of a
/// second: without coalescing each one becomes a POST that saturates the shared
/// queue and starves concurrent errors (CYDA-2). Here the frames of the same route
/// within a fixed [windowMs] window merge into a single [JankRollup]
/// (count + worst + avg), emitted via [onFlush] when the window expires —
/// mirrors the Ruby-side Rollup.
///
/// The window is **fixed** (it starts at the first frame, not sliding): at most one
/// verdict per route every [windowMs]. Nothing is enqueued during the window,
/// so the queue stays free for errors/logs. Deterministic under
/// `fakeAsync` (no real clock read: only [Timer]).
class JankCoalescer {
  JankCoalescer({required this.windowMs, required this.onFlush});

  /// Width of the aggregation window (ms).
  final int windowMs;

  /// Callback invoked with the aggregated verdict when the window ends.
  final void Function(JankRollup rollup) onFlush;

  /// Open windows per route. The key is the route itself (`null` included:
  /// Dart allows a `null` key), so no sentinel in the source.
  final Map<String?, _JankWindow> _windows = <String?, _JankWindow>{};

  /// Records an over-budget frame [frameMs] for [route]. Opens the window on the
  /// first frame; later frames within the window merge into it.
  void record(double frameMs, String? route) {
    final open = _windows[route];
    if (open == null) {
      final window = _JankWindow(route: route, firstMs: frameMs);
      window.timer =
          Timer(Duration(milliseconds: windowMs), () => _flushKey(route));
      _windows[route] = window;
    } else {
      open.add(frameMs);
    }
  }

  /// Emits all pending rollups right away and stops the timers (client
  /// flush/shutdown). A no-op without pending windows.
  void flush() {
    for (final route in _windows.keys.toList()) {
      _flushKey(route);
    }
  }

  void _flushKey(String? route) {
    final window = _windows.remove(route);
    if (window == null) return;
    window.timer?.cancel();
    onFlush(
      JankRollup(
        route: window.route,
        frames: window.frames,
        worstMs: window.worstMs,
        avgMs: window.sumMs / window.frames,
      ),
    );
  }
}

/// Mutable state of an ongoing jank window.
class _JankWindow {
  _JankWindow({required this.route, required double firstMs})
      : worstMs = firstMs,
        sumMs = firstMs;

  final String? route;
  int frames = 1;
  double worstMs;
  double sumMs;
  Timer? timer;

  void add(double frameMs) {
    frames += 1;
    sumMs += frameMs;
    if (frameMs > worstMs) worstMs = frameMs;
  }
}
