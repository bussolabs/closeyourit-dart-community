import 'package:closeyourit/src/events/metric_event.dart';
import 'package:closeyourit/src/events/performance_issue_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PerformanceIssueEvent', () {
    test('slow_external_http: payload with host/path/trace_id, fixed kind', () {
      final h = PerformanceIssueEvent(
        subtype: 'slow_external_http',
        durationMs: 1234.567,
        environment: 'production',
        traceId: 'req-9',
        httpHost: 'api.stripe.com',
        httpUrl: '/v1/charges/ch_<n>',
      ).toJson();

      expect(h['kind'], 'performance_issue');
      expect(h['subtype'], 'slow_external_http');
      expect(h['duration_ms'], 1234.57);
      expect(h['environment'], 'production');
      expect(h['trace_id'], 'req-9');
      expect(h['http_host'], 'api.stripe.com');
      expect(h['http_url'], '/v1/charges/ch_<n>');
      expect(h['sample_id'], isA<String>());
      expect((h['sdk'] as Map)['name'], 'closeyourit-dart');
    });

    test('omits nil fields (no sql/source/route/query_count on mobile)', () {
      final h = PerformanceIssueEvent(
        subtype: 'slow_external_http',
        durationMs: 1000,
        environment: 'production',
        httpHost: 'api.example.com',
        httpUrl: '/x',
      ).toJson();

      expect(h.containsKey('sql'), isFalse);
      expect(h.containsKey('source'), isFalse);
      expect(h.containsKey('route'), isFalse);
      expect(h.containsKey('query_count'), isFalse);
      expect(h.containsKey('trace_id'), isFalse);
    });
  });

  group('MetricEvent trace_id (parity)', () {
    test('includes trace_id when set', () {
      final h = MetricEvent(
        label: 'checkout',
        durationMs: 250,
        environment: 'production',
        traceId: 'req-1',
      ).toJson();
      expect(h['trace_id'], 'req-1');
    });

    test('omits trace_id when null', () {
      final h = MetricEvent(
              label: 'checkout', durationMs: 250, environment: 'production')
          .toJson();
      expect(h.containsKey('trace_id'), isFalse);
    });
  });
}
