import 'dart:async';

import 'package:flutter/widgets.dart';

import 'client.dart';
import 'configuration.dart';
import 'integrations/connectivity_observer.dart';
import 'integrations/device_context.dart';
import 'integrations/flutter_error_integration.dart';
import 'integrations/frame_timing_observer.dart';
import 'integrations/isolate_error_integration.dart';
import 'integrations/lifecycle_observer.dart';
import 'integrations/offline_store_provider.dart';
import 'log_level.dart';
import 'logger.dart';
import 'offline_store.dart';
import 'scope.dart';
import 'stats.dart';

/// Static façade of the CloseYourIt client — the public entry point.
///
/// Mirrors the module methods of `CloseYourIt` (gem). Every method is a
/// no-op until [init] is called; none of them throws.
abstract final class CloseYourIt {
  CloseYourIt._();

  static CloseYourItClient? _client;
  static void Function()? _disposeErrorHandlers;
  static void Function()? _disposeIsolateHandler;
  static Object? _isolateErrorPort;
  static CloseYourItLifecycleObserver? _lifecycleObserver;
  static CloseYourItFrameTimingObserver? _frameObserver;
  static CloseYourItConnectivityObserver? _connectivityObserver;

  /// The active client, or `null` if not initialized (advanced use/tests).
  static CloseYourItClient? get client => _client;

  /// `SendPort` to pass as `onError` to `Isolate.spawn` to route the crashes
  /// of spawned isolates to CloseYourIt (persisted like the other
  /// errors). It is typed `Object?` to stay web-safe (no `dart:isolate`
  /// in the façade): on the native target cast it to `SendPort`. `null` on web or
  /// without installed integrations.
  ///
  /// ```dart
  /// final port = CloseYourIt.isolateErrorPort;
  /// if (port is SendPort) {
  ///   await Isolate.spawn(worker, message, onError: port);
  /// }
  /// ```
  static Object? get isolateErrorPort => _isolateErrorPort;

  /// `true` if initialized and the configuration allows sending.
  static bool get isEnabled => _client?.options.isEnabled ?? false;

  /// Initializes the client with [options].
  ///
  /// If [installIntegrations] is `true` (default), installs the global handlers
  /// for unhandled errors (`FlutterError`/`PlatformDispatcher`) and the lifecycle
  /// observer (background log flush).
  ///
  /// If [appRunner] is provided, the app is started inside a guarded zone that
  /// also captures unhandled asynchronous errors. [client] allows
  /// injection in tests; [offlineStore] allows injecting the persistent
  /// queue (by default, with `persistOffline`, it is created via path_provider).
  static Future<void> init(
    CloseYourItOptions options, {
    FutureOr<void> Function()? appRunner,
    CloseYourItClient? client,
    bool installIntegrations = true,
    DeviceContextProvider? deviceContextProvider,
    OfflineStore? offlineStore,
  }) async {
    // Re-init = safe close of the previous client + new initialization (DoD
    // CYDA-12). Without this, a second init would install a second set of
    // error handlers/lifecycle observers/frame callbacks (every error captured
    // twice) and would orphan the old client, its transport and its
    // observers. For equivalent options the effect is idempotent (a single client,
    // a single set of integrations); for different options it is a reconfiguration.
    if (_client != null) {
      await close();
    }

    // Shared Stats: hooks the user diagnostic callback and acts as the sink for
    // the offline store's internal drops (TTL/eviction/corrupted records), so
    // diagnostics cover transport, worker and store (CYDA-13). Only when we create
    // the client ourselves: an injected client (tests) already carries its own Stats.
    final stats = client == null ? Stats(onEvent: options.onDiagnostic) : null;

    // Offline queue: injected (tests) or created by default via path_provider.
    // Only when no custom client is passed (it already has its store) and
    // persistence is enabled. On web/pure tests createDefault returns null → the
    // client keeps working without persistence.
    var store = offlineStore;
    if (client == null &&
        store == null &&
        options.persistOffline &&
        installIntegrations) {
      // Pass the current endpoint as the reference authority: the queue drops
      // records bound for other hosts (no telemetry redirection).
      final host = options.endpointHost;
      store = await createDefaultOfflineStore(
        maxEvents: options.maxPersistedEvents,
        endpoint: host != null && host.isNotEmpty ? options.eventsUri : null,
        onDrop: stats!.recordDrop,
      );
    }

    final instance =
        client ?? CloseYourItClient(options, store: store, stats: stats);
    _client = instance;

    // Without this warning a misconfiguration (e.g. missing token/projectId) makes the SDK
    // a completely silent no-op. No warning when disabling is intended (enabled: false).
    if (!options.isEnabled && options.enabled) {
      debugPrint(
        '[closeyourit] SDK disabled: ${options.disabledReason} — no event will be sent',
      );
    }

    if (installIntegrations) {
      _disposeErrorHandlers = installErrorHandlers(instance);
      // Backstop for unhandled errors of the current (root) isolate that
      // escape FlutterError/PlatformDispatcher; `isolateErrorPort` covers
      // spawned isolates by passing it as `onError` to Isolate.spawn.
      final isolateHandle = installIsolateErrorHandler(instance);
      _disposeIsolateHandler = isolateHandle.dispose;
      _isolateErrorPort = isolateHandle.errorPort;
      _installLifecycle(instance);
      _installFrameObserver(instance);
      _installConnectivity(instance);
      if (options.collectDeviceContext) {
        // Before appRunner: the first captured error already has device/OS/app.
        await installDeviceContext(instance, provider: deviceContextProvider);
      }
    }

    // Picks up and sends the events persisted by previous boots (crash/offline):
    // after the transport is ready, but without delaying the app start (CYDA-31).
    _scheduleReplay(instance, hasUi: installIntegrations);

    if (appRunner != null) {
      runZonedGuarded(
        () => appRunner(),
        (error, stack) => instance.captureException(error, stackTrace: stack),
      );
    }
  }

