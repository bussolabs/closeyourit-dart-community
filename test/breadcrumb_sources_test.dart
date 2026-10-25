import 'dart:async';
import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/breadcrumb_throttle.dart';
import 'package:closeyourit/src/integrations/connectivity_observer.dart';
import 'package:closeyourit/src/integrations/lifecycle_observer.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';

/// Harness with a fake transport: collects the sent payloads.
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

/// Fake connectivity source (no plugin): initial state + stream
/// driven by the test. [seedDelay] delays `current()` to simulate a seed that
/// completes after a real event (the plugin call is asynchronous).
class _FakeConnectivitySource implements ConnectivitySource {
  _FakeConnectivitySource(this._current, {this.seedDelay = Duration.zero});

  final CloseYourItConnectivity _current;
  final Duration seedDelay;
  final StreamController<CloseYourItConnectivity> _controller =
      StreamController<CloseYourItConnectivity>.broadcast();

  @override
  Stream<CloseYourItConnectivity> get onChange => _controller.stream;

  @override
  Future<CloseYourItConnectivity> current() => seedDelay == Duration.zero
      ? Future<CloseYourItConnectivity>.value(_current)
      : Future<CloseYourItConnectivity>.delayed(seedDelay, () => _current);

  void emit(CloseYourItConnectivity status) => _controller.add(status);

  void emitError(Object error) => _controller.addError(error);
}

class _MockConnectivity extends Mock implements Connectivity {}

CloseYourItOptions _opts({
  bool lifecycle = false,
  bool connectivity = false,
  bool tap = false,
  int throttleMs = 500,
}) =>
    CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      captureLifecycleBreadcrumbs: lifecycle,
      captureConnectivityBreadcrumbs: connectivity,
      captureTapBreadcrumbs: tap,
      breadcrumbThrottleMs: throttleMs,
    );

List<Breadcrumb> _crumbs(CloseYourItClient client) =>
    client.scope.breadcrumbs.toList();

