import '../scrubber.dart';
import '../stack_frames.dart';
import '../uuid.dart';
import '../version.dart';

/// Sentry-format error event, sent to `POST …/events`.
///
/// Mirrors `CloseYourIt::Events::ErrorEvent`. `exception.values.last` is the
/// crash; the stacktrace is oldest-first (see [StackFrames]).
class ErrorEvent {
  ErrorEvent({
    required this.exceptionType,
    required this.value,
    required this.frames,
    required this.environment,
    this.release,
    this.handled = false,
    this.level = 'error',
    this.scopeHash = const <String, Object?>{},
    this.traceId,
    this.contexts,
    this.request,
    String? eventId,
    DateTime? occurredAt,
  })  : eventId = eventId ?? Uuid.v4NoDashes(),
        occurredAt = (occurredAt ?? DateTime.now()).toUtc();

  /// Builds the event from a Dart exception and its stacktrace.
  factory ErrorEvent.fromError(
    Object error,
    StackTrace? stackTrace, {
    required String environment,
    String? release,
    bool handled = false,
    String level = 'error',
    Map<String, Object?> scopeHash = const <String, Object?>{},
    String? traceId,
    Map<String, Object?>? contexts,
    Map<String, Object?>? request,
    List<String> inAppPackages = const [],
    String? eventId,
    DateTime? occurredAt,
  }) {
    return ErrorEvent(
      exceptionType: error.runtimeType.toString(),
      value: Scrubber.scrubMessage(error.toString()),
      frames: StackFrames.parse(stackTrace, inAppPackages: inAppPackages),
      environment: environment,
      release: release,
      handled: handled,
      level: level,
      scopeHash: scopeHash,
      traceId: traceId,
      contexts: contexts,
      request: request,
      eventId: eventId,
      occurredAt: occurredAt,
    );
  }

  final String eventId;
  final DateTime occurredAt;
  final String exceptionType;
  final String value;
  final List<Map<String, Object?>> frames;
  final String environment;
  final String? release;
  final bool handled;
  final String level;
  final Map<String, Object?> scopeHash;
  final String? traceId;
  final Map<String, Object?>? contexts;

  /// Snapshot of THIS request's context, passed directly by the Dio
  /// interceptor instead of being read from the shared global scope.
  /// It wins over any leftover `request` in the scope (CYDA-9 isolation).
  final Map<String, Object?>? request;

  /// Relative ingest path.
  static const String ingestPath = 'events';

  Map<String, Object?> toJson() {
    final base = Map<String, Object?>.from(scopeHash);
    final scopeContexts =
        (base.remove('contexts') as Map<String, Object?>?) ?? const {};

    final json = <String, Object?>{
      'event_id': eventId,
      'timestamp': occurredAt.toIso8601String(),
      'platform': 'dart',
      'level': level,
      'environment': environment,
      if (release != null) 'release': release,
      'exception': {
        'values': [
          {
            'type': exceptionType,
            'value': value,
            'stacktrace': {'frames': frames},
            'mechanism': {'type': 'dart', 'handled': handled},
          },
        ],
      },
      'contexts': <String, Object?>{
        'runtime': const {'name': 'dart', 'version': closeYourItSdkVersion},
        ...scopeContexts,
        ...?contexts,
      },
      'sdk': const {
        'name': closeYourItSdkName,
        'version': closeYourItSdkVersion
      },
      ...base,
      // After `...base`: the per-request snapshot wins over any leftover
      // `request` in the scope (concurrent request isolation, CYDA-9).
      if (request != null) 'request': request,
      if (traceId != null) 'trace_id': traceId,
    };
    return json;
  }
}
