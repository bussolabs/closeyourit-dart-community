/// CloseYourIt — Dart/Flutter client for the internal observability backend.
///
/// Mirrors the `closeyourit-ruby` gem: captures errors, metrics, logs and
/// (opt-in) usage telemetry and sends them to the backend fire-and-forget (it never
/// crashes the host app). Distributed apps authenticate with the `publicKey` (DSN,
/// errors on `/api/{projectId}/store` with `?sentry_key=`); the `cyi_…` Bearer stays
/// server-side (`/api/v1/projects/{projectId}/{events,metrics,logs,usages}`).
///
/// Single import: `import 'package:closeyourit/closeyourit.dart';`
library;

export 'src/breadcrumb.dart' show Breadcrumb;
export 'src/client.dart' show CloseYourItClient;
export 'src/close_your_it.dart' show CloseYourIt;
export 'src/configuration.dart' show BeforeSend, CloseYourItOptions;
export 'src/integrations/connectivity_observer.dart'
    show
        CloseYourItConnectivity,
        CloseYourItConnectivityObserver,
        ConnectivitySource,
        PluginConnectivitySource;
export 'src/integrations/device_context.dart'
    show DeviceContextProvider, DeviceContexts, PluginDeviceContextProvider;
export 'src/integrations/dio_interceptor.dart' show CloseYourItDioInterceptor;
export 'src/integrations/isolate_error_integration.dart' show IsolateError;
export 'src/integrations/navigator_observer.dart'
    show CloseYourItNavigatorObserver;
export 'src/integrations/rebuild_probe.dart' show CloseYourItRebuildProbe;
export 'src/integrations/user_interaction.dart' show CloseYourItUserInteraction;
export 'src/log_level.dart' show LogLevel;
export 'src/logger.dart' show CloseYourItLogger;
// OfflineStore/PendingEvent (pure, web-safe types) to inject a custom
// persistent queue. FileOfflineStore is NOT exported: it uses dart:io (no web).
export 'src/offline_store.dart' show OfflineStore, PendingEvent;
export 'src/scope.dart' show Scope;
// Diagnostics (CYDA-13): flow counters, structured drop reasons,
// immutable snapshot and the `onDiagnostic` callback signal.
export 'src/stats.dart'
    show
        StatKey,
        DropReason,
        DiagnosticEvent,
        DiagnosticsSnapshot,
        DiagnosticCallback;
export 'src/version.dart' show closeYourItSdkName, closeYourItSdkVersion;
