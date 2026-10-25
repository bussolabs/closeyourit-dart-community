import 'dart:async';

import 'package:flutter/widgets.dart';

import '../client.dart';

/// Observes the app lifecycle. Two independent responsibilities:
///
/// 1. **Background flush** (always on): when the app goes to the background or
///    is terminated (`paused`/`hidden`/`detached`) it forces a flush of the
///    buffered logs, so they are not lost — parity with the gem's `at_exit`.
/// 2. **Lifecycle breadcrumbs** (opt-in, `captureLifecycleBreadcrumbs`): on every
///    state change it records a synthetic breadcrumb (`data.state`), useful to
///    put in context a crash that happened right after a state transition.
///
/// The flag only governs the breadcrumb: the flush happens regardless. Consecutive
/// identical states are deduplicated (no time throttle: transitions are few
/// and each one is meaningful).
class CloseYourItLifecycleObserver with WidgetsBindingObserver {
  CloseYourItLifecycleObserver(this._client);

  final CloseYourItClient _client;

  /// Last observed state, to deduplicate repeated changes.
  AppLifecycleState? _lastState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_client.options.captureLifecycleBreadcrumbs && state != _lastState) {
      _client.addBreadcrumb(
        message: 'lifecycle: ${state.name}',
        category: 'app.lifecycle',
        data: {'state': state.name},
      );
    }
    _lastState = state;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_client.flush());
    }
  }
}