  /// Runs [CloseYourItClient.replayPending] once the app has shown its first
  /// frame, so reading the leftover queue never delays the first screen
  /// (CYDA-31). Without a UI — integrations off, binding not initialized, no
  /// view (pure tests, headless) — or once the first frame is already on screen
  /// (re-init), it runs right away as before. A client closed in the meantime
  /// skips it ([CloseYourItClient.replayPending] is a no-op after close).
  static void _scheduleReplay(CloseYourItClient instance,
      {required bool hasUi}) {
    if (hasUi) {
      try {
        final firstFrame = _firstFrameRasterized();
        if (firstFrame != null) {
          unawaited(firstFrame.then((_) {
            try {
              instance.replayPending();
            } on Object {
              // Telemetry never surfaces errors to the app.
            }
          }));
          return;
        }
      } on Object {
        // Binding not initialized (e.g. pure tests): replay right away.
      }
    }
    instance.replayPending();
  }

  /// Future completing when the first frame is on screen, or `null` when there
  /// is nothing to wait for (no view, or first frame already shown). Throws if
  /// the binding is not initialized.
  static Future<void>? _firstFrameRasterized() {
    final binding = WidgetsBinding.instance;
    if (binding.platformDispatcher.implicitView == null ||
        binding.firstFrameRasterized) {
      return null;
    }
    return binding.waitUntilFirstFrameRasterized;
  }

  static void _installLifecycle(CloseYourItClient instance) {
    try {
      final observer = CloseYourItLifecycleObserver(instance);
      WidgetsBinding.instance.addObserver(observer);
      _lifecycleObserver = observer;
    } on Object {
      // Binding not initialized (e.g. pure tests): lifecycle skipped.
    }
  }

  static void _installFrameObserver(CloseYourItClient instance) {
    try {
      final observer = CloseYourItFrameTimingObserver(instance)..install();
      _frameObserver = observer;
    } on Object {
      // Binding not initialized (e.g. pure tests): jank observer skipped.
    }
  }

  static void _installConnectivity(CloseYourItClient instance) {
    if (!instance.options.captureConnectivityBreadcrumbs) return;
    try {
      final observer = CloseYourItConnectivityObserver(client: instance)
        ..install();
      _connectivityObserver = observer;
    } on Object {
      // Plugin unavailable (e.g. pure tests/unsupported platform):
      // connectivity breadcrumbs skipped, the rest of the client is intact.
    }
  }

  /// Captures an exception.
  static void captureException(
    Object error, {
    StackTrace? stackTrace,
    bool handled = false,
    String level = 'error',
    Map<String, Object?>? contexts,
    List<String> inAppPackages = const [],
  }) =>
      _client?.captureException(
        error,
        stackTrace: stackTrace,
        handled: handled,
        level: level,
        contexts: contexts,
        inAppPackages: inAppPackages,
      );

  /// Captures a diagnostic message.
  static void captureMessage(String message, {String level = 'info'}) =>
      _client?.captureMessage(message, level: level);

