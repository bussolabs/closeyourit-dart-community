import 'package:closeyourit/closeyourit.dart';
import 'package:flutter_test/flutter_test.dart';

CloseYourItOptions _opts({bool enabled = true}) => CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      enabled: enabled,
    );

void main() {
  tearDown(() async {
    await CloseYourIt.close();
  });

  group('CloseYourIt façade', () {
    test('before init it is a no-op and disabled', () {
      expect(CloseYourIt.isEnabled, isFalse);
      // No exception even without init.
      CloseYourIt.captureException(StateError('x'));
      CloseYourIt.log(LogLevel.info, 'x');
      CloseYourIt.setTag('a', 'b');
      expect(CloseYourIt.stats, isEmpty);
    });

    test('init with an injected client → delegates', () async {
      final client = CloseYourItClient(_opts());
      await CloseYourIt.init(_opts(), client: client);
      expect(CloseYourIt.isEnabled, isTrue);
      expect(identical(CloseYourIt.client, client), isTrue);
    });

    test('init runs appRunner', () async {
      var ran = false;
      await CloseYourIt.init(_opts(), appRunner: () => ran = true);
      expect(ran, isTrue);
    });

    test('measure without init still runs the body', () async {
      final r = await CloseYourIt.measure('x', () async => 99);
      expect(r, 99);
    });

    test('close clears the client', () async {
      await CloseYourIt.init(_opts());
      expect(CloseYourIt.client, isNotNull);
      await CloseYourIt.close();
      expect(CloseYourIt.client, isNull);
      expect(CloseYourIt.isEnabled, isFalse);
    });

    test('disabled config → isEnabled false after init', () async {
      await CloseYourIt.init(_opts(enabled: false));
      expect(CloseYourIt.isEnabled, isFalse);
    });
  });

  group('CloseYourIt diagnostics (CYDA-13)', () {
    test('diagnostics before init is an empty snapshot', () {
      final d = CloseYourIt.diagnostics;
      expect(d[StatKey.sent], 0);
      expect(d.reason(DropReason.sampled), 0);
      expect(d.toMap(), isEmpty);
    });

    test('onDiagnostic receives the drops and diagnostics aggregates them',
        () async {
      final events = <DiagnosticEvent>[];
      final opts = CloseYourItOptions(
        endpointUrl: 'https://www.closeyour.it',
        token: 'cyi_t',
        projectId: 'p1',
        sampleRate:
            0.0, // every capture is dropped by sampling: nothing is sent
        onDiagnostic: events.add,
      );
      // Without integrations: no global handler, but the callback stays attached.
      await CloseYourIt.init(opts, installIntegrations: false);
      CloseYourIt.captureException(StateError('dropped'));

      expect(events.map((e) => e.reason), contains(DropReason.sampled));
      expect(CloseYourIt.diagnostics.reason(DropReason.sampled), 1);
      expect(CloseYourIt.diagnostics[StatKey.enqueued], 0);
    });

    test('onDiagnostic also works with an injected client', () async {
      final events = <DiagnosticEvent>[];
      final opts = CloseYourItOptions(
        endpointUrl: 'https://www.closeyour.it',
        token: 'cyi_t',
        projectId: 'p1',
        sampleRate: 0.0,
        onDiagnostic: events.add,
      );
      // An injected client is built with the same options: the callback must
      // stay attached on this path too.
      await CloseYourIt.init(opts,
          client: CloseYourItClient(opts), installIntegrations: false);
      CloseYourIt.captureException(StateError('x'));

      expect(events.map((e) => e.reason), contains(DropReason.sampled));
    });
  });
}
