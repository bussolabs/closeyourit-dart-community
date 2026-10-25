import 'package:flutter/widgets.dart';

import '../breadcrumb_throttle.dart';
import '../client.dart';
import '../close_your_it.dart';

/// Wraps the app (or a subtree) and records a synthetic breadcrumb on every
/// pointer interaction (tap), when `captureTapBreadcrumbs` is on.
///
/// **Privacy by design**: it only captures the fact that an interaction happened
/// and the current route ([CloseYourItClient.currentRoute]) — never the tapped
/// widget, its internal type, or the typed text. It does not inspect the tree: it
/// intercepts only `PointerDownEvent` and does not consume it (transparent to
/// gestures). Rapid-fire taps are suppressed by a [BreadcrumbThrottle] (`breadcrumbThrottleMs`).
///
/// Opt-in, no-op if the option is OFF or the client is not initialized.
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [CloseYourItNavigatorObserver()],
///   builder: (context, child) =>
///       CloseYourItUserInteraction(child: child ?? const SizedBox()),
/// )
/// ```
class CloseYourItUserInteraction extends StatefulWidget {
  const CloseYourItUserInteraction({
    super.key,
    required this.child,
    this.client,
    this.nowMs,
  });

  /// Observed subtree (rendered unchanged).
  final Widget child;

  /// Injectable client (tests); otherwise the global client.
  final CloseYourItClient? client;

  /// Injectable clock (tests); otherwise the real clock.
  final int Function()? nowMs;

  @override
  State<CloseYourItUserInteraction> createState() =>
      _CloseYourItUserInteractionState();
}

class _CloseYourItUserInteractionState
    extends State<CloseYourItUserInteraction> {
  BreadcrumbThrottle? _throttle;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      child: widget.child,
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    final client = widget.client ?? CloseYourIt.client;
    if (client == null || !client.options.captureTapBreadcrumbs) return;

    final throttle = _throttle ??=
        BreadcrumbThrottle(minIntervalMs: client.options.breadcrumbThrottleMs);
    final now = (widget.nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();
    if (!throttle.allow(now)) return;

    final route = client.currentRoute;
    client.addBreadcrumb(
      message: 'tap',
      category: 'ui.tap',
      type: 'user',
      data: {if (route != null) 'route': route},
    );
  }
}
