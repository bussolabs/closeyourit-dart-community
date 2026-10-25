import '../log_level.dart';
import '../scrubber.dart';
import '../uuid.dart';
import '../version.dart';

/// Structured log entry, sent to `POST …/logs` (in batches).
///
/// Mirrors `CloseYourIt::Events::LogEvent`. The [attributes] are scrubbed at
/// construction; [traceId] correlates the log with errors/metrics of the same
/// operation.
class LogEvent {
  LogEvent({
    required this.message,
    required this.level,
    required this.environment,
    this.logger,
    this.release,
    this.traceId,
    Map<String, Object?>? attributes,
    String? eventId,
    DateTime? occurredAt,
  })  : eventId = eventId ?? Uuid.v4NoDashes(),
        occurredAt = (occurredAt ?? DateTime.now()).toUtc(),
        attributes = (attributes == null || attributes.isEmpty)
            ? null
            : Scrubber.scrubMap(attributes);

  final String eventId;
  final DateTime occurredAt;
  final String message;
  final LogLevel level;
  final String environment;
  final String? logger;
  final String? release;
  final String? traceId;
  final Map<String, Object?>? attributes;

  /// Relative ingest path.
  static const String ingestPath = 'logs';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'event_id': eventId,
      'timestamp': occurredAt.toIso8601String(),
      'level': level.wire,
      // Scrub the message on logs too (not only on exception.message): a log can carry
      // PII/secrets just like an error. Parity with ErrorEvent and the Ruby gem (LogEvent).
      'message': Scrubber.scrubMessage(message),
      if (attributes != null) 'attributes': attributes,
      if (logger != null) 'logger': logger,
      if (traceId != null) 'trace_id': traceId,
      'environment': environment,
      if (release != null) 'release': release,
      'sdk': const {
        'name': closeYourItSdkName,
        'version': closeYourItSdkVersion
      },
    };
  }
}
