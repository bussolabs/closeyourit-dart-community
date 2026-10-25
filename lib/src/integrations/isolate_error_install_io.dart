import 'dart:isolate';

import '../client.dart';
import 'isolate_error.dart';

/// Hooks [Isolate.current] to capture the unhandled errors **of the current
/// (root) isolate** — those that escape `FlutterError`/`PlatformDispatcher`/
/// the zone. Routed to [client] through the same persistence path as other
/// errors: they survive crashes/offline.
///
/// **Spawned isolates** (`Isolate.spawn`): a listener on the current isolate does
/// NOT cover them — each isolate only receives its own errors. Pass `errorPort` as
/// the `onError` argument when spawning to route their crashes to CloseYourIt.
/// (`compute` errors instead bubble up through its `Future`, already covered by
/// the `appRunner` zone.)
///
/// Returns `dispose` (detaches the listener) and `errorPort` (the `SendPort` to use
/// as `onError`, `null` if isolates are unavailable). Never throws.
({void Function() dispose, Object? errorPort}) installIsolateErrorHandler(
    CloseYourItClient client) {
  try {
    final port = RawReceivePort(
      (dynamic message) => handleIsolateError(client, message),
    );
    Isolate.current.addErrorListener(port.sendPort);
    return (
      dispose: () {
        try {
          Isolate.current.removeErrorListener(port.sendPort);
        } on Object {
          // Best-effort.
        }
        port.close();
      },
      errorPort: port.sendPort,
    );
  } on Object {
    // Isolates unavailable on the platform: no-op.
    return (dispose: () {}, errorPort: null);
  }
}
