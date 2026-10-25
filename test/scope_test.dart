import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/breadcrumb_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Breadcrumb', () {
    test(
        'serializes with only the keys that have a value + UTC ISO8601 timestamp',
        () {
      final ts = DateTime.utc(2026, 6, 29, 12);
      final json =
          Breadcrumb(message: 'tap', category: 'ui', timestamp: ts).toJson();
      expect(json['timestamp'], '2026-06-29T12:00:00.000Z');
      expect(json['type'], 'default');
      expect(json['level'], 'info');
      expect(json['category'], 'ui');
      expect(json['message'], 'tap');
      expect(json.containsKey('data'), isFalse); // empty data omitted
    });

    test('scrubs sensitive data at construction', () {
      final json =
          Breadcrumb(message: 'login', data: {'token': 'jwt', 'user': 'x'})
              .toJson();
      final data = json['data']! as Map<String, Object?>;
      expect(data['token'], '[FILTERED]');
      expect(data['user'], 'x');
    });
  });

  group('BreadcrumbBuffer', () {
    test('keeps only the last maxSize (ring)', () {
      final buf = BreadcrumbBuffer(maxSize: 2);
      buf
        ..add(Breadcrumb(message: 'a'))
        ..add(Breadcrumb(message: 'b'))
        ..add(Breadcrumb(message: 'c'));
      final values = buf.toList().map((c) => c.message).toList();
      expect(values, ['b', 'c']);
      expect(buf.length, 2);
    });

    test('maxSize 0 → no-op', () {
      final buf = BreadcrumbBuffer(maxSize: 0)..add(Breadcrumb(message: 'a'));
      expect(buf.isEmpty, isTrue);
      expect(buf.toJson(), isNull);
    });

    test('empty toJson → null', () {
      expect(BreadcrumbBuffer().toJson(), isNull);
    });
  });

  group('Scope.toEventHash', () {
    test('empty scope → empty hash', () {
      expect(Scope().toEventHash(sendPii: false), isEmpty);
    });

    test('user reduced to its id without sendPii', () {
      final s = Scope()
        ..setUser(id: '42', email: 'a@b.it', ipAddress: '1.2.3.4');
      final hash = s.toEventHash(sendPii: false);
      expect(hash['user'], {'id': '42'});
    });

    test('full user with sendPii', () {
      final s = Scope()..setUser(id: '42', email: 'a@b.it');
      final hash = s.toEventHash(sendPii: true);
      final user = hash['user']! as Map<String, Object?>;
      expect(user['id'], '42');
      expect(user['email'], 'a@b.it');
    });

    test('user without id and without sendPii → no user section', () {
      final s = Scope()..setUser(email: 'a@b.it');
      expect(s.toEventHash(sendPii: false).containsKey('user'), isFalse);
    });

    test('tags/extra/contexts included only when set, and scrubbed', () {
      final s = Scope()
        ..setTag('area', 'checkout')
        ..setExtra('cart', 3)
        ..setExtra('secret', 'x')
        ..setContext('billing', {'plan': 'pro', 'token': 't'});
      final hash = s.toEventHash(sendPii: false);
      expect(hash['tags'], {'area': 'checkout'});
      final extra = hash['extra']! as Map<String, Object?>;
      expect(extra['cart'], 3);
      expect(extra['secret'], '[FILTERED]');
      final billing = (hash['contexts']! as Map<String, Object?>)['billing']!
          as Map<String, Object?>;
      expect(billing['plan'], 'pro');
      expect(billing['token'], '[FILTERED]');
    });

    test('breadcrumbs serialized as {values:[...]}', () {
      final s = Scope()..addBreadcrumb(Breadcrumb(message: 'tap'));
      final crumbs =
          s.toEventHash(sendPii: false)['breadcrumbs']! as Map<String, Object?>;
      expect((crumbs['values']! as List).length, 1);
    });

    test('clear resets everything', () {
      final s = Scope()
        ..setUser(id: '1')
        ..setTag('a', 'b')
        ..setTraceId('t')
        ..addBreadcrumb(Breadcrumb(message: 'x'));
      s.clear();
      expect(s.toEventHash(sendPii: false), isEmpty);
      expect(s.traceId, isNull);
    });
  });

  group('Scope.traceId auto-population', () {
    test('by default the trace_id is missing until needed', () {
      expect(Scope().traceId, isNull);
    });

    test('ensureTraceId generates a trace_id if missing and then stores it',
        () {
      final s = Scope();
      final id = s.ensureTraceId();
      expect(id, isNotEmpty);
      expect(s.traceId, id); // stored on the scope
      expect(s.ensureTraceId(), id); // stable: second call = same id
    });

    test('ensureTraceId does not overwrite a hand-set trace_id', () {
      final s = Scope()..setTraceId('manual');
      expect(s.ensureTraceId(), 'manual');
      expect(s.traceId, 'manual');
    });

    test('ensureTraceId uses the injected generator', () {
      final s = Scope(traceIdGenerator: () => 'fixed');
      expect(s.ensureTraceId(), 'fixed');
    });

    test(
        'rotateTraceId always generates a new trace_id different from the previous one',
        () {
      final s = Scope();
      final first = s.ensureTraceId();
      final second = s.rotateTraceId();
      expect(second, isNotEmpty);
      expect(second, isNot(first)); // new logical unit
      expect(s.traceId, second);
    });

    test('rotateTraceId uses the injected generator', () {
      var n = 0;
      final s = Scope(traceIdGenerator: () => 'id-${n++}');
      expect(s.rotateTraceId(), 'id-0');
      expect(s.rotateTraceId(), 'id-1');
    });

    test('rotateTraceId does NOT overwrite a hand-pinned trace_id', () {
      final s = Scope()..setTraceId('custom-flow');
      expect(s.rotateTraceId(),
          'custom-flow'); // the manual one wins over navigation
      expect(s.traceId, 'custom-flow');
    });

    test('setTraceId(null) releases the pin: rotateTraceId rotates again', () {
      var n = 0;
      final s = Scope(traceIdGenerator: () => 'auto-${n++}')
        ..setTraceId('manual')
        ..setTraceId(null);
      expect(s.rotateTraceId(), 'auto-0'); // pin released -> generates again
    });

    test('clear resets the auto-generated trace_id (restarts lazily)', () {
      final s = Scope();
      final id = s.ensureTraceId();
      expect(id, isNotEmpty);
      s.clear();
      expect(s.traceId, isNull);
      expect(s.ensureTraceId(), isNot(id)); // generates a new one
    });

    test(
        'the auto-generated trace_id is 32 hex (parity with event_id/other SDKs)',
        () {
      expect(Scope().ensureTraceId(), matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });
}
