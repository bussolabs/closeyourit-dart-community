import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Spies on a client's sends (uri/body) and on the transport close, so the
/// tests can tell which client — the old or the new one — sent or
/// was shut down during a re-init.
class _Spy {
  final List<Uri> uris = [];
  final List<dynamic> bodies = [];
  bool transportClosed = false;
}

/// Controllable `http.Client` that records requests on the [_Spy], simulates
/// online/offline and tracks closing (to verify that re-init closes the
/// previous client's transport — no orphan resource).
class _SpyHttpClient extends http.BaseClient {
  _SpyHttpClient(this._spy, {this.online = true, this.status = 202});

  final _Spy _spy;
  final bool online;
  final int status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _spy.uris.add(request.url);
    if (request is http.Request) _spy.bodies.add(jsonDecode(request.body));
    if (!online) throw http.ClientException('offline', request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"data":{}}')),
      status,
    );
  }

  @override
  void close() {
    _spy.transportClosed = true;
    super.close();
  }
}

/// In-memory [OfflineStore]: persisted events stay until they are
/// confirmed (`remove`). [recordFailure] does not drop (it is due again right away),
/// to reproduce an undelivered event that survives the re-init.
class _MemoryStore implements OfflineStore {
  final Map<String, PendingEvent> _pending = <String, PendingEvent>{};

  int get length => _pending.length;

  @override
  void add(String id,
      {required Uri uri, required Map<String, Object?> payload}) {
    _pending[id] = PendingEvent(id: id, uri: uri, payload: payload);
  }

  @override
  bool remove(String id) {
    _pending.remove(id);
    return true;
  }

  @override
  bool recordFailure(String id) => false; // stays pending, due again right away

  @override
  List<PendingEvent> readAll() => List<PendingEvent>.of(_pending.values);
}

CloseYourItOptions _opts() => CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      logsMinLevel: LogLevel.debug,
    );

CloseYourItClient _client(
  _Spy spy, {
  bool online = true,
  int status = 202,
  OfflineStore? store,
}) {
  final stats = Stats();
  return CloseYourItClient(
    _opts(),
    stats: stats,
    worker: BackgroundWorker(stats: stats),
    transport: Transport(
      token: 'cyi_t',
      stats: stats,
      client: _SpyHttpClient(spy, online: online, status: status),
    ),
    store: store,
  );
}

void main() {
  // Real binding: without it, the façade skips lifecycle/frame observers (pure tests).
  // Needed to verify that re-init does not pile up lifecycle observers.
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  FlutterExceptionHandler? originalOnError;

  setUp(() {
    // Neutralizes the flutter_test reporter: errors injected in the tests must
    // not make the test itself fail.
    originalOnError = FlutterError.onError;
    FlutterError.onError = (_) {};
  });

  tearDown(() async {
    await CloseYourIt.close();
    FlutterError.onError = originalOnError;
  });

  group('Re-init: safe close + new init (CYDA-12)', () {
    test('a FlutterError after re-init is captured only once', () async {
      final spyA = _Spy();
      final spyB = _Spy();
      final a = _client(spyA);
      final b = _client(spyB);

      await CloseYourIt.init(_opts(), client: a); // installIntegrations: true
      await CloseYourIt.init(_opts(), client: b); // re-init → close(a)

      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ));
      await CloseYourIt.flush(); // flush of the active client (b)
      await a.flush(); // forces any pending send of the old client

      expect(spyB.bodies, hasLength(1)); // the new client captures
      expect(spyA.bodies, isEmpty); // the old handler is no longer attached
    });

    test('an error on PlatformDispatcher after re-init is captured only once',
        () async {
      final spyA = _Spy();
      final spyB = _Spy();
      final a = _client(spyA);
      final b = _client(spyB);

      await CloseYourIt.init(_opts(), client: a);
      await CloseYourIt.init(_opts(), client: b);

      final handled = PlatformDispatcher.instance.onError!(
        StateError('async'),
        StackTrace.current,
      );
      await CloseYourIt.flush();
      await a.flush();

      expect(handled, isTrue);
      expect(spyB.bodies, hasLength(1));
      expect(spyA.bodies, isEmpty);
    });

    test('after re-init the active client is only the new one', () async {
      final a = _client(_Spy());
      final b = _client(_Spy());

      await CloseYourIt.init(_opts(), client: a);
      await CloseYourIt.init(_opts(), client: b);

      expect(identical(CloseYourIt.client, b), isTrue);
      expect(identical(CloseYourIt.client, a), isFalse);
    });

    test('re-init closes the previous client (no orphan resource)', () async {
      final spyA = _Spy();
      final a = _client(spyA);

      await CloseYourIt.init(_opts(), client: a, installIntegrations: false);
      expect(spyA.transportClosed, isFalse);

      await CloseYourIt.init(_opts(),
          client: _client(_Spy()), installIntegrations: false);

      expect(spyA.transportClosed, isTrue); // close(a) → transport closed
    });

    test('re-init without integrations restores the old client global handlers',
        () async {
      final beforeAny = FlutterError.onError;
      final a = _client(_Spy());

      await CloseYourIt.init(_opts(), client: a); // installs the handlers of a
      expect(FlutterError.onError, isNot(same(beforeAny)));

      // The new init does NOT install integrations: the handlers of a must still
      // go away (re-init = safe close), back to the original handler.
      await CloseYourIt.init(_opts(),
          client: _client(_Spy()), installIntegrations: false);

      expect(FlutterError.onError, same(beforeAny));
    });

    test(
        'errors persisted by the old client (failed send) are sent by the new one',
        () async {
      final store = _MemoryStore();
      final spyA = _Spy();
      final a = _client(spyA, online: false, store: store); // send fails

      await CloseYourIt.init(_opts(), client: a, installIntegrations: false);
      a.captureException(StateError('lost in the crash'));

      // Re-init: close(a) waits for the old client flush → the send fails and
      // the event stays in the store; the new client picks it up (replayPending).
      final spyB = _Spy();
      final b = _client(spyB, online: true, store: store);
      await CloseYourIt.init(_opts(), client: b, installIntegrations: false);
      await CloseYourIt.flush();

      expect(spyB.bodies, hasLength(1)); // the new client resent the event
      expect(store.length, 0); // confirmed → removed from the offline queue
    });

    test('only one lifecycle observer stays active after re-init', () async {
      final spyA = _Spy();
      final spyB = _Spy();
      final a = _client(spyA);
      final b = _client(spyB);

      await CloseYourIt.init(_opts(), client: a); // lifecycle observer of a
      await CloseYourIt.init(_opts(),
          client: b); // re-init → removes a, installs b

      a.log(LogLevel.info, 'from-A'); // a is closed → no-op
      b.log(LogLevel.info, 'from-B');

      // App in background: only the surviving observer (b) must drain the logs.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var i = 0; i < 50 && spyB.bodies.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await a.flush();

      expect(spyB.uris, hasLength(1));
      expect(spyB.uris.single.path, '/api/v1/projects/p1/logs');
      expect(spyA.bodies, isEmpty); // the old observer no longer flushes
    });
  });
}
