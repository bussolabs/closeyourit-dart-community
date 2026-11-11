import 'dart:async';
import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Harness {
  _Harness(CloseYourItOptions options,
      {double random = 0.0, Stats? stats, int status = 202}) {
    stats ??= Stats();
    final transport = Transport(
      token: options.token,
      publicKey: options.publicKey,
      stats: stats,
      client: MockClient((req) async {
        uris.add(req.url);
        headers.add(req.headers);
        bodies.add(jsonDecode(req.body));
        return http.Response('{"data":{}}', status);
      }),
    );
    client = CloseYourItClient(
      options,
      transport: transport,
      stats: stats,
      worker: BackgroundWorker(stats: stats, maxQueue: options.maxQueue),
      randomSource: () => random,
    );
  }

  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];
  final List<dynamic> bodies = [];
  late final CloseYourItClient client;

  Map<String, Object?> get firstEvent =>
      (bodies.first as Map).cast<String, Object?>();
}

CloseYourItOptions options({
  bool enabled = true,
  String publicKey = '',
  double sampleRate = 1.0,
  double logsSampleRate = 1.0,
  int slowMethodThresholdMs = 0,
  LogLevel logsMinLevel = LogLevel.debug,
  int logsBatchSize = 50,
  int maxQueue = 30,
  List<String> excluded = const [],
  BeforeSend? beforeSend,
  bool detectPerformanceIssues = false,
  bool captureExternalHttp = true,
  int slowExternalThresholdMs = 1000,
  bool detectJank = true,
  int jankFrameBudgetMs = 32,
  int jankWindowMs = 1000,
}) =>
    CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      publicKey: publicKey,
      projectId: 'p1',
      enabled: enabled,
      sampleRate: sampleRate,
      logsSampleRate: logsSampleRate,
      slowMethodThresholdMs: slowMethodThresholdMs,
      logsMinLevel: logsMinLevel,
      logsBatchSize: logsBatchSize,
      maxQueue: maxQueue,
      excludedExceptions: excluded,
      beforeSend: beforeSend,
      detectPerformanceIssues: detectPerformanceIssues,
      captureExternalHttp: captureExternalHttp,
      slowExternalThresholdMs: slowExternalThresholdMs,
      detectJank: detectJank,
      jankFrameBudgetMs: jankFrameBudgetMs,
      jankWindowMs: jankWindowMs,
    );

