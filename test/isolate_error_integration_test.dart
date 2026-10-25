import 'dart:convert';
import 'dart:isolate';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/integrations/isolate_error_integration.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

CloseYourItClient _client(List<Map<String, Object?>> bodies) {
  final stats = Stats();
  return CloseYourItClient(
    CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
    ),
    stats: stats,
    worker: BackgroundWorker(stats: stats),
    transport: Transport(
      token: 'cyi_t',
      stats: stats,
      client: MockClient((req) async {
        bodies.add(jsonDecode(req.body) as Map<String, Object?>);
        return http.Response('{"data":{}}', 202);
      }),
    ),
  );
}

void main() {
  group('handleIsolateError', () {
    test('[message, stack] → fatal error captured and sent', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(bodies);

      handleIsolateError(client, ['RangeError: index out of range', '#0 main']);
      await client.flush();

      expect(bodies, hasLength(1));
      final values = (bodies.single['exception']! as Map)['values']! as List;
      final v0 = values.single as Map;
      expect(v0['type'], 'IsolateError');
      expect(
          (v0['value']! as String), contains('RangeError: index out of range'));
      expect(bodies.single['level'], 'fatal');
      // Unhandled: it is an isolate crash, not a recovered error.
      expect((v0['mechanism']! as Map)['handled'], isFalse);
    });

    test('malformed message → ignored, nothing sent', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(bodies);

      handleIsolateError(client, 'not a list');
      handleIsolateError(client, ['only one element']);
      handleIsolateError(client, ['', 'stack']); // empty message
      handleIsolateError(client, null);
      await client.flush();

      expect(bodies, isEmpty);
    });

    test('missing stack → no crash, event sent anyway', () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(bodies);

      handleIsolateError(client, ['StateError: boom', null]);
      await client.flush();

      expect(bodies, hasLength(1));
    });
  });

  group('installIsolateErrorHandler', () {
    test(
        'install exposes dispose + errorPort (SendPort on VM); dispose does not throw',
        () {
      final client = _client([]);
      final handle = installIsolateErrorHandler(client);
      expect(
          handle.errorPort, isA<SendPort>()); // on native the port is exposed
      expect(handle.dispose, returnsNormally);
    });

    test(
        'isolate spawned with onError=errorPort → the crash reaches CloseYourIt',
        () async {
      final bodies = <Map<String, Object?>>[];
      final client = _client(bodies);
      final handle = installIsolateErrorHandler(client);
      addTearDown(handle.dispose);

      // This is what covers crashes of spawned isolates: the listener
      // on the current isolate alone would not see them.
      await Isolate.spawn(
        _boomIsolate,
        null,
        onError: handle.errorPort! as SendPort,
      );

      await _waitUntil(() => bodies.isNotEmpty);
      await client.flush();

      expect(bodies, isNotEmpty);
      final values = (bodies.first['exception']! as Map)['values']! as List;
      final v0 = values.single as Map;
      expect(v0['type'], 'IsolateError');
      expect((v0['value']! as String), contains('crash in spawned isolate'));
      expect(bodies.first['level'], 'fatal');
    });
  });
}

/// Entrypoint of an isolate that crashes (must be top-level).
void _boomIsolate(dynamic _) {
  throw StateError('crash in spawned isolate');
}

/// Waits (with a timeout) for [condition] to become true, without using the real
/// clock in the assertions (only to advance the cross-isolate event loop).
Future<void> _waitUntil(bool Function() condition, {int maxTicks = 200}) async {
  for (var i = 0; i < maxTicks && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
