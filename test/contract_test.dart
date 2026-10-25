import 'dart:convert';
import 'dart:io';

import 'package:closeyourit/src/events/log_event.dart';
import 'package:closeyourit/src/events/message_event.dart';
import 'package:closeyourit/src/events/metric_event.dart';
import 'package:closeyourit/src/log_level.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:json_schema/json_schema.dart';

final contractRoot = Directory('contracts/ingest');
final contract = Directory('${contractRoot.path}/v1');

dynamic contractJson(String relative) {
  return jsonDecode(File('${contract.path}/$relative').readAsStringSync());
}

JsonSchema contractSchema(String definition) {
  final schema = contractJson('schema.json') as Map<String, dynamic>;
  return JsonSchema.create(
    <String, dynamic>{
      r'$schema': schema[r'$schema'],
      r'$ref': '#/\$defs/$definition',
      r'$defs': schema[r'$defs'],
    },
    schemaVersion: SchemaVersion.draft2020_12,
  );
}

void main() {
  group('ingest contract v1', () {
    test('matches the canonical snapshot and every checksum', () {
      final lock = contractJson('../LOCK.json') as Map<String, dynamic>;
      final sumsFile = File('${contract.path}/SHA256SUMS');
      final sums = sumsFile.readAsStringSync();
      expect(sha256.convert(sumsFile.readAsBytesSync()).toString(),
          lock['sha256sums']);

      for (final line in sums.trim().split('\n')) {
        final parts = line.split('  ./');
        final relative = parts[1];
        final digest = sha256
            .convert(File('${contract.path}/$relative').readAsBytesSync())
            .toString();
        expect(digest, parts[0], reason: relative);
      }
    });

    test('applies the declared validity to every golden fixture', () {
      final manifest = contractJson('manifest.json') as Map<String, dynamic>;
      for (final item in manifest['fixtures'] as List<dynamic>) {
        final fixture = item as Map<String, dynamic>;
        final result = contractSchema(fixture['definition'] as String).validate(
          contractJson(fixture['path'] as String),
          validateFormats: true,
        );
        expect(result.isValid, fixture['valid'],
            reason: fixture['path'] as String);
      }
    });

    test('validates the Dart producers for events, logs and metrics', () {
      final now = DateTime.utc(2026, 7, 13, 14);
      final payloads = <String, Map<String, Object?>>{
        'event': MessageEvent(
          message: 'cache miss',
          environment: 'production',
          level: 'warning',
          eventId: '12345678123442348234123456789abc',
          occurredAt: now,
        ).toJson(),
        'log': LogEvent(
          message: 'order charged',
          level: LogLevel.info,
          environment: 'production',
          eventId: '12345678123442348234123456789abc',
          occurredAt: now,
        ).toJson(),
        'slow_method': MetricEvent(
          label: 'checkout.total',
          durationMs: 12.345,
          environment: 'production',
          sampleId: '12345678-1234-4234-8234-123456789abc',
          occurredAt: now,
        ).toJson(),
      };

      for (final entry in payloads.entries) {
        final result = contractSchema(entry.key)
            .validate(entry.value, validateFormats: true);
        expect(result.isValid, isTrue, reason: '$entry.key: ${result.errors}');
      }
    });

    test('consumes the whole HTTP matrix and classifies 2xx or failed',
        () async {
      final cases = contractJson('fixtures/http/cases.json') as List<dynamic>;
      final uri =
          Uri.parse('https://closeyour.it/api/v1/projects/project/events');

      for (final item in cases) {
        final contractCase = item as Map<String, dynamic>;
        final status = contractCase['status'] as int?;
        final stats = Stats();
        final transport = Transport(
          token: 'cyi_contract',
          stats: stats,
          client: MockClient((_) async {
            if (status == null) throw Exception('network');
            return http.Response('{}', status);
          }),
        );

        await transport.send(<String, Object?>{}, uri: uri);

        final accepted = status != null && status >= 200 && status < 300;
        expect(stats[accepted ? StatKey.sent : StatKey.failed], 1,
            reason: contractCase['id'] as String);
      }
    });

    test('permits public ingestion but rejects public reads', () {
      final cases =
          (contractJson('fixtures/http/auth-cases.json') as List<dynamic>)
              .cast<Map<String, dynamic>>();
      final byId = <String, Map<String, dynamic>>{
        for (final item in cases) item['id'] as String: item,
      };

      expect(byId['public-store']?['credential'], 'public_dsn');
      for (final channel in ['logs', 'metrics']) {
        expect(byId['public-$channel']?['status'], 202);
        expect(byId['public-$channel']?['credential'], 'public_dsn');
        expect(byId['public-$channel']?['endpoint'],
            '/api/v1/projects/{project_id}/$channel');
      }
      expect(byId['public-read-error-groups-rejected']?['status'], 401);
      expect(byId['public-read-log-entries-rejected']?['status'], 401);
    });

    test('the Dart producer honours the public-store auth-case (CYDA-7)',
        () async {
      final byId = <String, Map<String, dynamic>>{
        for (final item
            in (contractJson('fixtures/http/auth-cases.json') as List<dynamic>)
                .cast<Map<String, dynamic>>())
          item['id'] as String: item,
      };
      final store = byId['public-store']!;
      expect(store['credential'], 'public_dsn');
      expect(store['endpoint'], '/api/{project_id}/store');

      // With the public DSN the transport authenticates via ?sentry_key= and never
      // sends the Bearer: the credential in the package is ingest-only.
      late http.Request captured;
      final transport = Transport(
        publicKey: 'deadbeef',
        stats: Stats(),
        client: MockClient((req) async {
          captured = req;
          return http.Response('{"id":"e1"}', store['status'] as int);
        }),
      );
      final status = await transport.send(
        <String, Object?>{'event_id': 'e1'},
        uri: Uri.parse('https://closeyour.it/api/project/store'),
      );

      expect(status, store['status']); // 200 on the DSN drop-in
      expect(captured.url.path, '/api/project/store');
      expect(captured.url.queryParameters['sentry_key'], 'deadbeef');
      expect(captured.headers.containsKey('Authorization'), isFalse);
    });
  });
}
