/// Minimum-interval (leading-edge) throttle for high-frequency automatic
/// breadcrumbs (connectivity, taps): allows at most one event every
/// [minIntervalMs]. The first event passes; later ones within the window are
/// suppressed, until one arrives past the window.
///
/// Pure and deterministic: the clock is passed by the caller ([allow]) → testable
/// without async, like [RebuildWindow]/[JankCoalescer]. `minIntervalMs <= 0`
/// disables the throttle (every event passes).
class BreadcrumbThrottle {
  BreadcrumbThrottle({required this.minIntervalMs});

  /// Minimum interval (ms) between two allowed events. `<= 0` = no throttle.
  final int minIntervalMs;

  int? _lastMs;

  /// `true` if an event at [nowMs] is allowed (updating the internal state);
  /// `false` if it falls within [minIntervalMs] of the last allowed one.
  bool allow(int nowMs) {
    if (minIntervalMs <= 0) return true;
    final last = _lastMs;
    if (last != null && nowMs - last < minIntervalMs) return false;
    _lastMs = nowMs;
    return true;
  }
}