void main() {
  group('captureException', () {
    test('builds an error event and sends it to /events', () async {
      final h = _Harness(options());
      h.client.captureException(const FormatException('boom'),
          stackTrace: StackTrace.current);
      await h.client.flush();

      expect(h.uris.single.path, '/api/v1/projects/p1/events');
      final values = (h.firstEvent['exception']! as Map)['values']! as List;
      expect((values.single as Map)['type'], 'FormatException');
      expect(h.client.stats[StatKey.enqueued], 1);
      expect(h.client.stats[StatKey.sent], 1);
    });

    test('disabled → nothing sent', () async {
      final h = _Harness(options(enabled: false));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('excluded exception → nothing sent', () async {
      final h = _Harness(options(excluded: ['FormatException']));
      h.client.captureException(const FormatException('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('dedup: same instance captured twice → 1 send', () async {
      final h = _Harness(options());
      final err = StateError('dup');
      h.client
        ..captureException(err)
        ..captureException(err);
      await h.client.flush();
      expect(h.bodies.length, 1);
    });

    test('sampling: random above rate → dropped', () async {
      final h = _Harness(options(sampleRate: 0.5), random: 0.9);
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('sampling: random below rate → sent', () async {
      final h = _Harness(options(sampleRate: 0.5), random: 0.1);
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies.length, 1);
    });

    test('scope (user/tag/trace_id) attached to the event', () async {
      final h = _Harness(options());
      h.client
        ..setUser(id: '7')
        ..setTag('area', 'checkout')
        ..setTraceId('trace-1');
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.firstEvent['user'], {'id': '7'});
      expect(h.firstEvent['tags'], {'area': 'checkout'});
      expect(h.firstEvent['trace_id'], 'trace-1');
    });
  });

  group('captureMessage', () {
    test('sends message.formatted to /events', () async {
      final h = _Harness(options());
      h.client.captureMessage('cache miss', level: 'warning');
      await h.client.flush();
      expect(h.firstEvent['message'], {'formatted': 'cache miss'});
      expect(h.firstEvent['level'], 'warning');
    });
  });

  group('measure', () {
    test('above threshold → slow_method metric to /metrics', () async {
      final h = _Harness(options());
      final result = await h.client.measure('checkout', () async => 42);
      await h.client.flush();
      expect(result, 42);
      expect(h.uris.single.path, '/api/v1/projects/p1/metrics');
      expect(h.firstEvent['kind'], 'slow_method');
      expect(h.firstEvent['label'], 'checkout');
    });

    test('below threshold → no metric', () async {
      final h = _Harness(options(slowMethodThresholdMs: 1 << 30));
      await h.client.measure('fast', () async => 1);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('a body that throws → metric recorded and rethrow', () async {
      final h = _Harness(options());
      await expectLater(
        h.client.measure('boom', () async => throw StateError('x')),
        throwsStateError,
      );
      await h.client.flush();
      expect(h.firstEvent['kind'], 'slow_method');
    });
  });

  group('recordExternalHttp (slow_external_http)', () {
    test('above threshold + detection ON → verdict to /metrics with trace_id',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, slowExternalThresholdMs: 500));
      h.client.setTraceId('trace-77');
      h.client.recordExternalHttp(
          host: 'api.stripe.com', path: '/v1/charges/ch_<n>', durationMs: 1200);
      await h.client.flush();

      expect(h.uris.single.path, '/api/v1/projects/p1/metrics');
      expect(h.firstEvent['kind'], 'performance_issue');
      expect(h.firstEvent['subtype'], 'slow_external_http');
      expect(h.firstEvent['http_host'], 'api.stripe.com');
      expect(h.firstEvent['http_url'], '/v1/charges/ch_<n>');
      expect(h.firstEvent['trace_id'], 'trace-77');
    });

    test('below threshold → nothing sent', () async {
      final h = _Harness(options(
          detectPerformanceIssues: true, slowExternalThresholdMs: 1000));
      h.client.recordExternalHttp(
          host: 'api.stripe.com', path: '/x', durationMs: 200);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('detection OFF → nothing sent even if very slow', () async {
      final h = _Harness(options(detectPerformanceIssues: false));
      h.client.recordExternalHttp(
          host: 'api.stripe.com', path: '/x', durationMs: 9999);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('host = CloseYourIt endpoint → excluded (no telemetry loop)',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, slowExternalThresholdMs: 0));
      h.client.recordExternalHttp(
          host: 'www.closeyour.it',
          path: '/api/v1/projects/p1/metrics',
          durationMs: 50);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });
  });

  group('measure trace_id', () {
    test('the slow_method metric carries the scope trace_id', () async {
      final h = _Harness(options());
      h.client.setTraceId('trace-m');
      await h.client.measure('checkout', () async => 1);
      await h.client.flush();
      expect(h.firstEvent['trace_id'], 'trace-m');
    });
  });

  group('recordRepeatedHttp', () {
    test('detection ON → repeated_http verdict with host/path/count', () async {
      final h = _Harness(options(detectPerformanceIssues: true));
      h.client.recordRepeatedHttp(
          host: 'api.x.it', path: '/v1/items/<n>', count: 5);
      await h.client.flush();
      expect(h.firstEvent['kind'], 'performance_issue');
      expect(h.firstEvent['subtype'], 'repeated_http');
      expect(h.firstEvent['http_host'], 'api.x.it');
      expect(h.firstEvent['query_count'], 5);
    });

    test('detection OFF → nothing sent', () async {
      final h = _Harness(options(detectPerformanceIssues: false));
      h.client.recordRepeatedHttp(host: 'api.x.it', path: '/x', count: 9);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });
  });

  group('recordJank', () {
    test('over-budget frame → jank verdict with route and duration', () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      h.client.currentRoute = 'FeedScreen';
      h.client.recordJank(frameMs: 50);
      await h.client.flush();
      expect(h.firstEvent['kind'], 'performance_issue');
      expect(h.firstEvent['subtype'], 'jank');
      expect(h.firstEvent['route'], 'FeedScreen');
      expect(h.firstEvent['duration_ms'], 50);
      expect(h.firstEvent['query_count'], 1); // aggregated frame count
    });

    test('janky scroll: ~40 frames in a window → a single aggregated verdict',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      h.client.currentRoute = 'FeedScreen';
      for (var i = 0; i < 40; i++) {
        h.client.recordJank(frameMs: 40 + i.toDouble());
      }
      // Trailing: nothing enqueued until the window closes.
      expect(h.bodies, isEmpty);

      await h.client.flush(); // closes the window as the timer would

      final janks = h.bodies
          .whereType<Map<String, dynamic>>()
          .where((b) => b['subtype'] == 'jank')
          .toList();
      expect(janks.length, 1); // one POST, not 40
      expect(janks.single['route'], 'FeedScreen');
      expect(janks.single['query_count'], 40); // frame count
      expect(janks.single['duration_ms'], 79); // worst frame (40 + 39)
      expect(h.client.stats[StatKey.dropped], 0);
    });

    test('a concurrent error is not starved by a janky scroll', () async {
      final h = _Harness(options(
          detectPerformanceIssues: true, jankFrameBudgetMs: 32, maxQueue: 30));
      h.client.currentRoute = 'FeedScreen';
      // ~40 janky frames in the same synchronous batch...
      for (var i = 0; i < 40; i++) {
        h.client.recordJank(frameMs: 50);
      }
      // ...plus an error at the same instant: the queue must not be saturated.
      h.client.captureException(StateError('boom'));
      expect(h.client.stats[StatKey.dropped], 0);

      await h.client.flush();

      final errorSent = h.bodies
          .whereType<Map<String, dynamic>>()
          .any((b) => b['exception'] != null);
      expect(errorSent, isTrue); // the error arrived, not dropped
      expect(h.client.stats[StatKey.dropped], 0);
    });

    test('frame within budget → nothing sent', () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      h.client.recordJank(frameMs: 16);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('detectJank OFF → nothing sent even over budget', () async {
      final h =
          _Harness(options(detectPerformanceIssues: true, detectJank: false));
      h.client.recordJank(frameMs: 200);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test(
        'without a route (no NavigatorObserver) → <unknown> sentinel, not an omitted route',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      // currentRoute stays null: NavigatorObserver not registered / during startup.
      h.client.recordJank(frameMs: 50);
      await h.client.flush();
      expect(h.firstEvent['subtype'], 'jank');
      expect(
          h.firstEvent['route'], '<unknown>'); // dedicated group, not omitted
    });

    test(
        'jank with and without a route → <unknown> group distinct from the screen',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      h.client.recordJank(frameMs: 50); // currentRoute null → <unknown>
      h.client.currentRoute = 'FeedScreen';
      h.client.recordJank(frameMs: 60); // → FeedScreen
      await h.client.flush();

      final routes = h.bodies
          .whereType<Map<String, dynamic>>()
          .where((b) => b['subtype'] == 'jank')
          .map((b) => b['route'])
          .toList();
      expect(routes, containsAll(<String>['<unknown>', 'FeedScreen']));
      expect(routes.length, 2); // two separate groups, not collapsed
    });

    test('an explicit route passed to recordJank wins over currentRoute',
        () async {
      final h = _Harness(
          options(detectPerformanceIssues: true, jankFrameBudgetMs: 32));
      h.client.currentRoute = 'FeedScreen';
      h.client.recordJank(frameMs: 50, route: 'CheckoutScreen');
      await h.client.flush();
      expect(h.firstEvent['route'], 'CheckoutScreen');
    });
  });

  group('recordRebuildStorm', () {
    test('detection ON → rebuild_storm verdict with widget/count', () async {
      final h = _Harness(options(detectPerformanceIssues: true));
      h.client
          .recordRebuildStorm(widget: 'ProductCard', count: 20, windowMs: 1000);
      await h.client.flush();
      expect(h.firstEvent['kind'], 'performance_issue');
      expect(h.firstEvent['subtype'], 'rebuild_storm');
      expect(h.firstEvent['source'], 'ProductCard');
      expect(h.firstEvent['query_count'], 20);
    });

    test('detection OFF → nothing sent', () async {
      final h = _Harness(options(detectPerformanceIssues: false));
      h.client.recordRebuildStorm(widget: 'X', count: 99, windowMs: 1000);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('without a current route → <unknown> sentinel in the verdict',
        () async {
      final h = _Harness(options(detectPerformanceIssues: true));
      // currentRoute null: no NavigatorObserver registered.
      h.client
          .recordRebuildStorm(widget: 'ProductCard', count: 20, windowMs: 1000);
      await h.client.flush();
      expect(h.firstEvent['route'], '<unknown>'); // not omitted
    });

    test('with a current route → attributed to the screen', () async {
      final h = _Harness(options(detectPerformanceIssues: true));
      h.client.currentRoute = 'CartScreen';
      h.client
          .recordRebuildStorm(widget: 'ProductCard', count: 20, windowMs: 1000);
      await h.client.flush();
      expect(h.firstEvent['route'], 'CartScreen');
    });
  });

  group('log', () {
    test('buffers and sends an array to /logs on flush', () async {
      final h = _Harness(options());
      h.client
        ..log(LogLevel.info, 'a',
            attributes: {'order_id': 1, 'token': 'secret'})
        ..log(LogLevel.error, 'b');
      await h.client.flush();
      expect(h.uris.single.path, '/api/v1/projects/p1/logs');
      final batch = h.bodies.single as List;
      expect(batch.length, 2);
      expect((batch.first as Map)['message'], 'a');
      expect(
          ((batch.first as Map)['attributes'] as Map)['token'], '[FILTERED]');
    });

    test('below logsMinLevel → not buffered', () async {
      final h = _Harness(options(logsMinLevel: LogLevel.warning));
      h.client.log(LogLevel.info, 'ignored');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('logger.warn maps to warning', () async {
      final h = _Harness(options());
      h.client.logger.warn('retry', attributes: {'attempt': 3});
      await h.client.flush();
      final batch = h.bodies.single as List;
      expect((batch.single as Map)['level'], 'warning');
    });

    test('flush of 1500 logs → 2 sends of 1000 and 500 (backend cap)',
        () async {
      final h = _Harness(options(logsBatchSize: 2000));
      for (var i = 0; i < 1500; i++) {
        h.client.log(LogLevel.info, 'm$i');
      }
      await h.client.flush();

      expect(h.bodies.length, 2);
      final sizes = h.bodies.map((b) => (b as List).length).toList()..sort();
      expect(sizes, [500, 1000]);
      expect(h.uris.every((u) => u.path == '/api/v1/projects/p1/logs'), isTrue);
    });

    test('flush of ≤1000 logs → a single send', () async {
      final h = _Harness(options(logsBatchSize: 2000));
      for (var i = 0; i < 1000; i++) {
        h.client.log(LogLevel.info, 'm$i');
      }
      await h.client.flush();

      expect(h.bodies.length, 1);
      expect((h.bodies.single as List).length, 1000);
    });
  });

  group('beforeSend', () {
    test('null drops the payload', () async {
      final h = _Harness(options(beforeSend: (_) => null));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('modifies the payload before sending', () async {
      final h = _Harness(options(beforeSend: (p) => {...p, 'tagged': true}));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.firstEvent['tagged'], true);
    });

    Map<String, dynamic>? throwing(Map<String, dynamic> _) =>
        throw StateError('hook bug');

    test('throwing on captureException → swallowed, dropped and counted',
        () async {
      final h = _Harness(options(beforeSend: throwing));
      expect(() => h.client.captureException(StateError('x')), returnsNormally);
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSendError), 1);
      expect(h.client.stats.drops(DropReason.beforeSend), 0);
    });

    test('throwing an Exception (not an Error) is swallowed too', () async {
      Map<String, dynamic>? throwingException(Map<String, dynamic> _) =>
          throw const FormatException('hook');

      final h = _Harness(options(beforeSend: throwingException));
      expect(() => h.client.captureException(StateError('x')), returnsNormally);
      await h.client.flush();
      expect(h.client.stats.drops(DropReason.beforeSendError), 1);
    });

    test('throwing on captureMessage → swallowed, dropped and counted',
        () async {
      final h = _Harness(options(beforeSend: throwing));
      expect(() => h.client.captureMessage('hello'), returnsNormally);
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSendError), 1);
    });

    test('throwing while measure records → the result is still returned',
        () async {
      final h = _Harness(options(beforeSend: throwing)); // threshold 0 → metric
      final result = await h.client.measure('checkout', () async => 42);
      await h.client.flush();
      expect(result, 42);
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSendError), 1);
    });

    test('throwing only on the 2nd of 3 logs → 1st and 3rd sent, 2nd counted',
        () async {
      Map<String, dynamic>? throwOnB(Map<String, dynamic> p) {
        if (p['message'] == 'b') throw StateError('hook bug');
        return p;
      }

      final h = _Harness(options(beforeSend: throwOnB));
      h.client
        ..log(LogLevel.info, 'a')
        ..log(LogLevel.info, 'b')
        ..log(LogLevel.info, 'c');
      await h.client.flush();
      final batch = h.bodies.single as List;
      expect(batch.map((e) => (e as Map)['message']), ['a', 'c']);
      expect(h.client.stats.drops(DropReason.beforeSendError), 1);
      expect(h.client.stats.drops(DropReason.beforeSend), 0);
    });

    test('throwing when a full log buffer flushes → log() does not throw',
        () async {
      final h = _Harness(options(beforeSend: throwing, logsBatchSize: 2));
      expect(() => h.client.log(LogLevel.info, 'a'), returnsNormally);
      // The 2nd log fills the buffer: the flush runs inside log().
      expect(() => h.client.log(LogLevel.info, 'b'), returnsNormally);
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSendError), 2);
    });

    test('a hook that modifies or drops without throwing → no beforeSendError',
        () async {
      Map<String, dynamic>? tagOrDrop(Map<String, dynamic> p) =>
          p['message'] == 'drop' ? null : {...p, 't': 1};

      final h = _Harness(options(beforeSend: tagOrDrop));
      h.client
        ..captureException(StateError('x'))
        ..log(LogLevel.info, 'keep')
        ..log(LogLevel.info, 'drop');
      await h.client.flush();
      expect(h.bodies.whereType<Map<String, dynamic>>().single['t'], 1);
      final logs = h.bodies.whereType<List<dynamic>>().single;
      expect(logs.map((e) => (e as Map)['message']), ['keep']);
      expect(h.client.stats.drops(DropReason.beforeSend), 1);
      expect(h.client.stats.drops(DropReason.beforeSendError), 0);
    });
  });

  group('trace_id auto-population (correlation)', () {
    // Extracts the trace_ids from every sent payload: from error/message events
    // (Map with a top-level trace_id) and from the entries of log batches (List of Map).
    Set<Object?> tracesOf(_Harness h) {
      final traces = <Object?>{};
      for (final body in h.bodies) {
        if (body is Map) {
          traces.add(body['trace_id']);
        } else if (body is List) {
          for (final entry in body) {
            traces.add((entry as Map)['trace_id']);
          }
        }
      }
      return traces;
    }

    test(
        'ticket scenario: 1 error + 3 warning logs in the same tap without '
        'setTraceId -> same non-null trace_id (correlatable)', () async {
      final h = _Harness(options());
      // A single "tap": no call to setTraceId.
      h.client.captureException(StateError('tap failed'));
      h.client
        ..log(LogLevel.warning, 'w1')
        ..log(LogLevel.warning, 'w2')
        ..log(LogLevel.warning, 'w3');
      await h.client.flush();

      final errorBody = h.bodies
          .whereType<Map<String, dynamic>>()
          .firstWhere((b) => b['exception'] != null);
      final errorTrace = errorBody['trace_id'];
      expect(errorTrace, isNotNull); // no longer missing

      final logBatch = h.bodies.whereType<List<dynamic>>().single;
      expect(logBatch.length, 3);
      final logTraces = logBatch.map((l) => (l as Map)['trace_id']).toSet();
      expect(logTraces, {errorTrace}); // the 3 logs share the error trace
    });

    test('error and message without setTraceId -> same auto trace_id',
        () async {
      final h = _Harness(options());
      h.client
        ..captureException(StateError('x'))
        ..captureMessage('nota');
      await h.client.flush();

      final traces = tracesOf(h);
      expect(traces.length, 1); // a single shared trace
      expect(traces.single, isNotNull);
    });

    test('slow_method metric without setTraceId -> correlated with the error',
        () async {
      final h = _Harness(options());
      h.client.captureException(StateError('x'));
      await h.client.measure('checkout', () async => 1);
      await h.client.flush();

      final traces = tracesOf(h);
      expect(traces.length, 1); // error + metric same trace
      expect(traces.single, isNotNull);
    });

    test('a manual setTraceId wins over auto-population', () async {
      final h = _Harness(options());
      h.client.setTraceId('manual');
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.firstEvent['trace_id'], 'manual');
    });

    test('rotateTraceId respects a manual setTraceId (flow not broken)',
        () async {
      final h = _Harness(options());
      h.client.setTraceId('flow');
      h.client.captureException(StateError('primo'));
      h.client.rotateTraceId(); // simulated navigation: must not break the flow
      h.client.captureException(StateError('secondo'));
      await h.client.flush();

      final traces = h.bodies
          .whereType<Map<String, dynamic>>()
          .map((b) => b['trace_id'])
          .toList();
      expect(traces, ['flow', 'flow']); // same manual trace on both
    });

    test('rotateTraceId starts a new logical unit (different trace)', () async {
      final h = _Harness(options());
      h.client.captureException(StateError('primo'));
      h.client.rotateTraceId();
      h.client.captureException(StateError('secondo'));
      await h.client.flush();

      final traces = h.bodies
          .whereType<Map<String, dynamic>>()
          .map((b) => b['trace_id'])
          .toList();
      expect(traces.length, 2);
      expect(traces.every((t) => t != null), isTrue);
      expect(traces[0], isNot(traces[1])); // two distinct logical units
    });

    test('clearScope -> the next event auto-generates a new trace_id',
        () async {
      final h = _Harness(options());
      h.client.captureException(StateError('primo'));
      await h.client.flush();
      final first = h.firstEvent['trace_id'];

      h.client.clearScope();
      h.client.captureException(StateError('secondo'));
      await h.client.flush();
      final second = (h.bodies.last as Map)['trace_id'];

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second, isNot(first));
    });
  });

  group('DSN mode (publicKey) — CYRA-973', () {
    test(
        'captureException goes to the /api/{projectId}/store drop-in with sentry_key, '
        'never Bearer', () async {
      final h = _Harness(options(publicKey: 'deadbeef'));
      h.client.captureException(StateError('boom'));
      await h.client.flush();

      expect(h.uris.single.path, '/api/p1/store');
      expect(h.uris.single.queryParameters['sentry_key'], 'deadbeef');
      expect(h.headers.single.containsKey('Authorization'), isFalse);
      final values = (h.firstEvent['exception']! as Map)['values']! as List;
      expect((values.single as Map)['type'], 'StateError');
      expect(h.client.stats[StatKey.sent], 1);
    });

    test('captureMessage goes to the /store drop-in', () async {
      final h = _Harness(options(publicKey: 'deadbeef'));
      h.client.captureMessage('cache miss', level: 'warning');
      await h.client.flush();

      expect(h.uris.single.path, '/api/p1/store');
      expect(h.firstEvent['message'], {'formatted': 'cache miss'});
    });

    test('measure sends metrics with the public key and preserves the result',
        () async {
      final h = _Harness(options(publicKey: 'deadbeef'));
      final result = await h.client.measure('checkout', () async => 42);
      await h.client.flush();

      expect(result, 42);
      expect(h.uris.single.path, '/api/v1/projects/p1/metrics');
      expect(h.uris.single.queryParameters['sentry_key'], 'deadbeef');
      expect(h.headers.single.containsKey('Authorization'), isFalse);
      expect(h.firstEvent['kind'], 'slow_method');
    });

    test('logs use the public key without a bearer', () async {
      final h = _Harness(options(publicKey: 'deadbeef'));
      h.client
        ..log(LogLevel.info, 'a')
        ..log(LogLevel.error, 'b');
      await h.client.flush();

      expect(h.uris.single.path, '/api/v1/projects/p1/logs');
      expect(h.uris.single.queryParameters['sentry_key'], 'deadbeef');
      expect(h.headers.single.containsKey('Authorization'), isFalse);
      expect(h.bodies.single, hasLength(2));
    });

    test('opt-in performance issues use the public key', () async {
      final h = _Harness(options(
        publicKey: 'deadbeef',
        detectPerformanceIssues: true,
        slowExternalThresholdMs: 0,
      ));
      h.client
        ..currentRoute = 'FeedScreen'
        ..recordExternalHttp(host: 'api.x.it', path: '/y', durationMs: 9999)
        ..recordRepeatedHttp(host: 'api.x.it', path: '/y', count: 9)
        ..recordJank(frameMs: 999)
        ..recordRebuildStorm(widget: 'W', count: 99, windowMs: 1000);
      await h.client.flush();

      expect(h.bodies, hasLength(4));
      expect(
          h.uris.every((uri) =>
              uri.path == '/api/v1/projects/p1/metrics' &&
              uri.queryParameters['sentry_key'] == 'deadbeef'),
          isTrue);
      expect(
          h.headers.every((headers) => !headers.containsKey('Authorization')),
          isTrue);
      expect(
          h.bodies.map((body) => (body as Map)['subtype']),
          unorderedEquals([
            'slow_external_http',
            'repeated_http',
            'jank',
            'rebuild_storm'
          ]));
    });
  });

  group('drop reason diagnostics (CYDA-13)', () {
    test('excluded type → excluded reason, nothing sent', () async {
      final h = _Harness(options(excluded: ['StateError']));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.excluded), 1);
    });

    test('error already captured → duplicate reason on the second capture',
        () async {
      final h = _Harness(options());
      final error = StateError('same instance');
      h.client.captureException(error);
      h.client.captureException(error);
      await h.client.flush();
      expect(h.bodies, hasLength(1)); // sent only once
      expect(h.client.stats.drops(DropReason.duplicate), 1);
    });

    test('unsampled error → sampled reason, nothing sent', () async {
      final h = _Harness(options(sampleRate: 0.0));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.sampled), 1);
    });

    test('unsampled log → sampled reason', () async {
      final h = _Harness(options(logsSampleRate: 0.0));
      h.client.log(LogLevel.error, 'lost');
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.sampled), 1);
    });

    test('beforeSend dropping an event → beforeSend reason', () async {
      final h = _Harness(options(beforeSend: (_) => null));
      h.client.captureException(StateError('x'));
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSend), 1);
    });

    test('beforeSend dropping logs → one beforeSend reason per log', () async {
      final h = _Harness(options(beforeSend: (_) => null));
      h.client
        ..log(LogLevel.info, 'a')
        ..log(LogLevel.info, 'b');
      await h.client.flush();
      expect(h.bodies, isEmpty);
      expect(h.client.stats.drops(DropReason.beforeSend), 2);
    });

    test('the callback receives flow and drop signals', () async {
      final events = <DiagnosticEvent>[];
      final stats = Stats(onEvent: events.add);
      final h = _Harness(options(sampleRate: 0.0), stats: stats);
      // One drop (sampled) and, with a valid capture, the enqueued+sent flow.
      h.client.captureException(StateError('scartato'));
      final h2 = _Harness(options(), stats: stats);
      h2.client.captureException(const FormatException('sent'));
      await h2.client.flush();

      final reasons = events.map((e) => e.reason).whereType<DropReason>();
      final flow = events.map((e) => e.stat).whereType<StatKey>();
      expect(reasons, contains(DropReason.sampled));
      expect(flow, contains(StatKey.enqueued));
      expect(flow, contains(StatKey.sent));
    });

    test(
        'a client built with onDiagnostic honours the callback (no injected stats)',
        () async {
      final events = <DiagnosticEvent>[];
      final client = CloseYourItClient(CloseYourItOptions(
        endpointUrl: 'https://www.closeyour.it',
        token: 'cyi_t',
        projectId: 'p1',
        sampleRate: 0.0, // drops by sampling: no network
        onDiagnostic: events.add,
      ));
      client.captureException(StateError('x'));
      expect(events.map((e) => e.reason), contains(DropReason.sampled));
      await client.close();
    });

    test('413 on a non-persisted send (metric) → tooLarge reason', () async {
      final h = _Harness(options(), status: 413);
      await h.client.measure('checkout', () async => 1); // threshold 0 → metric
      await h.client.flush();
      expect(h.client.stats.drops(DropReason.tooLarge), 1);
      expect(h.client.stats[StatKey.discarded],
          1); // symmetric with the persisted case
    });

    test('permanent 4xx on a log batch (non-persisted) → permanentReject',
        () async {
      final h = _Harness(options(), status: 400);
      h.client.log(LogLevel.error, 'x');
      await h.client.flush();
      expect(h.client.stats.drops(DropReason.permanentReject), 1);
    });

    test('retryable outcome on a non-persisted send → no drop reason',
        () async {
      final h = _Harness(options(), status: 500);
      await h.client.measure('x', () async => 1);
      await h.client.flush();
      expect(h.client.stats.drops(DropReason.tooLarge), 0);
      expect(h.client.stats.drops(DropReason.permanentReject), 0);
      expect(h.client.stats[StatKey.failed], 1); // still a send failure
    });
  });

  group('shutdown with an incomplete response (CYDA-24)', () {
    test('close() ends even with a send that never gets a response', () async {
      final stats = Stats();
      final client = CloseYourItClient(
        options(),
        stats: stats,
        transport: Transport(
          token: 'cyi_t',
          stats: stats,
          // Long send budget: what stops the shutdown is the worker limit.
          timeout: const Duration(seconds: 30),
          client: _NeverAnswersClient(),
        ),
        worker: BackgroundWorker(
          stats: stats,
          flushTimeout: const Duration(milliseconds: 50),
        ),
      );

      client.captureException(StateError('x'));
      await client.close(); // without a limit shutdown would never return
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('flush() ends even with a send that never gets a response', () async {
      final stats = Stats();
      final client = CloseYourItClient(
        options(),
        stats: stats,
        transport: Transport(
          token: 'cyi_t',
          stats: stats,
          timeout: const Duration(seconds: 30),
          client: _NeverAnswersClient(),
        ),
        worker: BackgroundWorker(
          stats: stats,
          flushTimeout: const Duration(milliseconds: 50),
        ),
      );
      addTearDown(client.close);

      client.captureException(StateError('x'));
      await client.flush();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

/// HTTP client that accepts the request and never answers: it reproduces the server
/// that keeps the connection open without completing the response.
class _NeverAnswersClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    return Completer<http.StreamedResponse>().future;
  }
}
