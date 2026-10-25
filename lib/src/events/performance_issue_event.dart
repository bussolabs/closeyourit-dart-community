import '../uuid.dart';
import '../version.dart';

/// `kind=performance_issue` performance verdict, sent to `POST …/metrics`.
///
/// Mirrors `CloseYourIt::PerformanceIssueEvent` (gem). It is an aggregated verdict,
/// not a raw metric: `subtype` qualifies it, `traceId` correlates it with
/// logs/errors of the same operation. On Flutter the only subtype emitted in Phase 2
/// is `slow_external_http` (slow external HTTP call, via the Dio interceptor); the
/// optional fields keep the payload aligned with the backend for future subtypes.
/// `null` fields are omitted.
class PerformanceIssueEvent {
  PerformanceIssueEvent({
    required this.subtype,
    required this.durationMs,
    required this.environment,
    this.traceId,
    this.httpHost,
    this.httpUrl,
    this.route,
    this.sql,
    this.source,
    this.queryCount,
    String? sampleId,
    DateTime? occurredAt,
  })  : sampleId = sampleId ?? Uuid.v4(),
        occurredAt = (occurredAt ?? DateTime.now()).toUtc();

  /// Verdict facet (`slow_external_http` in Phase 2; the backend also knows
  /// `n_plus_one`/`high_query_count`/`slow_request`).
  final String subtype;

  /// Salient duration in milliseconds (for slow_external_http = call duration).
  final double durationMs;

  final String environment;

  /// Correlation ID (from the Scope).
  final String? traceId;

  /// External host (slow_external_http) — the backend groups by host + path.
  final String? httpHost;

  /// Templated external path (slow_external_http).
  final String? httpUrl;

  /// Route/screen (route-based subtypes).
  final String? route;

  /// SQL template (query-bound subtypes; unused on Flutter).
  final String? sql;

  /// Call-site (query-bound subtypes; unused on Flutter).
  final String? source;

  /// Number of occurrences in the verdict (count-based subtypes).
  final int? queryCount;

  final String sampleId;
  final DateTime occurredAt;

  /// Fixed `kind` for performance verdicts.
  static const String kind = 'performance_issue';

  /// Relative ingest path (same as metrics).
  static const String ingestPath = 'metrics';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind,
      'subtype': subtype,
      'sample_id': sampleId,
      'duration_ms': double.parse(durationMs.toStringAsFixed(2)),
      'occurred_at': occurredAt.toIso8601String(),
      'environment': environment,
      if (traceId != null) 'trace_id': traceId,
      if (httpHost != null) 'http_host': httpHost,
      if (httpUrl != null) 'http_url': httpUrl,
      if (route != null) 'route': route,
      if (sql != null) 'sql': sql,
      if (source != null) 'source': source,
      if (queryCount != null) 'query_count': queryCount,
      'sdk': const {
        'name': closeYourItSdkName,
        'version': closeYourItSdkVersion
      },
    };
  }
}
