import '../client.dart';

/// Unhandled error propagated by an isolate, captured through the
/// `Isolate.addErrorListener` / `Isolate.spawn(onError:)` protocol. The message
/// arrives as a string (objects are not serializable across isolates), so it
/// is wrapped here to give it a type the backend can recognise.
///
/// "Pure" part of the isolate integration: no `dart:isolate`, so it also
/// compiles on web (where isolates do not exist).
class IsolateError implements Exception {
  IsolateError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Routes an isolate error message to [client].
///
/// The protocol delivers `[message, stackTrace]` (both strings,
/// `stackTrace` possibly `null`). Captures it as an unhandled `fatal` error.
/// Robust to malformed messages (ignored). Shared by the listener on the
/// current isolate and by the `onError` use of a spawned isolate.
void handleIsolateError(CloseYourItClient client, Object? message) {
  if (message is! List || message.length != 2) return;
  final error = message[0]?.toString();
  if (error == null || error.isEmpty) return;
  final traceStr = message[1]?.toString();
  final stack = (traceStr == null || traceStr.isEmpty)
      ? StackTrace.empty
      : StackTrace.fromString(traceStr);
  client.captureException(
    IsolateError(error),
    stackTrace: stack,
    level: 'fatal',
  );
}
