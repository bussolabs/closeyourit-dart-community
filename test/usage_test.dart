import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Usage telemetry (CYDA-22): which parts of the app actually run.
///
/// The `usages` channel is **Bearer-only** on the backend, so with the public DSN
/// it stays silent like metrics and logs; it is opt-in because a registry on by itself
/// would open a periodic window nobody asked for.
class _Harness {
  _Harness(CloseYourItOptions options, {int status = 202}) {
    final stats = Stats();
    client = CloseYourItClient(
      options,
      stats: stats,
      worker: BackgroundWorker(stats: stats, maxQueue: options.maxQueue),
      transport: Transport(
        token: options.token,
        publicKey: options.publicKey,
        stats: stats,
        client: MockClient((req) async {
          uris.add(req.url);
          headers.add(req.headers);
          bodies.add(jsonDecode(req.body));
          return http.Response('{"data":{"accepted":1}}', status);
        }),
      ),
    );
  }

  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];
  final List<dynamic> bodies = [];
  late final CloseYourItClient client;

  Map<String, Object?> get firstBody =>
      (bodies.first as Map).cast<String, Object?>();

  List<Map<String, Object?>> get firstSymbols =>
      (firstBody['symbols']! as List).cast<Map<String, Object?>>();
}

CloseYourItOptions options({
  bool enabled = true,
  bool usageEnabled = true,
  String publicKey = '',
  String? release = '1.2.3',
  int usageMaxSymbols = 2000,
  String environment = 'production',
}) =>
    CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      publicKey: publicKey,
      projectId: 'p1',
      environment: environment,
      release: release,
      enabled: enabled,
      usageEnabled: usageEnabled,
      usageMaxSymbols: usageMaxSymbols,
    );

