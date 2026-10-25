import 'package:flutter/widgets.dart';

import '../client.dart';
import '../close_your_it.dart';

/// go_router/Navigator observer that records navigation as breadcrumbs and
/// rotates the trace_id on every screen transition (new logical correlation
/// unit): logs/errors/metrics of the same screen thus share the same
/// trace_id — parity with the JS client's "per page". A trace set by hand
/// with `setTraceId` takes precedence and survives navigation.
/// `didRemove` rotates only if it removes the **top** screen (the route
/// below becomes visible → new unit); removing a buried route
/// (e.g. `pushAndRemoveUntil`) does not change screen → no rotation.
///
/// Counterpart of `SentryNavigatorObserver`.
class CloseYourItNavigatorObserver extends NavigatorObserver {
  CloseYourItNavigatorObserver({CloseYourItClient? client})
      : _injected = client;

  final CloseYourItClient? _injected;

  /// Route currently on top of the stack, tracked by identity. [didRemove]
  /// uses it to tell the removal of the current screen (the route below
  /// becomes visible → new logical unit → rotate) from the removal of a
  /// buried route (no screen change → no rotation).
  Route<dynamic>? _current;

  CloseYourItClient? get _client => _injected ?? CloseYourIt.client;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _client?.rotateTraceId();
    _crumb('didPush', route, previousRoute);
    _current = route;
    _client?.currentRoute = route.settings.name;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _client?.rotateTraceId();
    _crumb('didPop', route, previousRoute);
    _current = previousRoute;
    _client?.currentRoute = previousRoute?.settings.name;
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _client?.rotateTraceId();
    _crumb('didReplace', newRoute, oldRoute);
    _current = newRoute;
    _client?.currentRoute = newRoute?.settings.name;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // `didRemove` can also remove the top route (e.g.
    // `Navigator.removeRoute` of the current screen): then `previousRoute`
    // becomes visible again → new logical correlation unit, rotate. Removing
    // a buried route (e.g. `pushAndRemoveUntil`) does not change screen →
    // no rotation. A hand-set trace still wins (rotateTraceId respects
    // it).
    final removedCurrent = identical(route, _current);
    if (removedCurrent) _client?.rotateTraceId();
    _crumb('didRemove', route, previousRoute);
    if (removedCurrent) {
      _current = previousRoute;
      _client?.currentRoute = previousRoute?.settings.name;
    }
    super.didRemove(route, previousRoute);
  }

  void _crumb(String operation, Route<dynamic>? to, Route<dynamic>? from) {
    _client?.addBreadcrumb(
      message: operation,
      category: 'navigation',
      type: 'navigation',
      data: {
        'to': to?.settings.name,
        'from': from?.settings.name,
      },
    );
  }
}
