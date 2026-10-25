import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('CloseYourItLogger', () {
    late List<dynamic> bodies;
    late CloseYourItClient client;

    setUp(() {
      bodies = [];
      final options = CloseYourItOptions(
        endpointUrl: 'https://www.closeyour.it',
        token: 'cyi_t',
        projectId: 'p1',
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
            bodies.add(jsonDecode(req.body));
            return http.Response('{"data":{}}', 202);
          }),
        ),
      );
    });

    Future<String> levelOf(void Function(CloseYourItLogger) act) async {
      act(client.logger);
      await client.flush();
      final batch = bodies.single as List;
      return (batch.single as Map)['level'] as String;
    }

    test('debug → debug', () async {
      expect(await levelOf((l) => l.debug('x')), 'debug');
    });
    test('info → info', () async {
      expect(await levelOf((l) => l.info('x')), 'info');
    });
    test('warn → warning', () async {
      expect(await levelOf((l) => l.warn('x')), 'warning');
    });
    test('error → error', () async {
      expect(await levelOf((l) => l.error('x')), 'error');
    });
    test('fatal → fatal', () async {
      expect(await levelOf((l) => l.fatal('x')), 'fatal');
    });

    test('a logger with a null client is a no-op (does not throw)', () {
      final noop = CloseYourItLogger(null);
      expect(() => noop.info('x'), returnsNormally);
      expect(() => noop.error('y', attributes: {'a': 1}), returnsNormally);
    });
  });
}
