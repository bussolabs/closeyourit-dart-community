import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../client.dart';
import '../close_your_it.dart';

/// Network connectivity type, synthetic and stable — the only data recorded
/// in the network breadcrumb. Decouples the public API from the
/// `connectivity_plus` types (as `DeviceContexts` does with `device_info_plus`).
enum CloseYourItConnectivity {
  wifi('wifi'),
  cellular('cellular'),
  ethernet('ethernet'),
  vpn('vpn'),
  bluetooth('bluetooth'),
  other('other'),
  none('none'),
  unknown('unknown');

  const CloseYourItConnectivity(this.label);

  /// Stable label used in the breadcrumb (`data.connectivity`).
  final String label;
}

/// Reduces the list of active `connectivity_plus` transports to a single
/// primary type, by priority (wifi > ethernet > cellular > vpn > bluetooth > none).
/// The list is empty only in abnormal cases (→ [CloseYourItConnectivity.unknown]);
/// `none` always appears alone (no network).
CloseYourItConnectivity mapConnectivityResults(List<ConnectivityResult> r) {
  if (r.isEmpty) return CloseYourItConnectivity.unknown;
  if (r.contains(ConnectivityResult.wifi)) return CloseYourItConnectivity.wifi;
  if (r.contains(ConnectivityResult.ethernet)) {
    return CloseYourItConnectivity.ethernet;
  }
  if (r.contains(ConnectivityResult.mobile)) {
    return CloseYourItConnectivity.cellular;
  }
  if (r.contains(ConnectivityResult.vpn)) return CloseYourItConnectivity.vpn;
  if (r.contains(ConnectivityResult.bluetooth)) {
    return CloseYourItConnectivity.bluetooth;
  }
  if (r.contains(ConnectivityResult.none)) return CloseYourItConnectivity.none;
  return CloseYourItConnectivity.other;
}

/// Source of connectivity changes — injectable in tests (plugins do not
/// run there) and replaceable by those who do not use `connectivity_plus`.
abstract class ConnectivitySource {
  /// Stream of connectivity changes (already reduced to the primary type).
  Stream<CloseYourItConnectivity> get onChange;

  /// Current state, for the initial breadcrumb. Best-effort: if the plugin is
  /// unavailable or throws (permissions/platform) it returns
  /// [CloseYourItConnectivity.unknown], never an exception.
  Future<CloseYourItConnectivity> current();
}

/// Real source based on `connectivity_plus`. Every plugin call is
/// best-effort: `MissingPluginException` (plugin unavailable) or
/// `PlatformException` (permissions) never escape — the client's no-op philosophy.
class PluginConnectivitySource implements ConnectivitySource {
  PluginConnectivitySource([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<CloseYourItConnectivity> get onChange =>
      _connectivity.onConnectivityChanged.map(mapConnectivityResults);

  @override
  Future<CloseYourItConnectivity> current() async {
    try {
      return mapConnectivityResults(await _connectivity.checkConnectivity());
    } on Object {
      return CloseYourItConnectivity.unknown;
    }
  }
}

/// Records a synthetic breadcrumb on every network connectivity change
/// (`wifi`/`cellular`/`none`…). Only the network **type** — never SSID, IP or
/// other data. Installed by `CloseYourIt.init` when
/// `captureConnectivityBreadcrumbs` is on.
///
/// Noise control with a **leading+trailing** debounce (`breadcrumbThrottleMs`
/// window, same mechanics as the jank coalescer): the first change is recorded
/// right away (leading, immediate responsiveness), later toggles within the
/// window are suppressed but **remembered**, and when the window expires the
/// settled state is emitted (trailing) if it differs from the last one — so a
/// network that keeps flapping does not saturate the ring buffer, yet the
/// breadcrumb never stays on a stale state. Identical states are deduplicated.
/// `breadcrumbThrottleMs = 0` disables the debounce (every distinct change passes).
///
/// No-op if breadcrumbs or the option are disabled.
class CloseYourItConnectivityObserver {
  CloseYourItConnectivityObserver({
    CloseYourItClient? client,
    ConnectivitySource? source,
  })  : _injected = client,
        _source = source ?? PluginConnectivitySource();

  final CloseYourItClient? _injected;
  final ConnectivitySource _source;

  StreamSubscription<CloseYourItConnectivity>? _subscription;

  /// Debounce window opened after an emission: during it changes are
  /// accumulated in [_pending] instead of emitted. `null` = idle.
  Timer? _window;

  /// Last network type actually recorded in a breadcrumb.
  CloseYourItConnectivity? _lastEmitted;

  /// Most recent change observed while a window is open, awaiting
  /// (trailing) emission when it expires; `null` if there is none.
  CloseYourItConnectivity? _pending;

  CloseYourItClient? get _client => _injected ?? CloseYourIt.client;

  /// Subscribes to connectivity changes and also emits the initial state
  /// breadcrumb. No-op if `captureConnectivityBreadcrumbs` is OFF or the client
  /// is missing. A stream error (permissions/plugin) is swallowed.
  void install() {
    final client = _client;
    if (client == null || !client.options.captureConnectivityBreadcrumbs) {
      return;
    }
    _subscription = _source.onChange.listen(_handle, onError: (Object _) {});
    unawaited(_seedInitial());
  }

  /// Closes the subscription and stops the pending debounce.
  Future<void> dispose() async {
    _window?.cancel();
    _window = null;
    _pending = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Emits the initial state breadcrumb — but **only** if no real event has
  /// been recorded yet. `current()` (plugin) is asynchronous and can complete
  /// after the stream has already observed a change: in that case the initial
  /// state is stale and must be ignored, so it is not recorded out of order as
  /// if it were the latest.
  Future<void> _seedInitial() async {
    final initial = await _source.current();
    if (_lastEmitted != null || _window != null) return;
    _handle(initial);
  }

  void _handle(CloseYourItConnectivity status) {
    final client = _client;
    if (client == null || !client.options.captureConnectivityBreadcrumbs) {
      return;
    }
    final throttleMs = client.options.breadcrumbThrottleMs;
    if (throttleMs <= 0) {
      if (status != _lastEmitted) _emit(client, status);
      return;
    }
    if (_window != null) {
      _pending = status; // window open: keep the most recent state
      return;
    }
    if (status == _lastEmitted) return; // dedup while idle
    _emit(client, status); // leading
    _openWindow(client, throttleMs);
  }

  void _openWindow(CloseYourItClient client, int throttleMs) {
    _window =
        Timer(Duration(milliseconds: throttleMs), () => _closeWindow(client));
  }

  void _closeWindow(CloseYourItClient client) {
    _window = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && pending != _lastEmitted) {
      _emit(client, pending); // trailing: the settled state after flapping
      _openWindow(client, client.options.breadcrumbThrottleMs);
    }
  }

  void _emit(CloseYourItClient client, CloseYourItConnectivity status) {
    _lastEmitted = status;
    client.addBreadcrumb(
      message: 'connectivity: ${status.label}',
      category: 'device.connectivity',
      data: {'connectivity': status.label},
    );
  }
}
