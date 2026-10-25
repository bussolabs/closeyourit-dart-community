import 'package:closeyourit/src/integrations/trace_context.dart';
import 'package:flutter_test/flutter_test.dart';

/// W3C Trace Context parser/generator (CYDA-16).
///
/// The outgoing traceparent correlates the mobile call with downstream services;
/// it must be W3C-valid (the backend rejects malformed headers) and must never
/// carry internal information (sensitive baggage/tracestate filtered out).
void main() {
  group('TraceParent.parse', () {
    test('valid trace → fields extracted', () {
      final tp = TraceParent.parse(
          '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01');
      expect(tp, isNotNull);
      expect(tp!.version, '00');
      expect(tp.traceId, '4bf92f3577b34da6a3ce929d0e0e4736');
      expect(tp.parentId, '00f067aa0ba902b7');
      expect(tp.flags, '01');
    });

    test('roundtrip: toHeader reproduces the original header', () {
      const raw = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
      expect(TraceParent.parse(raw)!.toHeader(), raw);
    });

    test('malformed: null/empty → null', () {
      expect(TraceParent.parse(null), isNull);
      expect(TraceParent.parse(''), isNull);
      expect(TraceParent.parse('   '), isNull);
    });

    test('malformed: wrong number of fields → null', () {
      expect(TraceParent.parse('00-abc-def'), isNull);
      expect(
          TraceParent.parse(
              '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra'),
          isNull);
    });

    test('malformed: wrong lengths → null', () {
      // 31-hex trace-id
      expect(
          TraceParent.parse(
              '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01'),
          isNull);
      // 15-hex parent-id
      expect(
          TraceParent.parse(
              '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b-01'),
          isNull);
    });

    test('malformed: non-hexadecimal characters → null', () {
      expect(
          TraceParent.parse(
              '00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01'),
          isNull);
    });

    test('malformed: uppercase not allowed (W3C requires lowercase) → null',
        () {
      expect(
          TraceParent.parse(
              '00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01'),
          isNull);
    });

    test('malformed: all-zero trace-id → null', () {
      expect(
          TraceParent.parse(
              '00-00000000000000000000000000000000-00f067aa0ba902b7-01'),
          isNull);
    });

    test('malformed: all-zero parent-id → null', () {
      expect(
          TraceParent.parse(
              '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01'),
          isNull);
    });

    test('malformed: version ff (reserved) → null', () {
      expect(
          TraceParent.parse(
              'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'),
          isNull);
    });
  });

  group('TraceContext.hostAllowed', () {
    test('exact match, case-insensitive', () {
      expect(TraceContext.hostAllowed('api.x.it', ['api.x.it']), isTrue);
      expect(TraceContext.hostAllowed('API.X.IT', ['api.x.it']), isTrue);
    });

    test('subdomain covered by a domain entry', () {
      expect(TraceContext.hostAllowed('api.x.it', ['x.it']), isTrue);
      expect(TraceContext.hostAllowed('a.b.x.it', ['x.it']), isTrue);
    });

    test('domain boundary respected: no partial match', () {
      expect(TraceContext.hostAllowed('evilx.it', ['x.it']), isFalse);
    });

    test('empty allowlist or unlisted host → not allowed', () {
      expect(TraceContext.hostAllowed('api.x.it', const []), isFalse);
      expect(TraceContext.hostAllowed('api.y.it', ['api.x.it']), isFalse);
      expect(TraceContext.hostAllowed('', ['api.x.it']), isFalse);
    });
  });

  group('TraceContext.isValidTraceId / isValidParentId', () {
    test('trace-id: valid non-zero 32 hex', () {
      expect(TraceContext.isValidTraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
          isTrue);
      expect(TraceContext.isValidTraceId('0' * 32), isFalse);
      expect(TraceContext.isValidTraceId('abc'), isFalse);
      expect(TraceContext.isValidTraceId('4BF92F3577B34DA6A3CE929D0E0E4736'),
          isFalse);
    });

    test('parent-id: valid non-zero 16 hex', () {
      expect(TraceContext.isValidParentId('00f067aa0ba902b7'), isTrue);
      expect(TraceContext.isValidParentId('0' * 16), isFalse);
      expect(TraceContext.isValidParentId('00f067aa0ba902b'), isFalse);
    });
  });

  group('TraceContext.buildTraceState', () {
    test('without upstream tracestate → only the cyi vendor entry', () {
      expect(TraceContext.buildTraceState(null), 'cyi=1');
      expect(TraceContext.buildTraceState('   '), 'cyi=1');
    });

    test('with a valid tracestate → cyi entry first, rest preserved', () {
      expect(
        TraceContext.buildTraceState('rojo=00f067aa0ba902b7,congo=t61rcWkgMzE'),
        'cyi=1,rojo=00f067aa0ba902b7,congo=t61rcWkgMzE',
      );
    });

    test('an upstream cyi entry is not duplicated', () {
      expect(
        TraceContext.buildTraceState('cyi=0,rojo=abc'),
        'cyi=1,rojo=abc',
      );
    });

    test('sensitive baggage in the tracestate is filtered out', () {
      expect(
        TraceContext.buildTraceState('authorization=secret,rojo=abc'),
        'cyi=1,rojo=abc',
      );
      expect(
        TraceContext.buildTraceState('session=abc,token=xyz'),
        'cyi=1',
      );
    });

    test('the list is truncated to the W3C maximum of 32 members', () {
      final many =
          List.generate(40, (i) => 'k$i=v$i').join(','); // 40 benign members
      final out = TraceContext.buildTraceState(many).split(',');
      expect(out.length, 32);
      expect(out.first, 'cyi=1'); // our entry stays first
    });
  });

  group('TraceContext.filterBaggage', () {
    test('null/empty → null', () {
      expect(TraceContext.filterBaggage(null), isNull);
      expect(TraceContext.filterBaggage('  '), isNull);
    });

    test('benign members preserved', () {
      expect(TraceContext.filterBaggage('userId=42,plan=pro'),
          'userId=42,plan=pro');
    });

    test('members with a sensitive key removed', () {
      expect(TraceContext.filterBaggage('token=xyz,plan=pro'), 'plan=pro');
    });

    test('if every member is sensitive → null (header omitted)', () {
      expect(TraceContext.filterBaggage('token=xyz,secret=abc'), isNull);
    });
  });

  group('defaultSpanIdGenerator', () {
    test('produces distinct non-zero lowercase 16 hex', () {
      final a = defaultSpanIdGenerator();
      final b = defaultSpanIdGenerator();
      expect(TraceContext.isValidParentId(a), isTrue);
      expect(TraceContext.isValidParentId(b), isTrue);
      expect(a, isNot(b));
    });
  });
}
