import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// Opt-in real Rails test. Only non-secret public credentials enter this process.
const endpoint = String.fromEnvironment('CYI_CERT_ENDPOINT');
const project = String.fromEnvironment('CYI_CERT_PROJECT');
const publicKey = String.fromEnvironment('CYI_CERT_PUBLIC_KEY');
const readPublicKey = String.fromEnvironment('CYI_CERT_READ_PUBLIC_KEY');

class ObservedClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final List<int> statuses = [];
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.headers.keys
        .any((key) => key.toLowerCase() == 'authorization')) {
      throw StateError('Public consumer must never send Authorization');
    }
    requests++;
    final response = await delegate.send(request);
    statuses.add(response.statusCode);
    return response;
  }

  @override
  void close() => delegate.close();
}

CloseYourItClient client(ObservedClient wire,
    {String key = publicKey, BeforeSend? beforeSend}) {
  final stats = Stats();
  return CloseYourItClient(
    CloseYourItOptions(
      endpointUrl: endpoint,
      publicKey: key,
      projectId: project,
      environment: 'certification',
      release: 'dart-public-certification',
      slowMethodThresholdMs: 0,
      detectPerformanceIssues: true,
      slowExternalThresholdMs: 0,
      logsFlushInterval: Duration.zero,
      usageEnabled: true,
      beforeSend: beforeSend,
      persistOffline: false,
    ),
    stats: stats,
    transport: Transport(stats: stats, publicKey: key, client: wire),
  );
}

Future<void> exercisePublicIngest() async {
  expect(Uri.parse(endpoint).host, '127.0.0.1');
  // The liveness endpoint intentionally has no browser CORS policy.
  if (!kIsWeb) {
    final health = await http.get(Uri.parse('$endpoint/up'));
    expect(health.statusCode, 200,
        reason: 'The consumer must reach real Rails');
  }
  final wire = ObservedClient();
  final sdk = client(wire);
  addTearDown(sdk.close);
  await sdk.flush();
  expect(wire.requests, 0);

  sdk.captureMessage('public-dart-error');
  sdk.log(LogLevel.info, 'public-dart-one',
      attributes: {'password': 'privacy-sentinel'});
  expect(await sdk.measure('public-dart-measure', () => 42), 42);
  await sdk.flush();
  expect(wire.statuses, unorderedEquals([200, 202, 202]));
  sdk
    ..log(LogLevel.info, 'public-dart-two')
    ..log(LogLevel.warning, 'public-dart-three')
    ..recordExternalHttp(host: 'example.test', path: '/safe', durationMs: 1500)
    ..recordRepeatedHttp(host: 'example.test', path: '/safe', count: 9)
    ..recordJank(frameMs: 99, route: 'PublicScreen')
    ..recordRebuildStorm(widget: 'PublicWidget', count: 30, windowMs: 1000)
    ..recordUsage('public.should.not.send');
  await sdk.flush();
  expect(wire.requests, 8);
  expect(wire.statuses.where((status) => status == 202), hasLength(7));
  expect(sdk.stats[StatKey.sent], 8);
  await sdk.close();

  for (final rejection in [401, 403]) {
    final observed = ObservedClient();
    final failing = client(observed,
        key: rejection == 401
            ? '00000000000000000000000000000000'
            : readPublicKey);
    addTearDown(failing.close);
    await failing.measure('rejected-measure', () => 1);
    failing.log(LogLevel.warning, 'rejected-log');
    await failing.flush();
    expect(observed.statuses, [rejection, rejection]);
    expect(failing.stats.drops(DropReason.permanentReject), 2);
    await failing.flush();
    expect(observed.requests, 2, reason: 'Permanent failures must not retry');
    await failing.close();
  }

  final largeWire = ObservedClient();
  final large = client(largeWire,
      beforeSend: (payload) =>
          {...payload, 'padding': 'x' * (5 * 1024 * 1024 + 1)});
  addTearDown(large.close);
  await large.measure('oversized-measure', () => 1);
  await large.flush();
  expect(largeWire.statuses, [413]);
  expect(large.stats.drops(DropReason.tooLarge), 1);
  await large.close();

  // The SDK splits log batches at 1000. Exercise the real server rejection
  // separately through its production transport with a derived oversized batch.
  final logStats = Stats();
  final logTransport = Transport(stats: logStats, publicKey: publicKey);
  addTearDown(logTransport.close);
  final logStatus = await logTransport.send(
      List.generate(1001, (_) => {'message': 'oversized-protocol-batch'}),
      uri: Uri.parse('$endpoint/api/v1/projects/$project/logs'));
  expect(logStatus, 413);
  expect(logStats[StatKey.failed], 1);

  // Exercise real Rack::Attack, without changing limits or persisting records.
  final flood = ObservedClient();
  addTearDown(flood.close);
  final uri = Uri.parse('$endpoint/api/v1/projects/$project/logs').replace(
      queryParameters: {'sentry_key': '00000000000000000000000000000000'});
  var limited = false;
  for (var attempt = 0; attempt < 350; attempt++) {
    final response = await flood.post(uri,
        headers: {'Content-Type': 'application/json'}, body: jsonEncode([]));
    if (response.statusCode == 429) {
      limited = true;
      break;
    }
    expect(response.statusCode, 401);
  }
  expect(limited, isTrue, reason: 'The actual backend must enforce its limit');
  final throttledWire = ObservedClient();
  final throttled = client(throttledWire);
  addTearDown(throttled.close);
  await throttled.measure('throttled-measure', () => 1);
  throttled.log(LogLevel.info, 'throttled-log');
  await throttled.flush();
  expect(throttledWire.statuses, [429, 429]);
  expect(throttled.stats[StatKey.failed], 2);
  expect(throttled.stats.drops(DropReason.permanentReject), 0);
  await throttled.flush();
  expect(throttledWire.requests, 2,
      reason: 'Logs and metrics currently have no automatic retry queue');
}

void main() {
  test(
      'public Dart client sends real telemetry and respects rejection boundaries',
      exercisePublicIngest,
      skip: endpoint.isEmpty,
      timeout: const Timeout(Duration(minutes: 3)));
}
