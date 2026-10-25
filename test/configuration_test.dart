import 'package:closeyourit/closeyourit.dart';
import 'package:flutter_test/flutter_test.dart';

CloseYourItOptions opts({
  String endpointUrl = 'https://www.closeyour.it',
  String token = 'cyi_secret',
  String publicKey = '',
  String projectId = 'proj-1',
  String environment = 'development',
  bool enabled = true,
}) =>
    CloseYourItOptions(
      endpointUrl: endpointUrl,
      token: token,
      publicKey: publicKey,
      projectId: projectId,
      environment: environment,
      enabled: enabled,
    );

void main() {
  group('isEnabled / disabledReason', () {
    test('a valid config is enabled', () {
      final o = opts();
      expect(o.isEnabled, isTrue);
      expect(o.disabledReason, isNull);
    });

    test('enabled:false disables', () {
      final o = opts(enabled: false);
      expect(o.isEnabled, isFalse);
      expect(o.disabledReason, contains('enabled'));
    });

    test('empty or whitespace-only endpointUrl → disabled', () {
      expect(opts(endpointUrl: '').disabledReason, 'endpointUrl mancante');
      expect(opts(endpointUrl: '   ').disabledReason, 'endpointUrl mancante');
    });

    test('no credential (publicKey and token empty) → disabled', () {
      expect(opts(token: '').disabledReason,
          'credenziale mancante (publicKey o token)');
      expect(opts(token: '   ', publicKey: '  ').disabledReason,
          'credenziale mancante (publicKey o token)');
    });

    test('publicKey present without token → enabled (DSN mode)', () {
      final o = opts(token: '', publicKey: 'deadbeef');
      expect(o.isEnabled, isTrue);
      expect(o.disabledReason, isNull);
      expect(o.usesPublicKey, isTrue);
    });

    test('token only → bearer mode (does not use the public key)', () {
      final o = opts();
      expect(o.usesPublicKey, isFalse);
    });

    test('publicKey wins when both are present (never bearer from the client)',
        () {
      final o = opts(token: 'cyi_secret', publicKey: 'deadbeef');
      expect(o.isEnabled, isTrue);
      expect(o.usesPublicKey, isTrue);
    });

    test('empty projectId → disabled', () {
      expect(opts(projectId: '').disabledReason, 'projectId mancante');
    });

    test('http:// in production → disabled (insecure)', () {
      final o =
          opts(endpointUrl: 'http://closeyour.it', environment: 'production');
      expect(o.isEnabled, isFalse);
      expect(o.disabledReason, contains('http'));
    });

    test('http:// in development is allowed', () {
      final o = opts(
          endpointUrl: 'http://localhost:3000', environment: 'development');
      expect(o.isEnabled, isTrue);
    });

    test('https:// in production is allowed', () {
      final o =
          opts(endpointUrl: 'https://closeyour.it', environment: 'production');
      expect(o.isEnabled, isTrue);
    });

    test('http:// with a token is rejected in staging (CYDA-28)', () {
      final o =
          opts(endpointUrl: 'http://closeyour.it', environment: 'staging');
      expect(o.isEnabled, isFalse);
      expect(o.disabledReason, contains('http'));
    });

    test('http:// with a token is rejected with an empty environment', () {
      final o = opts(endpointUrl: 'http://closeyour.it', environment: '');
      expect(o.isEnabled, isFalse);
    });

    test('http:// with a token is allowed on loopback hosts', () {
      for (final url in [
        'http://localhost:3000',
        'http://127.0.0.1:3000',
        'http://[::1]:3000',
      ]) {
        expect(opts(endpointUrl: url, environment: 'staging').isEnabled, isTrue,
            reason: url);
      }
    });

    test('http:// with only a publicKey keeps the production-only rule', () {
      final staging = opts(
          endpointUrl: 'http://closeyour.it',
          token: '',
          publicKey: 'deadbeef',
          environment: 'staging');
      expect(staging.isEnabled, isTrue);
      final prod = opts(
          endpointUrl: 'http://closeyour.it',
          token: '',
          publicKey: 'deadbeef',
          environment: 'production');
      expect(prod.isEnabled, isFalse);
    });
  });

  group('ingest URIs', () {
    test('builds the three paths under /api/v1/projects/{id}', () {
      final o = opts(projectId: 'abc');
      expect(o.eventsUri.toString(),
          'https://www.closeyour.it/api/v1/projects/abc/events');
      expect(o.metricsUri.toString(),
          'https://www.closeyour.it/api/v1/projects/abc/metrics');
      expect(o.logsUri.toString(),
          'https://www.closeyour.it/api/v1/projects/abc/logs');
    });

    test('normalizes the trailing slash of endpointUrl', () {
      final o = opts(endpointUrl: 'https://www.closeyour.it/');
      expect(o.eventsUri.toString(),
          'https://www.closeyour.it/api/v1/projects/proj-1/events');
    });

    test('storeUri: Sentry drop-in /api/{projectId}/store (outside /api/v1)',
        () {
      final o = opts(projectId: 'abc');
      expect(o.storeUri.toString(), 'https://www.closeyour.it/api/abc/store');
    });

    test('storeUri normalizes the trailing slash of endpointUrl', () {
      final o = opts(endpointUrl: 'https://www.closeyour.it/');
      expect(
          o.storeUri.toString(), 'https://www.closeyour.it/api/proj-1/store');
    });
  });

  group('defaults', () {
    test('default values consistent with the gem', () {
      final o = opts();
      expect(o.environment, 'development');
      expect(o.sampleRate, 1.0);
      expect(o.sendPii, isFalse);
      expect(o.maxBreadcrumbs, 100);
      expect(o.logsBatchSize, 50);
      expect(o.logsFlushInterval, const Duration(seconds: 5));
      expect(o.logsMinLevel, LogLevel.info);
      expect(o.requestHeaderAllowlist, isNot(contains('Authorization')));
    });
  });

  group('isExcluded', () {
    test('recognises the exception type by name', () {
      final o = CloseYourItOptions(
        endpointUrl: 'https://x.it',
        token: 't',
        projectId: 'p',
        excludedExceptions: const ['FormatException'],
      );
      expect(o.isExcluded(const FormatException('x')), isTrue);
      expect(o.isExcluded(StateError('x')), isFalse);
    });
  });
}
