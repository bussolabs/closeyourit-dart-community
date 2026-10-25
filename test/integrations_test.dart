import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/integrations/flutter_error_integration.dart';
import 'package:closeyourit/src/integrations/frame_timing_observer.dart';
import 'package:closeyourit/src/integrations/lifecycle_observer.dart';
import 'package:closeyourit/src/integrations/rebuild_probe.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Harness {
  _Harness({CloseYourItOptions? options}) {
    options ??= CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
    );
    final stats = Stats();
    final transport = Transport(
      token: options.token,
      stats: stats,
      client: MockClient((req) async {
        uris.add(req.url);
        bodies.add(jsonDecode(req.body));
        return http.Response('{"data":{}}', 202);
      }),
    );
    client = CloseYourItClient(
      options,
      transport: transport,
      stats: stats,
      worker: BackgroundWorker(stats: stats),
    );
  }

  final List<Uri> uris = [];
  final List<dynamic> bodies = [];
  late final CloseYourItClient client;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responder);

  final Future<ResponseBody> Function(RequestOptions options) responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      responder(options);

  @override
  void close({bool force = false}) {}
}

void main() {
  group('installErrorHandlers', () {
    late FlutterExceptionHandler? originalFlutter;

    setUp(() {
      originalFlutter = FlutterError.onError;
      FlutterError.onError = (_) {}; // neutralizes the flutter_test reporter
    });
    tearDown(() => FlutterError.onError = originalFlutter);

    test('FlutterError.onError routes to captureException + chaining',
        () async {
      final h = _Harness();
      var prevCalled = false;
      FlutterError.onError = (_) => prevCalled = true;

      final dispose = installErrorHandlers(h.client);
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('boom'),
          stack: StackTrace.current,
        ),
      );
      await h.client.flush();

      expect(h.bodies.length, 1);
      expect(prevCalled, isTrue); // chain preserved
      dispose();
    });

    test('PlatformDispatcher.onError captures and returns true', () async {
      final h = _Harness();
      final dispose = installErrorHandlers(h.client);
      final handled = PlatformDispatcher.instance.onError!(
          StateError('async'), StackTrace.current);
      await h.client.flush();

      expect(handled, isTrue);
      expect(h.bodies.length, 1);
      dispose();
    });

    test('the disposer restores the previous handlers', () {
      final h = _Harness();
      final before = FlutterError.onError;
      final dispose = installErrorHandlers(h.client);
      expect(FlutterError.onError, isNot(same(before)));
      dispose();
      expect(FlutterError.onError, same(before));
    });
  });

  group('CloseYourItDioInterceptor', () {
    Dio buildDio(_Harness h, _FakeAdapter adapter) => Dio()
      ..httpClientAdapter = adapter
      ..interceptors.add(CloseYourItDioInterceptor(client: h.client));

    test('5xx error → captureException', () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 500)),
      );
      try {
        await dio.get<dynamic>('https://api.x.it/orders');
      } on DioException {
        // expected
      }
      await h.client.flush();
      expect(h.uris.single.path, '/api/v1/projects/p1/events');
      final values = (h.bodies.single as Map)['exception'] as Map;
      expect((values['values'] as List), isNotEmpty);
    });

    test('4xx error → breadcrumb only, no event', () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 404)),
      );
      try {
        await dio.get<dynamic>('https://api.x.it/missing');
      } on DioException {
        // expected
      }
      await h.client.flush();
      expect(h.bodies, isEmpty);
      final crumbs =
          h.client.scope.toEventHash(sendPii: false)['breadcrumbs'] as Map;
      expect((crumbs['values'] as List), isNotEmpty);
    });

    test('detection ON: slow call → slow_external_http verdict to /metrics',
        () async {
      final h = _Harness(
        options: CloseYourItOptions(
          endpointUrl: 'https://www.closeyour.it',
          token: 'cyi_t',
          projectId: 'p1',
          detectPerformanceIssues: true,
          slowExternalThresholdMs: 0, // any duration > 0 → verdict
        ),
      );
      h.client.setTraceId('trace-dio');
      final dio = buildDio(
        h,
        _FakeAdapter((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return ResponseBody.fromString('{}', 200);
        }),
      );
      await dio.get<dynamic>('https://api.x.it/v1/orders/12345');
      await h.client.flush();

      final metric = h.bodies
          .firstWhere((b) => (b as Map)['kind'] == 'performance_issue') as Map;
      expect(metric['subtype'], 'slow_external_http');
      expect(metric['http_host'], 'api.x.it');
      expect(metric['http_url'], '/v1/orders/<n>'); // templated id, /v1 kept
      expect(metric['trace_id'], 'trace-dio');
    });

    test('detection OFF (default) → no performance verdict', () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 200)),
      );
      await dio.get<dynamic>('https://api.x.it/orders/12345');
      await h.client.flush();
      expect(h.bodies.where((b) => (b as Map)['kind'] == 'performance_issue'),
          isEmpty);
    });

    test('repeated_http: N identical calls in the window → verdict', () async {
      final h = _Harness(
        options: CloseYourItOptions(
          endpointUrl: 'https://www.closeyour.it',
          token: 'cyi_t',
          projectId: 'p1',
          detectPerformanceIssues: true,
          slowExternalThresholdMs: 1 << 30, // no slow_external_http here
          repeatedHttpThreshold: 3,
          repeatedHttpWindowMs: 5000,
        ),
      );
      // Fixed clock → every call falls in the same window.
      final dio = Dio()
        ..httpClientAdapter =
            _FakeAdapter((_) async => ResponseBody.fromString('{}', 200))
        ..interceptors.add(
            CloseYourItDioInterceptor(client: h.client, nowMs: () => 1000));

      // ids of ≥3 digits → same templated path (/v1/items/<n>) = same key.
      for (var i = 0; i < 3; i++) {
        await dio.get<dynamic>('https://api.x.it/v1/items/${100 + i}');
      }
      await h.client.flush();

      final repeated = h.bodies
          .where((b) => (b as Map)['subtype'] == 'repeated_http')
          .toList();
      expect(repeated.length, 1); // emitted ONCE when the threshold is crossed
      expect((repeated.single as Map)['http_host'], 'api.x.it');
      expect((repeated.single as Map)['query_count'], 3);
    });

    test('onError 5xx: the request context filters sensitive headers',
        () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 500)),
      );
      try {
        await dio.get<dynamic>(
          'https://api.x.it/data',
          options: Options(headers: {
            'Authorization': 'Bearer s',
            'Accept': 'application/json'
          }),
        );
      } on DioException {
        // expected
      }
      await h.client.flush();

      final request =
          (h.bodies.single as Map)['request'] as Map<String, Object?>;
      final headers = request['headers']! as Map<String, Object?>;
      expect(headers.containsKey('Accept'), isTrue);
      expect(headers.containsKey('Authorization'), isFalse);
    });

    test('default: the query does not leak into breadcrumbs (CYDA-8)',
        () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 200)),
      );
      await dio.get<dynamic>(
          'https://api.x.it/orders?token=abc&email=a@b.it&code=123456');

      // breadcrumbs (request + response): no query value
      final crumbs =
          h.client.scope.toEventHash(sendPii: false)['breadcrumbs'] as Map;
      final values = crumbs['values'] as List;
      final serialized = jsonEncode(values);
      expect(serialized.contains('abc'), isFalse);
      expect(serialized.contains('a@b.it'), isFalse);
      expect(serialized.contains('123456'), isFalse);
      for (final crumb in values) {
        expect(
            ((crumb as Map)['data'] as Map)['url'], 'https://api.x.it/orders');
      }
    });

    test('onError 5xx: the query does not leak into the event context (CYDA-8)',
        () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 500)),
      );
      try {
        await dio.get<dynamic>('https://api.x.it/pay?token=abc&cvv=123');
      } on DioException {
        // expected
      }
      await h.client.flush();

      final body = h.bodies.single as Map;
      final serialized = jsonEncode(body);
      expect(serialized.contains('abc'), isFalse);
      expect(serialized.contains('cvv=123'), isFalse);
      final response =
          (body['contexts'] as Map)['response'] as Map<String, Object?>;
      expect(response['url'], 'https://api.x.it/pay');
      // The event request snapshot is also stripped of the query.
      final request = body['request'] as Map<String, Object?>;
      expect(request['url'], 'https://api.x.it/pay');
    });

    test(
        'sendPii true: query in the breadcrumb but sensitive values redacted (CYDA-8)',
        () async {
      final h = _Harness(
        options: CloseYourItOptions(
          endpointUrl: 'https://www.closeyour.it',
          token: 'cyi_t',
          projectId: 'p1',
          sendPii: true,
        ),
      );
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 200)),
      );
      await dio.get<dynamic>('https://api.x.it/orders?token=abc&page=2');

      final crumbs =
          h.client.scope.toEventHash(sendPii: true)['breadcrumbs'] as Map;
      final urls = (crumbs['values'] as List)
          .map((c) => ((c as Map)['data'] as Map)['url'])
          .toList();
      expect(urls,
          everyElement('https://api.x.it/orders?token=[FILTERED]&page=2'));
    });

    test(
        'concurrency: the error uses its own request context, not the concurrent one (CYDA-9)',
        () async {
      final h = _Harness();
      // A (fails) starts first but answers late; B (success) starts later
      // and answers right away. With a mutable global request, B overwrote the
      // shared scope and A inherited the context of B.
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          if (options.uri.host == 'api-a.x.it') {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return ResponseBody.fromString('{}', 500);
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return ResponseBody.fromString('{}', 200);
        })
        ..interceptors.add(CloseYourItDioInterceptor(client: h.client));

      Future<void> failing() async {
        try {
          await dio.get<dynamic>('https://api-a.x.it/slow-fail');
        } on DioException {
          // expected
        }
      }

      final a = failing();
      final b = dio.get<dynamic>('https://api-b.x.it/fast-ok');
      await Future.wait<dynamic>([a, b]);
      await h.client.flush();

      // Only the 5xx generates an event: it must carry the context of A.
      final event = h.bodies.single as Map;
      expect((event['request'] as Map)['url'], 'https://api-a.x.it/slow-fail');
      expect((event['contexts'] as Map)['response'],
          containsPair('url', 'https://api-a.x.it/slow-fail'));
    });

    test(
        'concurrency: two errors with inverted completion each keep their own context (CYDA-9)',
        () async {
      final h = _Harness();
      // Both fail: A starts first but answers late, B starts later but
      // answers right away → completion order inverted relative to start.
      final dio = Dio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          final delayMs = options.uri.host == 'api-a.x.it' ? 40 : 5;
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          return ResponseBody.fromString('{}', 500);
        })
        ..interceptors.add(CloseYourItDioInterceptor(client: h.client));

      Future<void> fire(String url) async {
        try {
          await dio.get<dynamic>(url);
        } on DioException {
          // expected
        }
      }

      await Future.wait<void>([
        fire('https://api-a.x.it/orders'),
        fire('https://api-b.x.it/items'),
      ]);
      await h.client.flush();

      final urls =
          h.bodies.map((b) => ((b as Map)['request'] as Map)['url']).toSet();
      expect(urls, {
        'https://api-a.x.it/orders',
        'https://api-b.x.it/items',
      });
    });

    test(
        'cleanup: a Dio request does not leave its context in the global scope (CYDA-9)',
        () async {
      final h = _Harness();
      final dio = buildDio(
        h,
        _FakeAdapter((_) async => ResponseBody.fromString('{}', 200)),
      );
      await dio.get<dynamic>('https://api.x.it/orders');

      // The interceptor does not mutate the shared scope.
      expect(h.client.scope.request, isNull);

      // A non-Dio error captured afterwards does not inherit the request context.
      h.client.captureException(StateError('boom'));
      await h.client.flush();
      final event = h.bodies.single as Map;
      expect(event.containsKey('request'), isFalse);
    });

    group('W3C Trace Context propagation (CYDA-16)', () {
      const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
      const spanId = '00f067aa0ba902b7';

      // Captures the headers actually going out (after the interceptor).
      Dio tracingDio(
        _Harness h, {
        String Function()? spanIdGenerator,
        required Map<String, dynamic> captured,
      }) =>
          Dio()
            ..httpClientAdapter = _FakeAdapter((options) async {
              captured
                ..clear()
                ..addAll(options.headers);
              return ResponseBody.fromString('{}', 200);
            })
            ..interceptors.add(CloseYourItDioInterceptor(
              client: h.client,
              spanIdGenerator: spanIdGenerator ?? () => spanId,
            ));

      _Harness tracing({List<String> allow = const ['api.x.it']}) => _Harness(
            options: CloseYourItOptions(
              endpointUrl: 'https://www.closeyour.it',
              token: 'cyi_t',
              projectId: 'p1',
              propagateTraceContext: true,
              tracePropagationAllowlist: allow,
            ),
          );

      test(
          'allowed host + active trace → valid traceparent and tracestate (Scenario 1)',
          () async {
        final h = tracing();
        h.client.setTraceId(traceId); // active trace, W3C-compliant id
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        await dio.get<dynamic>('https://api.x.it/orders');

        expect(headers['traceparent'], '00-$traceId-$spanId-01');
        expect(headers['tracestate'], 'cyi=1');
      });

      test('default opt-out → no header propagated (opt-in)', () async {
        final h = _Harness(); // propagateTraceContext: false (default)
        h.client.setTraceId(traceId);
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        await dio.get<dynamic>('https://api.x.it/orders');

        expect(headers.containsKey('traceparent'), isFalse);
        expect(headers.containsKey('tracestate'), isFalse);
      });

      test('external host (outside the allowlist) → no header propagated',
          () async {
        final h = tracing(allow: const ['api.x.it']);
        h.client.setTraceId(traceId);
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        await dio.get<dynamic>('https://evil.other.com/collect');

        expect(headers.containsKey('traceparent'), isFalse);
        expect(headers.containsKey('tracestate'), isFalse);
      });

      test(
          'nested request: a valid upstream traceparent continues the same trace with a new span',
          () async {
        final h = tracing();
        h.client.setTraceId(traceId); // different from the upstream trace
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        const upstream =
            '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';
        await dio.get<dynamic>(
          'https://api.x.it/orders',
          options: Options(headers: {'traceparent': upstream}),
        );

        // same trace-id as upstream, but our parent-id (new span)
        expect(headers['traceparent'],
            '00-0af7651916cd43dd8448eb211c80319c-$spanId-01');
      });

      test(
          'malformed upstream traceparent → dropped and regenerated from the active trace',
          () async {
        final h = tracing();
        h.client.setTraceId(traceId);
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        await dio.get<dynamic>(
          'https://api.x.it/orders',
          options: Options(headers: {'traceparent': 'not-a-traceparent'}),
        );

        // uses the active trace, well-formed header (the broken one is not propagated)
        expect(headers['traceparent'], '00-$traceId-$spanId-01');
      });

      test('sensitive baggage and tracestate filtered before propagation',
          () async {
        final h = tracing();
        h.client.setTraceId(traceId);
        final headers = <String, dynamic>{};
        final dio = tracingDio(h, captured: headers);

        await dio.get<dynamic>(
          'https://api.x.it/orders',
          options: Options(headers: {
            'baggage': 'token=abc,plan=pro',
            'tracestate': 'authorization=zzz,rojo=ok',
          }),
        );

        expect(headers['baggage'], 'plan=pro'); // token=... removed
        expect(headers['tracestate'],
            'cyi=1,rojo=ok'); // authorization=... removed
      });

      test(
          'concurrency: parallel requests share the trace-id but have distinct spans',
          () async {
        final h = tracing();
        h.client.setTraceId(traceId);

        var counter = 0;
        String nextSpan() {
          counter++;
          return counter.toRadixString(16).padLeft(16, '0');
        }

        final seen = <Map<String, dynamic>>[];
        final dio = Dio()
          ..httpClientAdapter = _FakeAdapter((options) async {
            seen.add(Map<String, dynamic>.from(options.headers));
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return ResponseBody.fromString('{}', 200);
          })
          ..interceptors.add(CloseYourItDioInterceptor(
            client: h.client,
            spanIdGenerator: nextSpan,
          ));

        await Future.wait<dynamic>([
          dio.get<dynamic>('https://api.x.it/a'),
          dio.get<dynamic>('https://api.x.it/b'),
        ]);

        final parents = seen.map((h) => h['traceparent'] as String).toList();
        final traceIds = parents.map((p) => p.split('-')[1]).toSet();
        final spanIds = parents.map((p) => p.split('-')[2]).toSet();
        expect(traceIds, {traceId}); // same trace for the logical unit
        expect(spanIds.length, 2); // distinct spans: no swapping
      });
    });
  });

  group('CloseYourItNavigatorObserver', () {
    test('didPush records a navigation breadcrumb', () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      final route = PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/home'),
        pageBuilder: (_, __, ___) => const SizedBox(),
      );
      observer.didPush(route, null);

      final crumbs =
          h.client.scope.toEventHash(sendPii: false)['breadcrumbs']! as Map;
      final values = crumbs['values']! as List;
      final last = values.last as Map;
      expect(last['category'], 'navigation');
      expect((last['data']! as Map)['to'], '/home');
    });

    test('didPop/didReplace/didRemove record breadcrumbs', () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      PageRouteBuilder<void> route(String name) => PageRouteBuilder<void>(
            settings: RouteSettings(name: name),
            pageBuilder: (_, __, ___) => const SizedBox(),
          );

      observer
        ..didPop(route('/a'), route('/b'))
        ..didReplace(newRoute: route('/c'), oldRoute: route('/a'))
        ..didRemove(route('/d'), route('/c'));

      final crumbs =
          h.client.scope.toEventHash(sendPii: false)['breadcrumbs']! as Map;
      final ops = (crumbs['values']! as List)
          .map((c) => (c as Map)['message'])
          .toList();
      expect(ops, containsAll(['didPop', 'didReplace', 'didRemove']));
    });

    PageRouteBuilder<void> route(String name) => PageRouteBuilder<void>(
          settings: RouteSettings(name: name),
          pageBuilder: (_, __, ___) => const SizedBox(),
        );

    test('didPush rotates the trace_id (new logical unit per screen)', () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      final before = h.client.scope.ensureTraceId();
      observer.didPush(route('/home'), null);
      final after = h.client.scope.traceId;
      expect(after, isNotNull);
      expect(after, isNot(before));
    });

    test('didPop and didReplace rotate the trace_id', () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);

      final t0 = h.client.scope.ensureTraceId();
      observer.didPop(route('/a'), route('/b'));
      final t1 = h.client.scope.traceId;
      expect(t1, isNot(t0));

      observer.didReplace(newRoute: route('/c'), oldRoute: route('/a'));
      final t2 = h.client.scope.traceId;
      expect(t2, isNot(t1));
    });

    test(
        'didRemove of a route never on top does NOT rotate the trace_id (route behind)',
        () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      final before = h.client.scope.ensureTraceId();
      observer.didRemove(route('/d'), route('/c'));
      expect(h.client.scope.traceId, before);
    });

    test(
        'didRemove of the top screen rotates the trace_id (previousRoute becomes visible)',
        () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      final top = route('/detail');
      observer.didPush(top, route('/list')); // /detail = current screen
      final onDetail = h.client.scope.traceId;
      expect(onDetail, isNotNull);

      // Navigator.removeRoute of the current screen → /list becomes visible again:
      // it is a new logical unit, the trace must rotate.
      observer.didRemove(top, route('/list'));
      expect(h.client.scope.traceId, isNotNull);
      expect(h.client.scope.traceId, isNot(onDetail));
    });

    test(
        'didRemove of a buried route (not on top) does NOT rotate the trace_id',
        () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      observer.didPush(route('/current'), null); // current screen on top
      final onCurrent = h.client.scope.traceId;

      // Removal of a route other than the top one (e.g. pushAndRemoveUntil):
      // the visible screen does not change → same trace.
      observer.didRemove(route('/buried'), route('/root'));
      expect(h.client.scope.traceId, onCurrent);
    });

    test('didRemove of the top screen does NOT overwrite a manual trace_id',
        () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      h.client.setTraceId('pinned-flow');
      final top = route('/step2');
      observer.didPush(top, route('/step1'));
      observer.didRemove(top, route('/step1'));
      expect(h.client.scope.traceId, 'pinned-flow'); // the pin survives
    });

    test('navigation does NOT overwrite a manual trace_id (multi-screen flow)',
        () {
      final h = _Harness();
      final observer = CloseYourItNavigatorObserver(client: h.client);
      h.client.setTraceId('checkout-flow');
      observer.didPush(route('/address'), route('/cart'));
      observer.didReplace(
          newRoute: route('/payment'), oldRoute: route('/address'));
      expect(
          h.client.scope.traceId, 'checkout-flow'); // survives screen changes
    });
  });

  group('CloseYourItLifecycleObserver', () {
    test('paused → flush of the buffered logs', () async {
      final h = _Harness();
      final observer = CloseYourItLifecycleObserver(h.client);
      h.client.log(LogLevel.info, 'pending');
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await h.client.flush();
      expect(h.uris.single.path, '/api/v1/projects/p1/logs');
    });

    test('resumed → no flush', () {
      final h = _Harness();
      final observer = CloseYourItLifecycleObserver(h.client);
      h.client.log(LogLevel.info, 'pending');
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(h.bodies, isEmpty); // nothing sent until a flush happens
    });

    // Lock: the observer alone (without an explicit flush) must drain the buffered
    // logs when the app goes to the background/terminates — parity with the gem's
    // `at_exit`. We do NOT call client.flush(): only the observer.
    for (final state in const [
      AppLifecycleState.detached,
      AppLifecycleState.hidden,
    ]) {
      test('$state → log flush without an explicit flush', () async {
        final h = _Harness();
        h.client.log(LogLevel.info, 'pending');
        CloseYourItLifecycleObserver(h.client)
            .didChangeAppLifecycleState(state);
        // The observer does unawaited(client.flush()): pump the event loop.
        for (var i = 0; i < 50 && h.bodies.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(h.uris.single.path, '/api/v1/projects/p1/logs');
        final batch = h.bodies.single as List;
        expect((batch.single as Map)['message'], 'pending');
      });
    }
  });

  group('CloseYourItFrameTimingObserver (jank)', () {
    _Harness perfHarness() => _Harness(
          options: CloseYourItOptions(
            endpointUrl: 'https://www.closeyour.it',
            token: 'cyi_t',
            projectId: 'p1',
            detectPerformanceIssues: true,
            jankFrameBudgetMs: 32,
          ),
        );

    test('over-budget frame → jank verdict with the current route', () async {
      final h = perfHarness();
      h.client.currentRoute = 'FeedScreen';
      CloseYourItFrameTimingObserver(h.client).handleFrame(50);
      await h.client.flush();

      final jank = h.bodies
          .firstWhere((b) => (b as Map)['kind'] == 'performance_issue') as Map;
      expect(jank['subtype'], 'jank');
      expect(jank['route'], 'FeedScreen');
    });

    test('frame within budget → no verdict', () async {
      final h = perfHarness();
      CloseYourItFrameTimingObserver(h.client).handleFrame(16);
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });
  });

  group('RebuildWindow (rebuild_storm counting)', () {
    test('hit() true on the N-th rebuild within the window', () {
      final w = RebuildWindow(threshold: 3, windowMs: 1000);
      expect(w.hit(1000), isFalse); // 1
      expect(w.hit(1100), isFalse); // 2
      expect(w.hit(1200), isTrue); // 3 = threshold
    });

    test('rebuilds outside the window do not count', () {
      final w = RebuildWindow(threshold: 3, windowMs: 1000);
      expect(w.hit(1000), isFalse); // 1
      expect(w.hit(5000), isFalse); // the first one left the window → 1
      expect(w.hit(5100), isFalse); // 2
      expect(w.hit(5200), isTrue); // 3
    });
  });

  group('CloseYourItRebuildProbe', () {
    testWidgets('renders the child (transparent)', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: CloseYourItRebuildProbe(
          label: 'ProductCard',
          child: Text('content'),
        ),
      ));
      expect(find.text('content'), findsOneWidget);
    });
  });
}