  /// Buffers a structured log.
  static void log(
    LogLevel level,
    String message, {
    String? logger,
    Map<String, Object?>? attributes,
  }) =>
      _client?.log(level, message, logger: logger, attributes: attributes);

  /// Compatible logger (`debug`/`info`/`warn`/`error`/`fatal`).
  static CloseYourItLogger get logger => CloseYourItLogger(_client);

  /// Declares that a piece of code was EXECUTED, under the literal key
  /// [key]: this is how the project's usage page knows which parts
  /// of the app actually run and which ones nobody touches anymore.
  ///
  /// [key] must be written by hand in the code, never interpolated with data (an id,
  /// a user name, a path): a malformed symbol is silently dropped.
  /// No-op while usage telemetry is off
  /// ([CloseYourItOptions.usageEnabled], opt-in) or if the credential is the public
  /// DSN — the channel is Bearer-only, like metrics and logs.
  static void used(String key) => _client?.recordUsage(key);

  /// Like [used], but declares a **screen** (kind `route`): pass the logical
  /// screen name (`CheckoutScreen`), never the visited path — an
  /// `/orders/42` would carry user data into the symbol table.
  static void usedRoute(String name) =>
      _client?.recordUsage(name, kind: 'route');

  /// Measures the duration of [body] (`slow_method` metric if ≥ threshold).
  static Future<T> measure<T>(String label, FutureOr<T> Function() body) {
    final c = _client;
    return c != null ? c.measure(label, body) : Future<T>.sync(body);
  }

  /// Sets the user.
  static void setUser(
          {String? id, String? email, String? ipAddress, String? username}) =>
      _client?.setUser(
          id: id, email: email, ipAddress: ipAddress, username: username);

  /// Sets a tag.
  static void setTag(String key, String value) => _client?.setTag(key, value);

  /// Adds several tags.
  static void setTags(Map<String, String> tags) => _client?.setTags(tags);

  /// Sets an extra value.
  static void setExtra(String key, Object? value) =>
      _client?.setExtra(key, value);

  /// Sets a named context.
  static void setContext(String key, Map<String, Object?> value) =>
      _client?.setContext(key, value);

  /// Sets the correlation ID.
  static void setTraceId(String? id) => _client?.setTraceId(id);

  /// Runs [fn] on the current scope.
  static void configureScope(void Function(Scope scope) fn) =>
      _client?.configureScope(fn);

  /// Clears the scope.
  static void clearScope() => _client?.clearScope();

  /// Adds a breadcrumb.
  static void addBreadcrumb({
    required String message,
    String? category,
    String type = 'default',
    String level = 'info',
    Map<String, Object?>? data,
  }) =>
      _client?.addBreadcrumb(
        message: message,
        category: category,
        type: type,
        level: level,
        data: data,
      );

  /// Snapshot of the diagnostic counters (flow counts, flat).
  static Map<String, int> get stats => _client?.stats.toMap() ?? const {};

  /// **Immutable** diagnostics snapshot: the flow counts and the structured
  /// drop reasons ([DropReason]) — a picture that does not change while
  /// telemetry carries on. It contains only enums and integers (no sensitive data).
  /// Empty snapshot if the client is not initialized.
  static DiagnosticsSnapshot get diagnostics =>
      _client?.stats.snapshot() ?? DiagnosticsSnapshot.empty();

  /// Flushes the buffered logs and waits for in-flight sends.
  static Future<void> flush() => _client?.flush() ?? Future<void>.value();

  /// Shuts down the client, restores the global handlers and frees resources.
  static Future<void> close() async {
    _disposeErrorHandlers?.call();
    _disposeErrorHandlers = null;

    _disposeIsolateHandler?.call();
    _disposeIsolateHandler = null;
    _isolateErrorPort = null;

    final observer = _lifecycleObserver;
    if (observer != null) {
      try {
        WidgetsBinding.instance.removeObserver(observer);
      } on Object {
        // Binding unavailable: nothing to remove.
      }
      _lifecycleObserver = null;
    }

    try {
      _frameObserver?.dispose();
    } on Object {
      // Binding unavailable: nothing to remove.
    }
    _frameObserver = null;

    try {
      await _connectivityObserver?.dispose();
    } on Object {
      // Subscription already closed or never opened: nothing to remove.
    }
    _connectivityObserver = null;

    // The reference must be cleared in any case: even if the client shutdown
    // failed, the façade must not stay attached to an orphan client (so
    // re-init stays a safe close — no dangling resources).
    try {
      await _client?.close();
    } finally {
      _client = null;
    }
  }
}
