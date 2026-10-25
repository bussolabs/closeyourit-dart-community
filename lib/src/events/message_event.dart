import '../scrubber.dart';
import '../uuid.dart';
import '../version.dart';

/// Diagnostic message event (Sentry format), sent to `POST …/events`.
class MessageEvent {
  MessageEvent({
    required this.message,
    required this.environment,
    this.release,
    this.level = 'info',
    this.scopeHash = const <String, Object?>{},
    this.traceId,
    String? eventId,
    DateTime? occurredAt,
  })  : eventId = eventId ?? Uuid.v4NoDashes(),
        occurredAt = (occurredAt ?? DateTime.now()).toUtc();

  final String eventId;
  final DateTime occurredAt;
  final String message;
  final String environment;
  final String? release;
  final String level;
  final Map<String, Object?> scopeHash;
  final String? traceId;

  /// Relative ingest path.
  static const String ingestPath = 'events';

  Map<String, Object?> toJson() {
    final base = Map<String, Object?>.from(scopeHash);
    final scopeContexts =
        (base.remove('contexts') as Map<String, Object?>?) ?? const {};

    return <String, Object?>{
      'event_id': eventId,
      'timestamp': occurredAt.toIso8601String(),
      'platform': 'dart',
      'level': level,
      'environment': environment,
      if (release != null) 'release': release,
      // Scrub the message on captureMessage too, not only on errors and logs: a
      // diagnostic message can carry an access header just like an
      // exception. Parity with the Ruby gem (MessageEvent) and the JS client.
      'message': {'formatted': Scrubber.scrubMessage(message)},
      'contexts': <String, Object?>{
        'runtime': const {'name': 'dart', 'version': closeYourItSdkVersion},
        ...scopeContexts,
      },
      'sdk': const {
        'name': closeYourItSdkName,
        'version': closeYourItSdkVersion
      },
      ...base,
      if (traceId != null) 'trace_id': traceId,
    };
  }
}
