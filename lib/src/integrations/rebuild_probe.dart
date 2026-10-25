import 'package:flutter/widgets.dart';

import '../client.dart';
import '../close_your_it.dart';

/// Rebuild sliding window: records timestamps and tells when the widget has
/// been rebuilt [threshold] times within [windowMs]. Pure and deterministic
/// (clock injected by the caller) → testable without widgets or async.
class RebuildWindow {
  RebuildWindow({required this.threshold, required this.windowMs});

  final int threshold;
  final int windowMs;
  final List<int> _hits = <int>[];

  /// Records a rebuild at [nowMs]; `true` if it reaches the threshold within the window.
  bool hit(int nowMs) {
    final cutoff = nowMs - windowMs;
    _hits
      ..removeWhere((t) => t < cutoff)
      ..add(nowMs);
    return _hits.length == threshold;
  }
}

/// Opt-in probe: wraps a subtree and counts its own rebuilds in a sliding
/// window. On the N-th rebuild within the window it emits a `rebuild_storm`
/// verdict (widget rebuilt too many times = wasted frames).
///
/// Per-widget opt-in: Flutter exposes no global rebuild count, so you
/// instrument where needed. No-op if detection is OFF. Transparent: renders [child].
///
/// ```dart
/// CloseYourItRebuildProbe(label: 'ProductCard', child: ProductCard(...))
/// ```
class CloseYourItRebuildProbe extends StatefulWidget {
  const CloseYourItRebuildProbe({
    super.key,
    required this.label,
    required this.child,
    this.client,
    this.nowMs,
  });

  /// Widget identifier in the verdict (backend grouping by `source`).
  final String label;

  /// Observed subtree (rendered unchanged).
  final Widget child;

  /// Injectable client (tests); otherwise the global client.
  final CloseYourItClient? client;

  /// Injectable clock (tests); otherwise the real clock.
  final int Function()? nowMs;

  @override
  State<CloseYourItRebuildProbe> createState() =>
      _CloseYourItRebuildProbeState();
}

class _CloseYourItRebuildProbeState extends State<CloseYourItRebuildProbe> {
  RebuildWindow? _window;

  @override
  Widget build(BuildContext context) {
    _track();
    return widget.child;
  }

  void _track() {
    final client = widget.client ?? CloseYourIt.client;
    if (client == null || !client.options.detectPerformanceIssues) return;

    final window = _window ??= RebuildWindow(
      threshold: client.options.rebuildStormThreshold,
      windowMs: client.options.rebuildStormWindowMs,
    );
    final now = (widget.nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();

    if (window.hit(now)) {
      client.recordRebuildStorm(
        widget: widget.label,
        count: client.options.rebuildStormThreshold,
        windowMs: client.options.rebuildStormWindowMs.toDouble(),
      );
    }
  }
}
