/// Isolate integration: backstop for unhandled errors.
///
/// The part that touches `dart:isolate` (`installIsolateErrorHandler`) is resolved
/// per platform via conditional import — on web (no isolates) it is a no-op —
/// so the `dart:isolate` import never reaches the web build and the
/// package stays compilable everywhere. `IsolateError`/`handleIsolateError` are
/// pure (no `dart:isolate`) and live in `isolate_error.dart`.
library;

export 'isolate_error.dart' show IsolateError, handleIsolateError;
export 'isolate_error_install_web.dart'
    if (dart.library.io) 'isolate_error_install_io.dart'
    show installIsolateErrorHandler;