void main() {
  group('client — sending usage telemetry', () {
    test('a recorded symbol reaches /usages with the Bearer', () async {
      final h = _Harness(options());
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();

      expect(h.uris.single.path, '/api/v1/projects/p1/usages');
      expect(h.headers.single['Authorization'], 'Bearer cyi_t');
      expect(h.firstSymbols.single['kind'], 'custom');
      expect(h.firstSymbols.single['symbol'], 'checkout.coupon');
      expect(h.firstSymbols.single['count'], 1);
      expect(h.firstSymbols.single['last_seen_at'], isA<String>());
    });

    test('the payload carries environment, release, sdk and the window',
        () async {
      final h = _Harness(options());
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();

      expect(h.firstBody['environment'], 'production');
      expect(h.firstBody['release'], '1.2.3');
      expect(h.firstBody['sdk'],
          {'name': closeYourItSdkName, 'version': closeYourItSdkVersion});
      expect(h.firstBody['truncated'], isFalse);
      expect(
          DateTime.parse(h.firstBody['window_started_at']! as String)
              .isAfter(DateTime.utc(2020)),
          isTrue);
      expect(
          DateTime.parse(h.firstBody['window_ended_at']! as String)
              .isAfter(DateTime.utc(2020)),
          isTrue);
    });

    test('without a release the key is omitted instead of travelling as null',
        () async {
      final h = _Harness(options(release: null));
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();

      expect(h.firstBody.containsKey('release'), isFalse);
    });

    test('recordUsage with kind route records a screen', () async {
      final h = _Harness(options());
      h.client.recordUsage('CheckoutScreen', kind: 'route');
      await h.client.flush();

      expect(h.firstSymbols.single['kind'], 'route');
      expect(h.firstSymbols.single['symbol'], 'CheckoutScreen');
    });

    test('several records in the same window travel in a single send',
        () async {
      final h = _Harness(options());
      h.client
        ..recordUsage('a')
        ..recordUsage('b')
        ..recordUsage('a');
      await h.client.flush();

      expect(h.bodies.length, 1);
      expect(h.firstSymbols.length, 2);
    });

    test('no record → nothing sent', () async {
      final h = _Harness(options());
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('beyond the cap the payload declares truncated', () async {
      final h = _Harness(options(usageMaxSymbols: 1));
      h.client
        ..recordUsage('a')
        ..recordUsage('b');
      await h.client.flush();

      expect(h.firstBody['truncated'], isTrue);
      expect(h.firstSymbols.length, 1);
    });

    test('close sends the rest of the open window', () async {
      final h = _Harness(options());
      h.client.recordUsage('checkout.coupon');
      await h.client.close();

      expect(h.uris.single.path, '/api/v1/projects/p1/usages');
    });

    test('after close a late record does not reopen a timer', () {
      fakeAsync((async) {
        // Client never used for usage telemetry before close: the registry
        // does not exist yet, so a late record would create it from
        // scratch — with a periodic timer on forever on a shut-down client.
        final h = _Harness(options());
        h.client.close();
        async.flushMicrotasks();

        h.client.recordUsage('checkout.coupon');

        expect(async.periodicTimerCount, 0);
        async.elapse(const Duration(hours: 1));
        expect(h.bodies, isEmpty);
      });
    });
  });

  group('client — when usage telemetry stays silent', () {
    test('usageEnabled false (default) → nothing sent', () async {
      final h = _Harness(options(usageEnabled: false));
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('public DSN → nothing sent: the usage channel is Bearer-only',
        () async {
      final h = _Harness(options(publicKey: 'abc123'));
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('disabled client → nothing sent', () async {
      final h = _Harness(options(enabled: false));
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('a symbol outside the contract is not sent', () async {
      final h = _Harness(options());
      h.client
        ..recordUsage('checkout?user=7')
        ..recordUsage('CheckoutScreen', kind: 'screen');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });

    test('beforeSend can drop the flush', () async {
      final h = _Harness(CloseYourItOptions(
        endpointUrl: 'https://www.closeyour.it',
        token: 'cyi_t',
        projectId: 'p1',
        usageEnabled: true,
        beforeSend: (_) => null,
      ));
      h.client.recordUsage('checkout.coupon');
      await h.client.flush();
      expect(h.bodies, isEmpty);
    });
  });

  group('configuration', () {
    test('usage telemetry is opt-in: off by default', () {
      final o = CloseYourItOptions(
          endpointUrl: 'https://www.closeyour.it',
          token: 'cyi_t',
          projectId: 'p1');
      expect(o.usageEnabled, isFalse);
      expect(o.usageFlushInterval, const Duration(minutes: 5));
      expect(o.usageMaxSymbols, 2000);
    });

    test('usagesUri points to the project usage ingest', () {
      expect(
        options().usagesUri.toString(),
        'https://www.closeyour.it/api/v1/projects/p1/usages',
      );
    });
  });

  group('façade CloseYourIt', () {
    late _Harness h;

    setUp(() async {
      h = _Harness(options());
      await CloseYourIt.init(h.client.options,
          client: h.client, installIntegrations: false);
    });

    tearDown(() => CloseYourIt.close());

    test('used records a literal key as custom', () async {
      CloseYourIt.used('checkout.coupon');
      await CloseYourIt.flush();

      expect(h.firstSymbols.single['kind'], 'custom');
      expect(h.firstSymbols.single['symbol'], 'checkout.coupon');
    });

    test('usedRoute records a screen as route', () async {
      CloseYourIt.usedRoute('CheckoutScreen');
      await CloseYourIt.flush();

      expect(h.firstSymbols.single['kind'], 'route');
      expect(h.firstSymbols.single['symbol'], 'CheckoutScreen');
    });
  });

  group('façade without init', () {
    test('used and usedRoute are silent no-ops', () {
      expect(() => CloseYourIt.used('checkout.coupon'), returnsNormally);
      expect(() => CloseYourIt.usedRoute('CheckoutScreen'), returnsNormally);
    });
  });
}
