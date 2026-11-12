import 'dart:async';
import 'dart:convert';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Test binding whose first frame is shown on demand.
///
/// flutter_test replaces `drawFrame` and never reports a rasterized frame, so
/// `waitUntilFirstFrameRasterized` would never complete. Here the test decides
/// when the first screen is on screen ([showFirstFrame]); the façade reads it
/// through the same binding API it uses in the app.
class _FirstFrameBinding extends AutomatedTestWidgetsFlutterBinding {
  Completer<void> _firstFrame = Completer<void>();

  @override
  bool get firstFrameRasterized => _firstFrame.isCompleted;

  @override
  Future<void> get waitUntilFirstFrameRasterized => _firstFrame.future;

  void showFirstFrame() {
    if (!_firstFrame.isCompleted) _firstFrame.complete();
  }

  /// A new start: no frame on screen yet.
  void resetFirstFrame() => _firstFrame = Completer<void>();
}

/// Records every body the client sends; [online] false makes every send fail.
class _SpyHttpClient extends http.BaseClient {
  _SpyHttpClient({this.online = true});

  final bool online;
  final List<Map<String, Object?>> bodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      bodies.add(jsonDecode(request.body) as Map<String, Object?>);
    }
    if (!online) throw http.ClientException('offline', request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"data":{}}')),
      202,
    );
  }
}

/// In-memory [OfflineStore]: records stay due until they are confirmed and a
/// failure never drops them.
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
  bool recordFailure(String id) => false;

  @override
  List<PendingEvent> readAll() => List<PendingEvent>.of(_pending.values);
}

final Uri _eventsUri =
    Uri.parse('https://www.closeyour.it/api/v1/projects/p1/events');

/// A store holding one error left over by a previous start.
_MemoryStore _leftover() {
  final store = _MemoryStore();
  store.add('left', uri: _eventsUri, payload: {'event_id': 'left'});
  return store;
}

CloseYourItOptions _opts() => CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
    );

CloseYourItClient _client(_SpyHttpClient spy, OfflineStore store) {
  final stats = Stats();
  return CloseYourItClient(
    _opts(),
    stats: stats,
    worker: BackgroundWorker(stats: stats),
    transport: Transport(token: 'cyi_t', stats: stats, client: spy),
    store: store,
  );
}

/// Lets the continuations scheduled on the first-frame future run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  final binding = _FirstFrameBinding();

  FlutterExceptionHandler? originalOnError;

  setUp(() {
    binding.resetFirstFrame();
    originalOnError = FlutterError.onError;
    FlutterError.onError = (_) {};
  });

  tearDown(() async {
    await CloseYourIt.close();
    FlutterError.onError = originalOnError;
  });

  group('Replay of leftover errors after the first frame (CYDA-31)', () {
    test('init does not wait for the leftovers: they go after the first frame',
        () async {
      final store = _leftover();
      final spy = _SpyHttpClient();
      final client = _client(spy, store);

      await CloseYourIt.init(_opts(), client: client);
      await client.flush();
      expect(spy.bodies, isEmpty); // nothing read or sent during init
      expect(store.length, 1);

      binding.showFirstFrame(); // the first screen is shown
      await _settle();
      await client.flush();

      expect(spy.bodies, hasLength(1));
      expect(spy.bodies.single['event_id'], 'left');
      expect(store.length, 0); // confirmed → removed
    });

    test('an error captured before the first frame is sent only once',
        () async {
      // Offline: every send fails and the records stay pending (due again),
      // so the deferred replay finds the in-flight error on disk too.
      final store = _leftover();
      final spy = _SpyHttpClient(online: false);
      final client = _client(spy, store);

      await CloseYourIt.init(_opts(), client: client);
      CloseYourIt.captureException(StateError('before first frame'));
      await client.flush();
      expect(spy.bodies, hasLength(1)); // the new error, sent right away
      expect(store.length, 2); // leftover + new error, both pending

      binding.showFirstFrame();
      await _settle();
      await client.flush();

      // Only the leftover is replayed: the new error is not sent again.
      expect(spy.bodies, hasLength(2));
      expect(spy.bodies.last['event_id'], 'left');
    });

    test('a client closed before the first frame does not replay', () async {
      final store = _leftover();
      final spy = _SpyHttpClient();
      final client = _client(spy, store);

      await CloseYourIt.init(_opts(), client: client);
      await CloseYourIt.close();
      binding.showFirstFrame();
      await _settle();

      expect(spy.bodies, isEmpty);
      expect(store.length, 1); // kept for the next start
    });

    test('first frame already on screen (re-init): replay right away',
        () async {
      binding.showFirstFrame();
      final store = _leftover();
      final spy = _SpyHttpClient();

      await CloseYourIt.init(_opts(), client: _client(spy, store));
      await CloseYourIt.flush();

      expect(spy.bodies, hasLength(1));
      expect(store.length, 0);
    });
  });
}
