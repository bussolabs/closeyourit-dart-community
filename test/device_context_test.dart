import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/integrations/device_context.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Harness {
  _Harness(CloseYourItOptions options) {
    final stats = Stats();
    final transport = Transport(
      token: options.token,
      stats: stats,
      client: MockClient((req) async {
        bodies.add(jsonDecode(req.body));
        return http.Response('{"data":{}}', 202);
      }),
    );
    client = CloseYourItClient(
      options,
      transport: transport,
      stats: stats,
      worker: BackgroundWorker(stats: stats, maxQueue: options.maxQueue),
      randomSource: () => 0.0,
    );
  }

  final List<dynamic> bodies = [];
  late final CloseYourItClient client;

  Map<String, Object?> get firstEvent =>
      (bodies.first as Map).cast<String, Object?>();
}

CloseYourItOptions _options({String? release}) => CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      release: release,
    );

DeviceContexts _fullContexts() => const DeviceContexts(
      device: {
        'model': 'Pixel 8',
        'manufacturer': 'Google',
        'simulator': false
      },
      os: {'name': 'Android', 'version': '14'},
      app: {
        'app_version': '1.2.0',
        'build_number': '45',
        'bundle_id': 'app.demo.flutter',
      },
    );

class _FakeProvider implements DeviceContextProvider {
  _FakeProvider(this.contexts);
  final DeviceContexts contexts;

  @override
  Future<DeviceContexts> load() async => contexts;
}

class _ThrowingProvider implements DeviceContextProvider {
  @override
  Future<DeviceContexts> load() => throw StateError('no plugins here');
}

void main() {
  test('device/os/app end up in the contexts of every event', () async {
    final h = _Harness(_options());
    await installDeviceContext(h.client,
        provider: _FakeProvider(_fullContexts()));

    h.client.captureException(StateError('x'));
    await h.client.flush();

    final contexts = (h.firstEvent['contexts'] as Map).cast<String, Object?>();
    expect((contexts['os'] as Map)['name'], 'Android');
    expect((contexts['os'] as Map)['version'], '14');
    expect((contexts['device'] as Map)['model'], 'Pixel 8');
    expect((contexts['app'] as Map)['app_version'], '1.2.0');
    expect((contexts['app'] as Map)['build_number'], '45');
  });

  test('auto-release "version+build" when options.release is missing',
      () async {
    final h = _Harness(_options());
    await installDeviceContext(h.client,
        provider: _FakeProvider(_fullContexts()));

    h.client.captureException(StateError('x'));
    await h.client.flush();

    expect(h.firstEvent['release'], '1.2.0+45');
  });

  test('an explicit release in the options is NOT overwritten', () async {
    final h = _Harness(_options(release: 'v9.9.9'));
    await installDeviceContext(h.client,
        provider: _FakeProvider(_fullContexts()));

    h.client.captureException(StateError('x'));
    await h.client.flush();

    expect(h.firstEvent['release'], 'v9.9.9');
  });

  test('a provider that throws → no context, no propagated exception',
      () async {
    final h = _Harness(_options());
    await installDeviceContext(h.client, provider: _ThrowingProvider());

    h.client.captureException(StateError('x'));
    await h.client.flush();

    final contexts = (h.firstEvent['contexts'] as Map).cast<String, Object?>();
    expect(contexts.containsKey('device'), isFalse);
    expect(contexts.containsKey('os'), isFalse);
    expect(h.firstEvent['release'], isNull);
  });

  test('null sections from the provider are simply omitted', () async {
    final h = _Harness(_options());
    await installDeviceContext(
      h.client,
      provider: _FakeProvider(const DeviceContexts(
        device: null,
        os: {'name': 'macOS', 'version': '15.1'},
        app: null,
      )),
    );

    h.client.captureException(StateError('x'));
    await h.client.flush();

    final contexts = (h.firstEvent['contexts'] as Map).cast<String, Object?>();
    expect((contexts['os'] as Map)['name'], 'macOS');
    expect(contexts.containsKey('device'), isFalse);
    expect(contexts.containsKey('app'), isFalse);
    expect(h.firstEvent['release'], isNull);
  });

  test('logs also inherit the auto-derived release', () async {
    final h = _Harness(_options());
    await installDeviceContext(h.client,
        provider: _FakeProvider(_fullContexts()));

    h.client.log(LogLevel.info, 'hello');
    await h.client.flush();

    final logs = (h.bodies.first as List).cast<Map<String, Object?>>();
    expect(logs.first['release'], '1.2.0+45');
  });
}
