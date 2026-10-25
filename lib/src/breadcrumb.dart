import 'scrubber.dart';

/// Single history entry (breadcrumb), in Sentry format.
///
/// Attached to events as `breadcrumbs.values[]`. The [data] are scrubbed at
/// construction (defense in depth on PII).
class Breadcrumb {
  Breadcrumb({
    required this.message,
    this.category,
    this.type = 'default',
    this.level = 'info',
    Map<String, Object?>? data,
    DateTime? timestamp,
  })  : timestamp = (timestamp ?? DateTime.now()).toUtc(),
        data = (data == null || data.isEmpty) ? null : Scrubber.scrubMap(data);

  /// Event instant (UTC).
  final DateTime timestamp;

  /// Human-readable breadcrumb text.
  final String? message;

  /// Free-form category (e.g. `ui`, `navigation`, `http`).
  final String? category;

  /// Sentry type: `default`, `query`, `http`, `user`, `navigation`.
  final String type;

  /// Level: `info`, `debug`, `warning`, `error`.
  final String level;

  /// Structured context (already scrubbed), or `null` if empty.
  final Map<String, Object?>? data;

  /// Sentry serialization, with only the keys that have a value.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'timestamp': timestamp.toIso8601String(),
      'type': type,
      'level': level,
    };
    if (category != null) json['category'] = category;
    if (message != null) json['message'] = message;
    if (data != null) json['data'] = data;
    return json;
  }
}
