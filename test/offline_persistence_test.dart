import 'dart:convert';
import 'dart:io';

import 'package:closeyourit/closeyourit.dart';
import 'package:closeyourit/src/background_worker.dart';
import 'package:closeyourit/src/file_offline_store.dart';
import 'package:closeyourit/src/offline_retry_policy.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:closeyourit/src/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Builds a client with a real (temp) on-disk store and a controllable transport
/// (success/failure/status on demand), to reproduce crash/offline and the
/// various end-to-end replay HTTP outcomes. [clock] (fixed) makes TTL and
/// backoff deterministic across boots; [retryPolicy] tunes expiry/attempts.
class _Harness {
  _Harness(
    this.dir, {
    required this.online,
    this.status = 202,
    DateTime Function()? clock,
    OfflineRetryPolicy retryPolicy = const OfflineRetryPolicy(),
  }) {
    final stats = Stats();
    this.stats = stats;
    final transport = Transport(
      token: 'cyi_t',
      stats: stats,
      client: MockClient((req) async {
        uris.add(req.url);
        bodies.add(jsonDecode(req.body) as Map<String, Object?>);
        if (!online) throw Exception('offline'); // no network → send fails
        return http.Response('{"data":{}}', status);
      }),
    );
    client = CloseYourItClient(
      _options(),
      transport: transport,
      stats: stats,
      worker: BackgroundWorker(stats: stats, maxQueue: 30),
      store: FileOfflineStore(dir, retryPolicy: retryPolicy, clock: clock),
    );
  }

  final Directory dir;
  bool online;

  /// HTTP status returned by the transport when [online] (ignored when offline,
  /// where the send fails before the response → null status on the client side).
  final int status;
  final List<Uri> uris = [];
  final List<Map<String, Object?>> bodies = [];
  late final CloseYourItClient client;
  late final Stats stats;

  int get filesOnDisk =>
      dir.existsSync() ? dir.listSync().whereType<File>().length : 0;
}

CloseYourItOptions _options({BeforeSend? beforeSend}) => CloseYourItOptions(
      endpointUrl: 'https://www.closeyour.it',
      token: 'cyi_t',
      projectId: 'p1',
      beforeSend: beforeSend,
    );

/// Store whose removal always fails ([remove] → false, best-effort failed),
/// to verify that the client does not count a drop that never happened.
class _UnremovableStore implements OfflineStore {
  _UnremovableStore(this._events);

  final List<PendingEvent> _events;
  int removeCalls = 0;

  @override
  void add(String id,
      {required Uri uri, required Map<String, Object?> payload}) {}

  @override
  bool remove(String id) {
    removeCalls++;
    return false; // removal failed: the record stays pending
  }

  @override
  bool recordFailure(String id) => false; // does not drop

  @override
  List<PendingEvent> readAll() => List.of(_events);
}

/// Unbounded in-memory store: every record stays due until it is removed and
/// failures never drop it, so a replay sees everything the session persisted.
class _KeepAllStore implements OfflineStore {
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
  bool recordFailure(String id) => false; // never drops: due again

  @override
  List<PendingEvent> readAll() => List.of(_pending.values);
}

/// Offline client (every send fails) over [store], to count what a replay
/// resends of the errors persisted by the same session.
CloseYourItClient _offlineClient(OfflineStore store, Stats stats) =>
    CloseYourItClient(
      _options(),
      transport: Transport(
        token: 'cyi_t',
        stats: stats,
        client: MockClient((req) async => throw Exception('offline')),
      ),
      stats: stats,
      // Room for every replayed record at once.
      worker: BackgroundWorker(stats: stats, maxQueue: 500),
      store: store,
    );

/// Writes a raw record (in the on-disk format) to control the retry state,
/// age and endpoint in the queue end-to-end tests.
void _writeRaw(
  Directory dir,
  String id,
  Uri uri,
  Map<String, Object?> payload, {
  required DateTime storedAt,
  int attemptCount = 0,
  DateTime? nextAttemptAt,
}) {
  File('${dir.path}/$id.json').writeAsStringSync(jsonEncode({
    'v': 2,
    'uri': uri.toString(),
    'payload': payload,
    'stored_at': storedAt.toIso8601String(),
    'attempt_count': attemptCount,
    'next_attempt_at': (nextAttemptAt ?? storedAt).toIso8601String(),
  }));
}

