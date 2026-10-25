import '../uuid.dart';
import '../version.dart';

/// `slow_method` metric, sent to `POST …/metrics`.
///
/// Flutter has no `slow_query` (no SQL): metrics are only timings of blocks
/// measured with `CloseYourIt.measure`. `kind` is fixed to `slow_method`
/// (the backend rejects other kinds with `R422-METRIC-002`).
class MetricEvent {
  MetricEvent({
    required this.label,
    required this.durationMs,
    required this.environment,
    this.file,
    this.lineno,
    this.arguments,
    this.traceId,
    String? sampleId,
    DateTime? occurredAt,
  })  : assert(label.trim().isNotEmpty,
            'MetricEvent.label must not be empty: it is the slow_method fingerprint'),
        sampleId = sampleId ?? Uuid.v4(),
        occurredAt = (occurredAt ?? DateTime.now()).toUtc() {
    // Production guard (asserts are disabled in release): an empty label
    // collapses every metric into a single group on the backend
    // (signature = "slow_method\n" + label).
    if (label.trim().isEmpty) {
      throw ArgumentError.value(
          label, 'label', 'must not be empty (slow_method fingerprint)');
    }
  }

  /// `Class#method` or a label provided by the caller.
  final String label;

  /// Measured duration in milliseconds.
  final double durationMs;

  final String environment;

  /// Call-site file (if known).
  final String? file;

  /// Call-site line (if known).
  final int? lineno;

  /// Block arguments (opt-in, already scrubbed), or `null`.
  final List<Map<String, Object?>>? arguments;

  /// Correlation ID (from the Scope) — ties the metric to logs/errors of the same operation.
  final String? traceId;

  final String sampleId;
  final DateTime occurredAt;

  /// Fixed `kind` for Flutter metrics.
  static const String kind = 'slow_method';

  /// Relative ingest path.
  static const String ingestPath = 'metrics';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind,
      'sample_id': sampleId,
      'duration_ms': double.parse(durationMs.toStringAsFixed(2)),
      'occurred_at': occurredAt.toIso8601String(),
      'environment': environment,
      if (traceId != null) 'trace_id': traceId,
      'label': label,
      if (file != null) 'file': file,
      if (lineno != null) 'lineno': lineno,
      if (arguments != null) 'arguments': arguments,
      'sdk': const {
        'name': closeYourItSdkName,
        'version': closeYourItSdkVersion
      },
    };
  }
}
