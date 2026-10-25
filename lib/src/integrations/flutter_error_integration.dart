import 'package:flutter/foundation.dart';

import '../client.dart';

/// Installs the global handlers for unhandled errors, routing them to
/// [client]. Replaces the gem's Rack middlewares.
///
/// - [FlutterError.onError]: widget framework errors (build/layout/paint).
/// - [PlatformDispatcher.onError]: asynchronous/platform errors.
///
/// Both call the previous handler (chain preserved: the default behaviour,
/// e.g. printing to the console, stays). Returns a disposer that restores
/// the original handlers (used by `CloseYourIt.close`).
void Function() installErrorHandlers(CloseYourItClient client) {
  final previousFlutterOnError = FlutterError.onError;
  final previousPlatformOnError = PlatformDispatcher.instance.onError;

  FlutterError.onError = (FlutterErrorDetails details) {
    client.captureException(
      details.exception,
      stackTrace: details.stack ?? StackTrace.current,
    );
    previousFlutterOnError?.call(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    client.captureException(error, stackTrace: stack);
    return previousPlatformOnError?.call(error, stack) ?? true;
  };

  return () {
    FlutterError.onError = previousFlutterOnError;
    PlatformDispatcher.instance.onError = previousPlatformOnError;
  };
}