void main() {
  group('BreadcrumbThrottle', () {
    test('leading-edge: the first passes, later ones in the window do not', () {
      final throttle = BreadcrumbThrottle(minIntervalMs: 500);
      expect(throttle.allow(1000), isTrue); // first
      expect(throttle.allow(1100), isFalse); // within 500
      expect(throttle.allow(1400), isFalse); // still within 500
      expect(throttle.allow(1500), isTrue); // past the window
      expect(throttle.allow(1600), isFalse); // new window
    });

    test('minIntervalMs <= 0 disables the throttle (every event passes)', () {
      final throttle = BreadcrumbThrottle(minIntervalMs: 0);
      expect(throttle.allow(1), isTrue);
      expect(throttle.allow(1), isTrue);
      expect(throttle.allow(1), isTrue);
    });
  });

  group('mapConnectivityResults', () {
    test('single type → matching primary type', () {
      expect(mapConnectivityResults([ConnectivityResult.wifi]),
          CloseYourItConnectivity.wifi);
      expect(mapConnectivityResults([ConnectivityResult.mobile]),
          CloseYourItConnectivity.cellular);
      expect(mapConnectivityResults([ConnectivityResult.ethernet]),
          CloseYourItConnectivity.ethernet);
      expect(mapConnectivityResults([ConnectivityResult.vpn]),
          CloseYourItConnectivity.vpn);
      expect(mapConnectivityResults([ConnectivityResult.bluetooth]),
          CloseYourItConnectivity.bluetooth);
      expect(mapConnectivityResults([ConnectivityResult.none]),
          CloseYourItConnectivity.none);
    });

    test('several transports → priority wins (wifi > cellular)', () {
      expect(
        mapConnectivityResults(
            [ConnectivityResult.mobile, ConnectivityResult.wifi]),
        CloseYourItConnectivity.wifi,
      );
      expect(
        mapConnectivityResults(
            [ConnectivityResult.mobile, ConnectivityResult.vpn]),
        CloseYourItConnectivity.cellular,
      );
    });

    test('empty list → unknown; satellite → other', () {
      expect(mapConnectivityResults(const []), CloseYourItConnectivity.unknown);
      expect(mapConnectivityResults([ConnectivityResult.other]),
          CloseYourItConnectivity.other);
    });
  });

  group('CloseYourItLifecycleObserver — breadcrumb', () {
    test('opt-in ON: paused → app.lifecycle breadcrumb + log flush', () async {
      final h = _Harness(options: _opts(lifecycle: true));
      final observer = CloseYourItLifecycleObserver(h.client);
      h.client.log(LogLevel.info, 'pending');

      observer.didChangeAppLifecycleState(AppLifecycleState.paused);

      final crumb = _crumbs(h.client).last;
      expect(crumb.category, 'app.lifecycle');
      expect(crumb.data?['state'], 'paused');

      await h.client.flush();
      expect(h.uris.single.path, '/api/v1/projects/p1/logs'); // flush happened
    });

    test('opt-out (default): paused → NO breadcrumb but the flush stays on',
        () async {
      final h = _Harness(); // captureLifecycleBreadcrumbs = false
      h.client.log(LogLevel.info, 'pending');

      CloseYourItLifecycleObserver(h.client)
          .didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(_crumbs(h.client), isEmpty); // no lifecycle breadcrumb
      // The observer does unawaited(flush): the log is drained anyway.
      for (var i = 0; i < 50 && h.bodies.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.uris.single.path, '/api/v1/projects/p1/logs');
    });

    test('consecutive identical states deduplicated', () {
      final h = _Harness(options: _opts(lifecycle: true));
      CloseYourItLifecycleObserver(h.client)
        ..didChangeAppLifecycleState(AppLifecycleState.paused)
        ..didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(_crumbs(h.client).length, 1);
    });

    test('resumed → breadcrumb but no flush', () {
      final h = _Harness(options: _opts(lifecycle: true));
      h.client.log(LogLevel.info, 'pending');
      CloseYourItLifecycleObserver(h.client)
          .didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(_crumbs(h.client).single.data?['state'], 'resumed');
      expect(h.bodies, isEmpty); // resumed does not flush
    });
  });

  group('CloseYourItConnectivityObserver — breadcrumb', () {
    test('state change → synthetic network breadcrumb', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true));
        final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();
        async.flushMicrotasks(); // seed wifi (leading), opens the window

        final seed = _crumbs(h.client).single;
        expect(seed.category, 'device.connectivity');
        expect(seed.data?['connectivity'], 'wifi');

        async.elapse(const Duration(milliseconds: 500)); // closes the window
        source.emit(CloseYourItConnectivity.none);
        async.flushMicrotasks(); // window closed → leading none
        expect(_crumbs(h.client).last.data?['connectivity'], 'none');
      });
    });

    test('unchanged state → no second breadcrumb (dedup)', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true));
        final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();
        async.flushMicrotasks(); // seed wifi
        async.elapse(const Duration(milliseconds: 500));

        source.emit(CloseYourItConnectivity.wifi); // same state as the seed
        async.flushMicrotasks();
        expect(_crumbs(h.client).length, 1);
      });
    });

    test(
        'rapid toggles: intermediate toggles are suppressed but the settled state '
        'is recorded (it does not stay stale)', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true, throttleMs: 500));
        final source = _FakeConnectivitySource(CloseYourItConnectivity.none);
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();
        async.flushMicrotasks(); // seed none (leading), opens the window
        final baseline = _crumbs(h.client).length; // 1

        // Flapping during the window: nothing emitted, but the last one is remembered.
        source.emit(CloseYourItConnectivity.wifi);
        async.flushMicrotasks();
        source.emit(CloseYourItConnectivity.cellular);
        async.flushMicrotasks();
        source.emit(CloseYourItConnectivity.wifi); // real final state
        async.flushMicrotasks();
        expect(_crumbs(h.client).length, baseline); // nothing during the window

        async.elapse(const Duration(milliseconds: 500)); // trailing
        // The settled state (wifi) is emitted; the intermediate cellular is not.
        expect(_crumbs(h.client).length, baseline + 1);
        expect(_crumbs(h.client).last.data?['connectivity'], 'wifi');
        final types =
            _crumbs(h.client).map((c) => c.data?['connectivity']).toList();
        expect(types, ['none', 'wifi']); // cellular suppressed, wifi recovered
      });
    });

    test('opt-out: no connectivity breadcrumb', () {
      fakeAsync((async) {
        final h = _Harness(); // captureConnectivityBreadcrumbs = false
        final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();
        async.flushMicrotasks();
        source.emit(CloseYourItConnectivity.none);
        async.flushMicrotasks();
        expect(_crumbs(h.client), isEmpty);
      });
    });

    test('stream error (permissions/plugin) swallowed, no crash', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true));
        final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();
        async.flushMicrotasks();
        final before = _crumbs(h.client).length;

        source.emitError(PlatformException(code: 'PERMISSION_DENIED'));
        async.flushMicrotasks();

        // The error neither adds a breadcrumb nor propagates.
        expect(_crumbs(h.client).length, before);
      });
    });

    test('stale seed ignored: a real event before the seed wins', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true, throttleMs: 500));
        // The seed (`current()`) answers late, after the stream has already
        // observed the real network: the initial state is stale by now.
        final source = _FakeConnectivitySource(
          CloseYourItConnectivity.wifi,
          seedDelay: const Duration(milliseconds: 100),
        );
        CloseYourItConnectivityObserver(client: h.client, source: source)
            .install();

        source.emit(CloseYourItConnectivity.none); // real network: none
        async.flushMicrotasks(); // none recorded (leading)
        expect(_crumbs(h.client).last.data?['connectivity'], 'none');
        final afterEvent = _crumbs(h.client).length;

        async.elapse(
            const Duration(milliseconds: 100)); // the seed completes now
        async.flushMicrotasks();
        // The seed (wifi) is stale → ignored, no inverted state.
        expect(_crumbs(h.client).length, afterEvent);
        expect(
          _crumbs(h.client).every((c) => c.data?['connectivity'] != 'wifi'),
          isTrue,
        );
      });
    });

    test('dispose stops the subscription and the pending debounce', () {
      fakeAsync((async) {
        final h = _Harness(options: _opts(connectivity: true));
        final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
        final observer =
            CloseYourItConnectivityObserver(client: h.client, source: source)
              ..install();
        async.flushMicrotasks(); // seed wifi
        observer.dispose();
        async.flushMicrotasks();

        source.emit(CloseYourItConnectivity.none); // after dispose: ignored
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1)); // no leftover trailing
        expect(
          _crumbs(h.client).every((c) => c.data?['connectivity'] != 'none'),
          isTrue,
        );
      });
    });
  });

  group('PluginConnectivitySource — plugin unavailable / permissions', () {
    test('checkConnectivity that throws → current() returns unknown', () async {
      final mock = _MockConnectivity();
      when(mock.checkConnectivity).thenThrow(MissingPluginException('no impl'));
      final source = PluginConnectivitySource(mock);
      expect(await source.current(), CloseYourItConnectivity.unknown);
    });

    test('checkConnectivity with a value → current() maps the type', () async {
      final mock = _MockConnectivity();
      when(mock.checkConnectivity)
          .thenAnswer((_) async => [ConnectivityResult.mobile]);
      final source = PluginConnectivitySource(mock);
      expect(await source.current(), CloseYourItConnectivity.cellular);
    });
  });

  group('CloseYourItUserInteraction — tap breadcrumb', () {
    testWidgets(
        'tap ON → ui.tap breadcrumb with the route, without widget data',
        (tester) async {
      final h = _Harness(options: _opts(tap: true));
      h.client.currentRoute = '/checkout';

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: CloseYourItUserInteraction(
          client: h.client,
          nowMs: () => 0,
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: const Text('Pay now Mario Rossi'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Pay now Mario Rossi'));

      final crumb = _crumbs(h.client).last;
      expect(crumb.category, 'ui.tap');
      expect(crumb.type, 'user');
      expect(crumb.data?['route'], '/checkout');
      // Privacy: the tapped widget text does not end up in the breadcrumb.
      expect(jsonEncode(crumb.toJson()).contains('Mario Rossi'), isFalse);
    });

    testWidgets('rapid taps suppressed by the throttle', (tester) async {
      final h = _Harness(options: _opts(tap: true, throttleMs: 500));
      var clock = 0;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: CloseYourItUserInteraction(
          client: h.client,
          nowMs: () => clock,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const SizedBox.expand(),
          ),
        ),
      ));

      await tester.tapAt(const Offset(50, 50)); // @0 → passes
      clock = 100;
      await tester.tapAt(const Offset(50, 50)); // @100 → suppressed
      expect(_crumbs(h.client).length, 1);

      clock = 700;
      await tester.tapAt(const Offset(50, 50)); // past the window → passes
      expect(_crumbs(h.client).length, 2);
    });

    testWidgets('tap OFF (default) → no breadcrumb', (tester) async {
      final h = _Harness(); // captureTapBreadcrumbs = false
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: CloseYourItUserInteraction(
          client: h.client,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const SizedBox.expand(),
          ),
        ),
      ));
      await tester.tapAt(const Offset(20, 20));
      expect(_crumbs(h.client), isEmpty);
    });
  });

  group('Scenario 1 — error after a network/lifecycle change', () {
    test(
        'the event attaches the synthetic network and lifecycle breadcrumbs, without widget data',
        () async {
      // throttleMs: 0 → passthrough (no Timer): a linear test with the real worker.
      final h = _Harness(
        options: _opts(connectivity: true, lifecycle: true, throttleMs: 0),
      );

      // The app changes connectivity...
      final source = _FakeConnectivitySource(CloseYourItConnectivity.wifi);
      CloseYourItConnectivityObserver(client: h.client, source: source)
          .install();
      await pumpEventQueue(); // seed wifi
      source.emit(CloseYourItConnectivity.none);
      await pumpEventQueue();

      // ...and goes to the background.
      CloseYourItLifecycleObserver(h.client)
          .didChangeAppLifecycleState(AppLifecycleState.paused);

      // Shortly after an error occurs.
      h.client.captureException(StateError('boom'));
      await h.client.flush();

      final event = h.bodies.firstWhere((b) => (b as Map)['exception'] != null)
          as Map<String, dynamic>;
      final values = (((event['breadcrumbs'] as Map)['values']) as List)
          .cast<Map<String, dynamic>>();
      final categories = values.map((c) => c['category']).toSet();
      expect(categories, containsAll(['device.connectivity', 'app.lifecycle']));

      final network =
          values.lastWhere((c) => c['category'] == 'device.connectivity');
      expect((network['data'] as Map)['connectivity'], 'none');
      final lifecycle =
          values.firstWhere((c) => c['category'] == 'app.lifecycle');
      expect((lifecycle['data'] as Map)['state'], 'paused');
    });
  });
}