void main() {
  late Directory dir;

  // Fixed instant: makes TTL and backoff windows deterministic across boots.
  final t0 = DateTime.utc(2026, 7, 27, 12);
  final uri = Uri.parse('https://www.closeyour.it/api/v1/projects/p1/events');

  setUp(() => dir = Directory.systemTemp.createTempSync('cyi_offline_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('Offline persistence of errors (DoD: survives crash/offline)', () {
    test(
        'offline: the error is persisted to disk and NOT confirmed (send fails)',
        () async {
      final h = _Harness(dir, online: false);
      h.client
          .captureException(StateError('boom'), stackTrace: StackTrace.current);
      await h.client.flush();

      expect(h.stats[StatKey.persisted], 1);
      expect(h.stats[StatKey.sent], 0);
      expect(h.stats[StatKey.failed], greaterThanOrEqualTo(1));
      expect(h.filesOnDisk, 1); // stays on disk for the next start
    });

    test(
        'hard crash: the file is on disk already at capture, before any flush/send',
        () {
      final h = _Harness(dir, online: false);
      // No await, no flush: simulates the process dying right after.
      h.client.captureException(StateError('hard crash'));
      expect(h.filesOnDisk, 1); // synchronous persistence → survives the crash
    });

    test('restart: a new client picks the event up from disk and sends it',
        () async {
      // Boot 1 — offline: the error ends up on disk, never sent.
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('lost in the crash'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);
      final persisted = jsonDecode(
        File(dir.listSync().whereType<File>().single.path).readAsStringSync(),
      ) as Map<String, Object?>;

      // Boot 2 — online, past the backoff window: replay picks it up and sends it.
      final boot2 = _Harness(dir,
          online: true, clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();

      expect(boot2.stats[StatKey.replayed], 1);
      expect(boot2.stats[StatKey.sent], 1);
      expect(boot2.bodies, hasLength(1));
      // What reached the backend is exactly the persisted event.
      expect(boot2.bodies.single['event_id'],
          (persisted['payload'] as Map)['event_id']);
      expect(boot2.filesOnDisk, 0); // confirmed → removed from disk
    });

    test(
        'deferred replay: an error captured before it is sent only once (CYDA-31)',
        () async {
      // Boot 1 — offline: one leftover error on disk.
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('left over'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 — the app captures an error before the (deferred) replay runs:
      // its send is already in flight and its record is on disk, due now.
      final boot2 = _Harness(dir,
          online: true, clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.captureException(StateError('before first frame'));
      expect(boot2.filesOnDisk, 2);
      boot2.client.replayPending();
      await boot2.client.flush();

      // Only the leftover is replayed: the in-flight one is not sent twice.
      expect(boot2.stats[StatKey.replayed], 1);
      expect(boot2.bodies, hasLength(2));
      final eventIds = boot2.bodies.map((b) => b['event_id']).toList();
      expect(eventIds.toSet(), hasLength(2));
      expect(boot2.filesOnDisk, 0); // both confirmed → removed from disk
    });

    test('replayPending after close sends nothing (CYDA-31)', () async {
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('left over'));
      await boot1.client.flush();

      final boot2 = _Harness(dir,
          online: true, clock: () => t0.add(const Duration(hours: 1)));
      await boot2.client.close();
      boot2.client.replayPending(); // e.g. first frame after a re-init

      expect(boot2.stats[StatKey.replayed], 0);
      expect(boot2.bodies, isEmpty);
      expect(boot2.filesOnDisk, 1); // still on disk for the next start
    });

    test(
        'in-flight ids are kept only until the replay reads the queue (CYDA-31)',
        () async {
      final stats = Stats();
      final store = _KeepAllStore();
      final client = _offlineClient(store, stats);

      client.captureException(StateError('before the replay'));
      await client.flush();
      client.replayPending(); // skips the in-flight error
      await client.flush();
      expect(stats[StatKey.replayed], 0);

      // After the replay nothing is remembered any more: a later error is not
      // tracked and the earlier id was released (a second replay — never
      // done by the façade — would see both as plain leftovers).
      client.captureException(StateError('after the replay'));
      await client.flush();
      client.replayPending();
      await client.flush();
      expect(stats[StatKey.replayed], 2);
      expect(store.length, 2);
    });

    test('in-flight ids stay bounded during a long offline session (CYDA-31)',
        () async {
      final stats = Stats();
      final store = _KeepAllStore();
      final client = _offlineClient(store, stats);

      // 300 errors before the replay, far more than any real queue keeps.
      for (var i = 0; i < 300; i++) {
        client.captureException(StateError('offline $i'));
        await client.flush();
      }
      client.replayPending();
      await client.flush();

      // At most 256 ids are remembered (the newest ones): only the 44 oldest,
      // which a real store would have evicted long before, count as leftovers.
      expect(stats[StatKey.replayed], 300 - 256);
    });

    test('online: the error is sent and removed from disk on 2xx', () async {
      final h = _Harness(dir, online: true);
      h.client.captureException(StateError('x'));
      await h.client.flush();

      expect(h.stats[StatKey.persisted], 1);
      expect(h.stats[StatKey.sent], 1);
      expect(h.filesOnDisk, 0); // confirmation → no leftovers on disk
    });

    test('replay still offline: the event stays on disk, it is not lost',
        () async {
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('x'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 offline again past the backoff: replay tries, fails, but does not delete.
      final boot2 = _Harness(dir,
          online: false, clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.stats[StatKey.replayed], 1); // it really retried
      expect(boot2.filesOnDisk, 1); // retryable on the next boot
    });

    test('captureMessage is persisted just like captureException', () async {
      final h = _Harness(dir, online: false);
      h.client.captureMessage('diagnostics', level: 'warning');
      await h.client.flush();
      expect(h.stats[StatKey.persisted], 1);
      expect(h.filesOnDisk, 1);
    });
  });

  group('Offline queue expiry and backoff (CYDA-11)', () {
    test(
        'backoff: a failed error is NOT retried on the immediately following boot',
        () async {
      // Boot 1 offline: capture, fail, reschedule with backoff (future next).
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('x'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 at the same instant: not due yet → no request.
      final boot2 = _Harness(dir, online: true, clock: () => t0);
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.stats[StatKey.replayed], 0);
      expect(boot2.uris, isEmpty); // no network burst
      expect(boot2.filesOnDisk, 1); // stays for a future start
    });

    test(
        'backoff: once the window has passed, the error is due again and retried',
        () async {
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('x'));
      await boot1.client.flush();

      // Boot 2 an hour later: past the backoff → due → retried and confirmed.
      final boot2 = _Harness(dir,
          online: true, clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.stats[StatKey.replayed], 1);
      expect(boot2.stats[StatKey.sent], 1);
      expect(boot2.filesOnDisk, 0);
    });

    test('Scenario 1: from a mixed queue only valid, due events are scheduled',
        () async {
      // Queue with: a recent due event, an expired one (past TTL) and one already
      // retried and waiting on backoff (next in the future).
      _writeRaw(dir, 'recent', uri, {'event_id': 'recent'},
          storedAt: t0.subtract(const Duration(minutes: 1)));
      _writeRaw(dir, 'expired', uri, {'event_id': 'expired'},
          storedAt: t0.subtract(const Duration(days: 8))); // past the 7-day TTL
      _writeRaw(dir, 'already_retried', uri, {'event_id': 'already_retried'},
          storedAt: t0.subtract(const Duration(hours: 2)),
          attemptCount: 2,
          nextAttemptAt: t0.add(const Duration(hours: 1))); // not due

      final boot = _Harness(dir, online: true, clock: () => t0);
      boot.client.replayPending();
      await boot.client.flush();

      // Only the recent due one was sent: no burst from the whole backlog.
      expect(boot.uris, hasLength(1));
      expect(boot.bodies.single['event_id'], 'recent');
      expect(boot.stats[StatKey.sent], 1);
      // The expired one was deleted (TTL); the not-due one stays for a future start.
      expect(File('${dir.path}/expired.json').existsSync(), isFalse);
      expect(File('${dir.path}/already_retried.json').existsSync(), isTrue);
      // The confirmed recent one was removed.
      expect(File('${dir.path}/recent.json').existsSync(), isFalse);
    });

    test(
        'attempts exhausted at the first failure (maxAttempts=1): dropped and counted',
        () async {
      final boot = _Harness(dir,
          online: false, retryPolicy: const OfflineRetryPolicy(maxAttempts: 1));
      boot.client.captureException(StateError('x'));
      await boot.client.flush();

      expect(boot.stats[StatKey.persisted], 1);
      expect(boot.stats[StatKey.discarded],
          1); // attempts exhausted → drop counted
      expect(boot.stats.drops(DropReason.maxAttempts), 1); // structured reason
      expect(boot.filesOnDisk, 0); // it does not stay to be retried forever
    });

    test(
        'attempts exhausted after the cap (maxAttempts=2): the 2nd attempt drops',
        () async {
      const policy = OfflineRetryPolicy(maxAttempts: 2);
      // Boot 1 offline: 1st failure → attempt=1 (<2) → stays.
      final boot1 =
          _Harness(dir, online: false, retryPolicy: policy, clock: () => t0);
      boot1.client.captureException(StateError('x'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 offline past the backoff: 2nd failure → attempt=2 (=X) → dropped.
      final boot2 = _Harness(dir,
          online: false,
          retryPolicy: policy,
          clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.stats[StatKey.discarded], 1);
      expect(boot2.stats.drops(DropReason.maxAttempts), 1); // structured reason
      expect(boot2.filesOnDisk, 0); // no longer retried
    });
  });

  group('No plaintext PII/secret on disk (DoD)', () {
    test('an attribute with a sensitive key is [FILTERED] in the file on disk',
        () async {
      final h = _Harness(dir, online: false);
      h.client.setExtra('api_key', 'sk_live_should_not_hit_disk');
      h.client.captureException(StateError('x'));
      await h.client.flush();

      final raw =
          File(dir.listSync().whereType<File>().single.path).readAsStringSync();
      expect(raw, isNot(contains('sk_live_should_not_hit_disk')));
      expect(raw, contains('[FILTERED]'));
    });

    test(
        'a secret injected via beforeSend (downstream of the scope) is redacted on disk',
        () async {
      // beforeSend can add fields after the scope scrubbing: the store
      // re-scrubs → the disk never contains the plaintext secret.
      final stats = Stats();
      final client = CloseYourItClient(
        _options(beforeSend: (p) => {...p, 'authorization': 'Bearer LEAK'}),
        transport: Transport(
          token: 'cyi_t',
          stats: stats,
          client: MockClient((_) async => throw Exception('offline')),
        ),
        stats: stats,
        worker: BackgroundWorker(stats: stats),
        store: FileOfflineStore(dir),
      );
      client.captureException(StateError('x'));
      await client.flush();

      final raw =
          File(dir.listSync().whereType<File>().single.path).readAsStringSync();
      expect(raw, isNot(contains('LEAK')));
      expect(raw, contains('[FILTERED]'));
    });
  });

  group('Without a store (default) the behaviour is unchanged', () {
    test('captureException persists nothing and sends directly', () async {
      final stats = Stats();
      final bodies = <Object?>[];
      final client = CloseYourItClient(
        _options(),
        transport: Transport(
          token: 'cyi_t',
          stats: stats,
          client: MockClient((req) async {
            bodies.add(jsonDecode(req.body));
            return http.Response('{"data":{}}', 202);
          }),
        ),
        stats: stats,
        worker: BackgroundWorker(stats: stats),
        // store: null → no persistence
      );
      client.captureException(StateError('x'));
      await client.flush();

      expect(stats[StatKey.persisted], 0);
      expect(stats[StatKey.sent], 1);
      expect(bodies, hasLength(1));
      expect(client.hasOfflineStore, isFalse);
    });
  });

  group(
      'Dropping permanent errors from the offline queue '
      '(DoD: only network/408/425/429/5xx stay retryable)', () {
    // Permanent rejections: retrying does not make them valid (invalid payload, not
    // authorized, too large…). They must be dropped from disk, not retried.
    for (final status in [400, 401, 403, 404, 413, 422]) {
      test('replay with permanent rejection $status: dropped from disk',
          () async {
        // Boot 1 offline: the error stays on disk (no response from the backend).
        final boot1 = _Harness(dir, online: false, clock: () => t0);
        boot1.client.captureException(StateError('permanent $status'));
        await boot1.client.flush();
        expect(boot1.filesOnDisk, 1);

        // Boot 2 online past the backoff: the replay receives the permanent rejection → drop.
        final boot2 = _Harness(dir,
            online: true,
            status: status,
            clock: () => t0.add(const Duration(hours: 1)));
        boot2.client.replayPending();
        await boot2.client.flush();

        expect(boot2.stats[StatKey.replayed], 1);
        expect(boot2.stats[StatKey.sent], 0);
        expect(boot2.stats[StatKey.discarded], 1); // diagnosable drop reason
        // Structured reason: 413 = over the server-side payload budget (CYRA-112);
        // every other permanent rejection is permanentReject.
        final expectedReason =
            status == 413 ? DropReason.tooLarge : DropReason.permanentReject;
        expect(boot2.stats.drops(expectedReason), 1);
        expect(boot2.filesOnDisk, 0); // dropped: it no longer clogs the queue
      });
    }

    // Retryable outcomes: transient (timeout, rate limit, server errors). The 429
    // stays queued to honour the Retry-After wait on the next attempt.
    for (final status in [408, 425, 429, 500, 502, 503]) {
      test('replay with retryable outcome $status: stays on disk', () async {
        final boot1 = _Harness(dir, online: false, clock: () => t0);
        boot1.client.captureException(StateError('retryable $status'));
        await boot1.client.flush();
        expect(boot1.filesOnDisk, 1);

        final boot2 = _Harness(dir,
            online: true,
            status: status,
            clock: () => t0.add(const Duration(hours: 1)));
        boot2.client.replayPending();
        await boot2.client.flush();

        expect(boot2.stats[StatKey.replayed], 1); // it really retried
        expect(boot2.stats[StatKey.discarded], 0); // not dropped
        expect(boot2.filesOnDisk, 1); // retryable on the next boot
      });
    }

    test(
        'replay with a network error (null status): stays retryable, does not drop',
        () async {
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('no network'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 still offline past the backoff → the send fails before the response (null).
      final boot2 = _Harness(dir,
          online: false, clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();

      expect(boot2.stats[StatKey.discarded], 0); // no network ≠ rejection
      expect(boot2.filesOnDisk, 1);
    });

    test(
        'online capture with permanent rejection: dropped right away, no leftover on disk',
        () async {
      // The classification also applies to the first send (not only to replay): a
      // freshly captured permanent one must not stay on disk to be retried at boot.
      final h = _Harness(dir, online: true, status: 400);
      h.client.captureException(StateError('invalid payload'));
      await h.client.flush();

      expect(h.stats[StatKey.persisted], 1);
      expect(h.stats[StatKey.sent], 0);
      expect(h.stats[StatKey.discarded], 1);
      expect(h.filesOnDisk, 0); // no leftover → no retry at boot
    });

    test(
        'Scenario 1: a permanent one is not retried forever across multiple restarts',
        () async {
      // Boot 1 offline: the event stays on disk.
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('rejected on replay'));
      await boot1.client.flush();
      expect(boot1.filesOnDisk, 1);

      // Boot 2 online past the backoff: the replay receives a permanent rejection → dropped.
      final boot2 = _Harness(dir,
          online: true,
          status: 403,
          clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.filesOnDisk, 0);

      // Boot 3: there is nothing left to retry — no send goes out.
      final boot3 = _Harness(dir,
          online: true,
          status: 403,
          clock: () => t0.add(const Duration(hours: 2)));
      boot3.client.replayPending();
      await boot3.client.flush();
      expect(boot3.stats[StatKey.replayed], 0);
      expect(boot3.uris, isEmpty); // the queue does not retry the dropped event
    });

    test(
        'the queue stays available for deliverable events after dropping a permanent one',
        () async {
      final boot1 = _Harness(dir, online: false, clock: () => t0);
      boot1.client.captureException(StateError('permanente'));
      await boot1.client.flush();

      // The permanent one is dropped.
      final boot2 = _Harness(dir,
          online: true,
          status: 400,
          clock: () => t0.add(const Duration(hours: 1)));
      boot2.client.replayPending();
      await boot2.client.flush();
      expect(boot2.filesOnDisk, 0);

      // A new deliverable event passes normally: the queue is free.
      final boot3 = _Harness(dir, online: true);
      boot3.client.captureException(StateError('consegnabile'));
      await boot3.client.flush();
      expect(boot3.stats[StatKey.sent], 1);
      expect(boot3.filesOnDisk, 0);
    });

    test(
        'failed disk removal: the permanent one is NOT counted as dropped (best-effort drop)',
        () async {
      // A remove that always fails: without the guard on the outcome, discarded would
      // inflate while the event stays on disk and retryable at boot.
      final stats = Stats();
      final store = _UnremovableStore([
        PendingEvent(
          id: 'stuck',
          uri: Uri.parse('https://www.closeyour.it/api/v1/projects/p1/events'),
          payload: const {'event_id': 'e1'},
        ),
      ]);
      final client = CloseYourItClient(
        _options(),
        transport: Transport(
          token: 'cyi_t',
          stats: stats,
          client:
              MockClient((_) async => http.Response('{}', 400)), // permanent
        ),
        stats: stats,
        worker: BackgroundWorker(stats: stats),
        store: store,
      );
      client.replayPending();
      await client.flush();

      expect(
          store.removeCalls, greaterThanOrEqualTo(1)); // the drop was attempted
      expect(
          stats[StatKey.discarded], 0); // but it did not happen → not counted
    });
  });
}
