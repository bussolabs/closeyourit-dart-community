import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<dynamic> bodies;
  late List<Uri> uris;
  late CloseYourItClient client;

  setUp(() async {
    bodies = [];
    uris = [];
    final options = CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      slowMethodThresholdMs: 0,
      logsMinLevel: LogLevel.debug,
    );
    final stats = Stats();
    client = CloseYourItClient(
      options,
      stats: stats,
      worker: BackgroundWorker(stats: stats),
      transport: Transport(
        token: options.token,
        stats: stats,
        client: MockClient((req) async {
          uris.add(req.url);
          bodies.add(jsonDecode(req.body));
          return http.Response('{"data":{}}', 202);
        }),
      ),
    );
    await CloseYourIt.init(options, client: client, installIntegrations: false);
  });

  tearDown(() => CloseYourIt.close());

  group('CloseYourIt façade — delegates to the scope', () {
    test('setUser/setTag/setTags/setExtra/setContext/setTraceId', () {
      CloseYourIt.setUser(id: '7');
      CloseYourIt.setTag('a', 'b');
      CloseYourIt.setTags({'c': 'd'});
      CloseYourIt.setExtra('e', 1);
      CloseYourIt.setContext('ctx', {'k': 'v'});
      CloseYourIt.setTraceId('trace-1');

      final hash = client.scope.toEventHash(sendPii: false);
      expect(hash['user'], {'id': '7'});
      expect(hash['tags'], {'a': 'b', 'c': 'd'});
      expect((hash['extra']! as Map)['e'], 1);
      expect((hash['contexts']! as Map)['ctx'], {'k': 'v'});
      expect(client.scope.traceId, 'trace-1');
    });

    test('configureScope + addBreadcrumb + clearScope', () {
      CloseYourIt.configureScope((s) => s.setTag('x', 'y'));
      CloseYourIt.addBreadcrumb(message: 'tap', category: 'ui');
      expect(
          client.scope.toEventHash(sendPii: false).containsKey('breadcrumbs'),
          isTrue);

      CloseYourIt.clearScope();
      expect(client.scope.toEventHash(sendPii: false), isEmpty);
    });
  });

  group('CloseYourIt façade — sends', () {
    test('captureException → /events', () async {
      CloseYourIt.captureException(StateError('x'));
      await CloseYourIt.flush();
      expect(uris.single.path, '/api/v1/projects/p1/events');
    });

    test('captureMessage → /events', () async {
      CloseYourIt.captureMessage('hi');
      await CloseYourIt.flush();
      expect((bodies.single as Map)['message'], {'formatted': 'hi'});
    });

    test('log → /logs', () async {
      CloseYourIt.log(LogLevel.info, 'l');
      await CloseYourIt.flush();
      expect(uris.single.path, '/api/v1/projects/p1/logs');
    });

    test('measure → /metrics and returns the value', () async {
      final r = await CloseYourIt.measure('m', () async => 7);
      await CloseYourIt.flush();
      expect(r, 7);
      expect(uris.single.path, '/api/v1/projects/p1/metrics');
    });

    test('stats exposes the counters', () async {
      CloseYourIt.captureException(StateError('x'));
      await CloseYourIt.flush();
      expect(CloseYourIt.stats['sent'], 1);
    });
  });
}
