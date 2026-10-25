import 'package:closeyourit/src/events/error_event.dart';
// The `sdk` block of every event carries name and version: what matters here is that it is there
// and is the real one, not which number was current the day the test was written.
import 'package:closeyourit/src/version.dart';
import 'package:closeyourit/src/events/log_event.dart';
import 'package:closeyourit/src/events/message_event.dart';
import 'package:closeyourit/src/events/metric_event.dart';
import 'package:closeyourit/src/log_level.dart';
import 'package:flutter_test/flutter_test.dart';

final _noDashes = RegExp(r'^[0-9a-f]{32}$');
final _withDashes = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  group('ErrorEvent', () {
    test('Sentry format: exception.values, mechanism, sdk, platform', () {
      final st =
          StackTrace.fromString('#0      Boom.go (package:app/b.dart:1:1)\n');
      final json = ErrorEvent.fromError(
        const FormatException('boom'),
        st,
        environment: 'production',
        release: 'v1.2.3',
        handled: true,
      ).toJson();

      expect((json['event_id']! as String), matches(_noDashes));
      expect(json['platform'], 'dart');
      expect(json['level'], 'error');
      expect(json['environment'], 'production');
      expect(json['release'], 'v1.2.3');

      final values = (json['exception']! as Map)['values']! as List;
      final v0 = values.single as Map<String, Object?>;
      expect(v0['type'], 'FormatException');
      expect((v0['value']! as String), contains('boom'));
      expect(((v0['stacktrace']! as Map)['frames']! as List), isNotEmpty);
      expect(v0['mechanism'], {'type': 'dart', 'handled': true});

      expect(json['sdk'],
          {'name': closeYourItSdkName, 'version': closeYourItSdkVersion});
      final runtime = (json['contexts']! as Map)['runtime']! as Map;
      expect(runtime['name'], 'dart');
      expect((runtime['version']! as String), isNotEmpty);
    });

    test('release omitted when null', () {
      final json = ErrorEvent.fromError(StateError('x'), null,
              environment: 'development')
          .toJson();
      expect(json.containsKey('release'), isFalse);
    });

    test('scrubs secrets in the exception message (value)', () {
      final json = ErrorEvent.fromError(
        const FormatException('login failed password=hunter2'),
        null,
        environment: 'production',
      ).toJson();

      final values = (json['exception']! as Map)['values']! as List;
      final value = (values.single as Map)['value']! as String;
      expect(value, isNot(contains('hunter2')));
      expect(value, contains('[FILTERED]'));
    });

    test(
        'access header in the exception message: the value after '
        'Bearer is not sent (CYDA-26)', () {
      final json = ErrorEvent.fromError(
        const FormatException(
            'request rejected — Authorization: Bearer EXAMPLE_NOT_A_CREDENTIAL'),
        null,
        environment: 'production',
      ).toJson();

      final values = (json['exception']! as Map)['values']! as List;
      final value = (values.single as Map)['value']! as String;
      expect(value.contains('EXAMPLE_NOT_A_CREDENTIAL'), isFalse);
      expect(value, contains('[FILTERED]'));
    });

    test('merges scope (user/tags) + trace_id + explicit contexts', () {
      final json = ErrorEvent.fromError(
        StateError('x'),
        null,
        environment: 'development',
        traceId: 'trace-1',
        scopeHash: {
          'user': {'id': '7'},
          'tags': {'area': 'checkout'},
          'contexts': {
            'app': {'screen': 'home'},
          },
        },
        contexts: {
          'device': {'model': 'iPhone'},
        },
      ).toJson();

      expect(json['user'], {'id': '7'});
      expect(json['tags'], {'area': 'checkout'});
      expect(json['trace_id'], 'trace-1');
      final contexts = json['contexts']! as Map<String, Object?>;
      expect((contexts['runtime']! as Map)['name'], 'dart');
      expect((contexts['app']! as Map)['screen'], 'home');
      expect((contexts['device']! as Map)['model'], 'iPhone');
    });
  });

  group('MessageEvent', () {
    test(
        'scrubs message.formatted (parity with ErrorEvent/LogEvent and with '
        'the Ruby/JS SDKs)', () {
      final json = MessageEvent(
        message: 'login failed password=hunter2',
        environment: 'production',
      ).toJson();

      final formatted = (json['message']! as Map)['formatted']! as String;
      expect(formatted, isNot(contains('hunter2')));
      expect(formatted, 'login failed [FILTERED]');
    });

    test(
        'access header in the message: the value after Bearer is not sent '
        '(CYDA-26)', () {
      final json = MessageEvent(
        message: 'Authorization: Bearer EXAMPLE_NOT_A_CREDENTIAL',
        environment: 'production',
      ).toJson();

      final formatted = (json['message']! as Map)['formatted']! as String;
      expect(formatted.contains('EXAMPLE_NOT_A_CREDENTIAL'), isFalse);
      expect(formatted, '[FILTERED]');
    });

    test('message.formatted + level + sdk', () {
      final json = MessageEvent(
        message: 'cache miss',
        environment: 'staging',
        level: 'warning',
      ).toJson();
      expect(json['message'], {'formatted': 'cache miss'});
      expect(json['level'], 'warning');
      expect((json['event_id']! as String), matches(_noDashes));
      expect(json['platform'], 'dart');
      final runtime = (json['contexts']! as Map)['runtime']! as Map;
      expect(runtime['name'], 'dart');
      expect((runtime['version']! as String), isNotEmpty);
    });
  });

  group('MetricEvent', () {
    test('kind slow_method, sample_id with dashes, rounded duration', () {
      final json = MetricEvent(
        label: 'checkout.total',
        durationMs: 123.456789,
        environment: 'production',
        file: 'lib/checkout.dart',
        lineno: 42,
      ).toJson();

      expect(json['kind'], 'slow_method');
      expect((json['sample_id']! as String), matches(_withDashes));
      expect(json['duration_ms'], 123.46);
      expect(json['label'], 'checkout.total');
      expect(json['file'], 'lib/checkout.dart');
      expect(json['lineno'], 42);
      expect(json['sdk'],
          {'name': closeYourItSdkName, 'version': closeYourItSdkVersion});
    });

    test('file/lineno/arguments omitted when missing', () {
      final json =
          MetricEvent(label: 'x', durationMs: 1, environment: 'development')
              .toJson();
      expect(json.containsKey('file'), isFalse);
      expect(json.containsKey('lineno'), isFalse);
      expect(json.containsKey('arguments'), isFalse);
    });

    test('empty or whitespace-only label → throws (fingerprint guard)', () {
      final blankRaises =
          throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>()));
      expect(
          () =>
              MetricEvent(label: '', durationMs: 1, environment: 'development'),
          blankRaises);
      expect(
          () => MetricEvent(
              label: '   ', durationMs: 1, environment: 'development'),
          blankRaises);
    });

    test('a non-empty label → builds without throwing', () {
      expect(
          MetricEvent(
                  label: 'checkout', durationMs: 1, environment: 'development')
              .label,
          'checkout');
    });
  });

  group('LogEvent', () {
    test('logs fields + scrubbed attributes + trace_id', () {
      final json = LogEvent(
        message: 'order created',
        level: LogLevel.info,
        environment: 'production',
        logger: 'payments',
        release: 'v1',
        traceId: 'trace-9',
        attributes: {'order_id': 1, 'token': 'jwt'},
      ).toJson();

      expect((json['event_id']! as String), matches(_noDashes));
      expect(json['level'], 'info');
      expect(json['message'], 'order created');
      expect(json['logger'], 'payments');
      expect(json['trace_id'], 'trace-9');
      expect(json['environment'], 'production');
      expect(json['release'], 'v1');
      final attrs = json['attributes']! as Map<String, Object?>;
      expect(attrs['order_id'], 1);
      expect(attrs['token'], '[FILTERED]');
    });

    test('attributes/logger/trace_id/release omitted when missing', () {
      final json = LogEvent(
        message: 'x',
        level: LogLevel.error,
        environment: 'development',
      ).toJson();
      expect(json.containsKey('attributes'), isFalse);
      expect(json.containsKey('logger'), isFalse);
      expect(json.containsKey('trace_id'), isFalse);
      expect(json.containsKey('release'), isFalse);
      expect(json['level'], 'error');
    });

    test('scrubs sensitive assignments in the message (PII as for errors)', () {
      final json = LogEvent(
        message: 'login failed password=hunter2 for alice',
        level: LogLevel.warning,
        environment: 'production',
      ).toJson();
      expect(json['message'], contains('[FILTERED]'));
      expect(json['message'], isNot(contains('hunter2')));
    });

    test(
        'access header in a log message: the value after Bearer is not '
        'sent (CYDA-26)', () {
      final json = LogEvent(
        message:
            'upstream 401 — Authorization: Bearer EXAMPLE_NOT_A_CREDENTIAL',
        level: LogLevel.warning,
        environment: 'production',
      ).toJson();
      expect(json['message'], isNot(contains('EXAMPLE_NOT_A_CREDENTIAL')));
      expect(json['message'], 'upstream 401 — [FILTERED]');
    });
  });
}
