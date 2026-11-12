import 'dart:convert';
import 'dart:io';

import 'package:closeyourit/src/file_offline_store.dart';
import 'package:closeyourit/src/offline_retry_policy.dart';
import 'package:closeyourit/src/stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cyi_store_'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final uri = Uri.parse('https://www.closeyour.it/api/v1/projects/p/events');

  // Fixed instant for deterministic time/backoff tests (no real now).
  final t0 = DateTime.utc(2026, 7, 27, 12);
  DateTime fixedClock() => t0;

  group('FileOfflineStore', () {
    test('add then readAll returns the persisted event', () {
      final store = FileOfflineStore(dir);
      store
          .add('id1', uri: uri, payload: {'event_id': 'id1', 'level': 'error'});

      final pending = store.readAll();
      expect(pending, hasLength(1));
      expect(pending.single.id, 'id1');
      expect(pending.single.uri, uri);
      expect(pending.single.payload['level'], 'error');
    });

    test('add writes schema v2 and the initial retry state', () {
      final store = FileOfflineStore(dir, clock: fixedClock);
      store.add('id1', uri: uri, payload: {'level': 'error'});

      final record = jsonDecode(File('${dir.path}/id1.json').readAsStringSync())
          as Map<String, Object?>;
      expect(record['v'], 2);
      expect(record['attempt_count'], 0);
      // New event sendable right away: next_attempt_at == stored_at.
      expect(record['stored_at'], t0.toIso8601String());
      expect(record['next_attempt_at'], t0.toIso8601String());
    });

    test(
        'add is synchronous: the file is on disk before returning (crash durability)',
        () {
      final store = FileOfflineStore(dir);
      store.add('crash1', uri: uri, payload: {'level': 'fatal'});
      // No await, no flush: the file must already exist.
      expect(File('${dir.path}/crash1.json').existsSync(), isTrue);
    });

    test('remove deletes the event and confirms the outcome (true)', () {
      final store = FileOfflineStore(dir);
      store.add('id1', uri: uri, payload: {'a': 1});
      store.add('id2', uri: uri, payload: {'a': 2});
      expect(store.remove('id1'), isTrue); // successful removal

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['id2']);
    });

    test('readAll sorts by ascending stored_at (oldest-first)', () {
      final store = FileOfflineStore(dir);
      // Recent timestamps (within the TTL) and out of order, to verify the sort.
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'b', uri, {'n': 2},
          storedAt: now.subtract(const Duration(minutes: 2)));
      _writeRaw(dir, 'a', uri, {'n': 1},
          storedAt: now.subtract(const Duration(minutes: 3)));
      _writeRaw(dir, 'c', uri, {'n': 3},
          storedAt: now.subtract(const Duration(minutes: 1)));

      expect(store.readAll().map((e) => e.id).toList(), ['a', 'b', 'c']);
    });

    test('no plaintext secret on disk: the payload is scrubbed before writing',
        () {
      final store = FileOfflineStore(dir);
      store.add('sec', uri: uri, payload: {
        'authorization': 'Bearer super-secret',
        'nested': {'api_key': 'sk_live_123', 'ok': 'plain'},
      });

      final raw = File('${dir.path}/sec.json').readAsStringSync();
      expect(raw, isNot(contains('super-secret')));
      expect(raw, isNot(contains('sk_live_123')));
      expect(raw, contains('[FILTERED]'));
      expect(raw, contains('plain')); // non-sensitive fields stay

      // What is read back is redacted too.
      final payload = store.readAll().single.payload;
      expect(payload['authorization'], '[FILTERED]');
      expect((payload['nested'] as Map)['api_key'], '[FILTERED]');
      expect((payload['nested'] as Map)['ok'], 'plain');
    });

    test('maxEvents cap: beyond the cap it evicts the oldest', () {
      final store = FileOfflineStore(dir, maxEvents: 3);
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 3; i++) {
        _writeRaw(dir, 'e$i', uri, {'n': i},
            storedAt: now.subtract(Duration(minutes: 3 - i)));
      }
      // The 4th add exceeds the cap → evicts e0 (the oldest), keeps 3 files.
      store.add('e3', uri: uri, payload: {'n': 3});

      final ids = store.readAll().map((e) => e.id).toSet();
      expect(ids.length, 3);
      expect(ids, isNot(contains('e0')));
      expect(ids, contains('e3'));
    });

    test('full queue: add evicts the oldest without reading the other files',
        () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir, maxEvents: 3, onDrop: drops.add);
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 3; i++) {
        _writeRaw(dir, 'e$i', uri, {'n': i},
            storedAt: now.subtract(Duration(minutes: 3 - i)));
      }
      // Unreadable content: had add decoded it, it would be dropped as corrupted.
      final broken = File('${dir.path}/e1.json');
      broken.writeAsStringSync('{ not json');
      broken.setLastModifiedSync(now.subtract(const Duration(minutes: 2)));

      store.add('e3', uri: uri, payload: {'n': 3});

      expect(File('${dir.path}/e0.json').existsSync(), isFalse); // oldest
      expect(File('${dir.path}/e1.json').existsSync(), isTrue); // not opened
      expect(File('${dir.path}/e3.json').existsSync(), isTrue);
      expect(drops, [DropReason.evicted]); // no storeCorrupted from add
    });

    test('add does not open or decode the other pending files (CYDA-31)', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir, onDrop: drops.add);
      File('${dir.path}/broken.json').writeAsStringSync('{ not json');

      // Several captures in a row: none of them reads the broken record.
      for (var i = 0; i < 5; i++) {
        store.add('id$i', uri: uri, payload: {'n': i});
      }

      expect(File('${dir.path}/broken.json').existsSync(), isTrue);
      expect(drops, isEmpty);
      // The full read at startup is still where corrupted records are dropped.
      expect(store.readAll(), hasLength(5));
      expect(drops, [DropReason.storeCorrupted]);
    });

    test('readAll realigns the eviction order with the real stored_at', () {
      final store = FileOfflineStore(dir, maxEvents: 2);
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'old', uri, {'n': 1},
          storedAt: now.subtract(const Duration(hours: 2)));
      _writeRaw(dir, 'new', uri, {'n': 2},
          storedAt: now.subtract(const Duration(hours: 1)));
      // Rewritten after a failed attempt: the file looks newer than it is.
      final aMinuteAgo = now.subtract(const Duration(minutes: 1));
      File('${dir.path}/old.json').setLastModifiedSync(now);
      File('${dir.path}/new.json').setLastModifiedSync(aMinuteAgo);

      store.readAll(); // startup read: real stored_at replace the file times
      store.add('latest', uri: uri, payload: {'n': 3});

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['new', 'latest']); // the really oldest one was evicted
    });

    test('remove and dropped records free their slot in the index', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir,
          maxEvents: 2,
          retryPolicy: const OfflineRetryPolicy(maxAttempts: 1),
          onDrop: drops.add);
      store.add('a', uri: uri, payload: {'n': 1});
      store.add('b', uri: uri, payload: {'n': 2});

      expect(store.remove('a'), isTrue);
      store.add('c', uri: uri, payload: {'n': 3}); // slot freed by remove
      expect(store.recordFailure('b'), isTrue); // attempts exhausted → dropped
      store.add('d', uri: uri, payload: {'n': 4}); // slot freed by the drop

      expect(drops, isEmpty); // nothing evicted for capacity
      expect(store.readAll().map((e) => e.id).toSet(), {'c', 'd'});
    });

    test('a file added from outside joins the index at the next full read', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir, maxEvents: 2, onDrop: drops.add);
      final now = DateTime.now().toUtc();
      store.add('a', uri: uri, payload: {'n': 1}); // index built here
      _writeRaw(dir, 'outside', uri, {'n': 0},
          storedAt: now.subtract(const Duration(hours: 1)));

      store.readAll(); // realigns with the files actually present
      store.add('b', uri: uri, payload: {'n': 2}); // at the cap → evicts

      expect(drops, [DropReason.evicted]);
      expect(File('${dir.path}/outside.json').existsSync(), isFalse);
      expect(store.readAll().map((e) => e.id).toSet(), {'a', 'b'});
    });

    test('corrupted file: skipped (and deleted), does not crash readAll', () {
      final store = FileOfflineStore(dir);
      File('${dir.path}/broken.json').writeAsStringSync('{ not json');
      store.add('good', uri: uri, payload: {'ok': true});

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['good']);
      expect(File('${dir.path}/broken.json').existsSync(), isFalse);
    });

    test('readAll on a missing directory → empty list, does not throw', () {
      final missing = Directory('${dir.path}/nope');
      final store = FileOfflineStore(missing);
      expect(store.readAll(), isEmpty);
    });

    test(
        'remove of a missing id does not throw and returns true (already missing)',
        () {
      final store = FileOfflineStore(dir);
      expect(store.remove('ghost'), isTrue); // already not pending
    });
  });

  group('FileOfflineStore — TTL and backoff (CYDA-11)', () {
    test('readAll drops events past the TTL (too old) and deletes them', () {
      final store = FileOfflineStore(dir,
          retryPolicy: const OfflineRetryPolicy(ttl: Duration(days: 7)));
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'expired', uri, {'n': 1},
          storedAt: now.subtract(const Duration(days: 8))); // past TTL
      _writeRaw(dir, 'recent', uri, {'n': 2},
          storedAt: now.subtract(const Duration(hours: 1))); // within TTL

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['recent']); // only the valid one is scheduled
      expect(File('${dir.path}/expired.json').existsSync(), isFalse); // deleted
      expect(File('${dir.path}/recent.json').existsSync(), isTrue);
    });

    test(
        'readAll excludes events not yet due (backoff in progress) but leaves them on disk',
        () {
      final store = FileOfflineStore(dir, clock: fixedClock);
      // Due: next_attempt_at in the past.
      _writeRaw(dir, 'due', uri, {'n': 1},
          storedAt: t0.subtract(const Duration(minutes: 10)),
          attemptCount: 1,
          nextAttemptAt: t0.subtract(const Duration(minutes: 1)));
      // Waiting on backoff: next_attempt_at in the future.
      _writeRaw(dir, 'waiting', uri, {'n': 2},
          storedAt: t0.subtract(const Duration(minutes: 10)),
          attemptCount: 1,
          nextAttemptAt: t0.add(const Duration(hours: 1)));

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['due']); // only the due one is scheduled
      // The not-due one is NOT lost: it stays on disk for a later start.
      expect(File('${dir.path}/waiting.json').existsSync(), isTrue);
    });

    test(
        'recordFailure increments attempts and reschedules with backoff (deterministic)',
        () {
      const policy = OfflineRetryPolicy(maxAttempts: 5);
      final store =
          FileOfflineStore(dir, retryPolicy: policy, clock: fixedClock);
      store.add('e', uri: uri, payload: {'n': 1});

      expect(store.recordFailure('e'), isFalse); // rescheduled, not dropped

      final record = jsonDecode(File('${dir.path}/e.json').readAsStringSync())
          as Map<String, Object?>;
      expect(record['attempt_count'], 1);
      final expectedNext = t0.add(policy.backoffFor('e', 1));
      expect(record['next_attempt_at'], expectedNext.toIso8601String());
      // The next attempt is scheduled in the future (no immediate retry).
      expect(expectedNext.isAfter(t0), isTrue);
    });

    test(
        'max attempts: after X-1 failures it stays, on the X-th it is dropped, X+1 is missing',
        () {
      const maxAttempts = 3;
      final store = FileOfflineStore(dir,
          retryPolicy: const OfflineRetryPolicy(maxAttempts: maxAttempts),
          clock: fixedClock);
      store.add('e', uri: uri, payload: {'n': 1});

      // X-1 = 2 failures: the record stays retryable.
      expect(store.recordFailure('e'), isFalse); // attempt 1
      expect(store.recordFailure('e'), isFalse); // attempt 2 (X-1)
      expect(File('${dir.path}/e.json').existsSync(), isTrue);

      // X-th failure: attempts exhausted → dropped.
      expect(store.recordFailure('e'), isTrue); // attempt 3 (X)
      expect(File('${dir.path}/e.json').existsSync(), isFalse);

      // X+1: the record is gone → no further drop.
      expect(store.recordFailure('e'), isFalse); // (X+1) missing
    });

    test('recordFailure of a missing id does not throw and returns false', () {
      final store = FileOfflineStore(dir);
      expect(store.recordFailure('ghost'), isFalse);
    });

    test('migration: a legacy record (without v/attempt/next) is read and due',
        () {
      final store = FileOfflineStore(dir, clock: fixedClock);
      // Legacy format: only uri/payload/stored_at.
      File('${dir.path}/legacy.json').writeAsStringSync(jsonEncode({
        'uri': uri.toString(),
        'payload': {'event_id': 'old'},
        'stored_at': t0.subtract(const Duration(minutes: 5)).toIso8601String(),
      }));

      final pending = store.readAll();
      expect(pending, hasLength(1));
      expect(pending.single.id, 'legacy');
      expect(pending.single.payload['event_id'], 'old');
    });
  });

  group('FileOfflineStore — endpoint authority (CYDA-11, security)', () {
    final endpoint = Uri.parse('https://www.closeyour.it');

    test('drops records bound for an unexpected host (no redirection)', () {
      final store = FileOfflineStore(dir, endpoint: endpoint);
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'evil', Uri.parse('https://evil.example.com/api/store'),
          {'n': 1},
          storedAt: now.subtract(const Duration(minutes: 1)));
      _writeRaw(dir, 'ok', uri, {'n': 2},
          storedAt: now.subtract(const Duration(minutes: 1)));

      final ids = store.readAll().map((e) => e.id).toList();
      expect(ids, ['ok']); // only the expected host is scheduled
      expect(File('${dir.path}/evil.json').existsSync(), isFalse); // dropped
    });

    test('accepts the apex/www variant of the same host', () {
      final store = FileOfflineStore(dir, endpoint: endpoint);
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'apex',
          Uri.parse('https://closeyour.it/api/v1/projects/p/events'), {'n': 1},
          storedAt: now.subtract(const Duration(minutes: 1)));

      expect(store.readAll().map((e) => e.id).toList(), ['apex']);
    });

    test('without an enforced endpoint it applies no constraint (compat)', () {
      final store = FileOfflineStore(dir); // no endpoint
      final now = DateTime.now().toUtc();
      _writeRaw(
          dir, 'anyhost', Uri.parse('https://elsewhere.example/x'), {'n': 1},
          storedAt: now.subtract(const Duration(minutes: 1)));

      expect(store.readAll().map((e) => e.id).toList(), ['anyhost']);
    });
  });

  group('FileOfflineStore — onDrop diagnostic sink (CYDA-13)', () {
    test('readAll: an event expired by TTL reports expired', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir,
          retryPolicy: const OfflineRetryPolicy(ttl: Duration(days: 7)),
          onDrop: drops.add);
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'expired', uri, {'n': 1},
          storedAt: now.subtract(const Duration(days: 8)));

      store.readAll();
      expect(drops, [DropReason.expired]);
    });

    test('add at the capacity cap: the eviction reports evicted', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir, maxEvents: 2, onDrop: drops.add);
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 2; i++) {
        _writeRaw(dir, 'e$i', uri, {'n': i},
            storedAt: now.subtract(Duration(minutes: 2 - i)));
      }
      store.add('e2', uri: uri, payload: {'n': 2}); // exceeds the cap

      expect(drops, [DropReason.evicted]);
    });

    test('readAll: a corrupted record reports storeCorrupted', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir, onDrop: drops.add);
      File('${dir.path}/broken.json').writeAsStringSync('{ not json');

      store.readAll();
      expect(drops, [DropReason.storeCorrupted]);
    });

    test('readAll: a record bound for a disallowed host reports storeCorrupted',
        () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir,
          endpoint: Uri.parse('https://www.closeyour.it'), onDrop: drops.add);
      final now = DateTime.now().toUtc();
      _writeRaw(
          dir, 'evil', Uri.parse('https://evil.example/api/store'), {'n': 1},
          storedAt: now.subtract(const Duration(minutes: 1)));

      store.readAll();
      expect(drops, [DropReason.storeCorrupted]);
    });

    test('an expired record is reported only once, not on every read', () {
      final drops = <DropReason>[];
      final store = FileOfflineStore(dir,
          retryPolicy: const OfflineRetryPolicy(ttl: Duration(days: 7)),
          onDrop: drops.add);
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'expired', uri, {'n': 1},
          storedAt: now.subtract(const Duration(days: 8)));

      store.readAll();
      store.readAll(); // the file is already deleted: no second report
      expect(drops, [DropReason.expired]);
    });

    test('a sink that throws does not break the store', () {
      final store = FileOfflineStore(dir,
          retryPolicy: const OfflineRetryPolicy(ttl: Duration(days: 7)),
          onDrop: (_) => throw StateError('boom'));
      final now = DateTime.now().toUtc();
      _writeRaw(dir, 'expired', uri, {'n': 1},
          storedAt: now.subtract(const Duration(days: 8)));
      _writeRaw(dir, 'valid', uri, {'n': 2},
          storedAt: now.subtract(const Duration(hours: 1)));

      // Although the sink throws on the expired one, the valid one is still returned.
      expect(store.readAll().map((e) => e.id).toList(), ['valid']);
    });
  });
}

/// Writes a raw record (in the on-disk format) to control `stored_at`,
/// the retry state and the uri, and to verify ordering/TTL/backoff/authority
/// deterministically. Omitting [attemptCount]/[nextAttemptAt] yields a
/// legacy record (schema v1) to migrate.
void _writeRaw(
  Directory dir,
  String id,
  Uri uri,
  Map<String, Object?> payload, {
  required DateTime storedAt,
  int? attemptCount,
  DateTime? nextAttemptAt,
}) {
  final record = <String, Object?>{
    'uri': uri.toString(),
    'payload': payload,
    'stored_at': storedAt.toIso8601String(),
    if (attemptCount != null || nextAttemptAt != null) 'v': 2,
    if (attemptCount != null) 'attempt_count': attemptCount,
    if (nextAttemptAt != null)
      'next_attempt_at': nextAttemptAt.toIso8601String(),
  };
  final file = File('${dir.path}/$id.json');
  file.writeAsStringSync(jsonEncode(record));
  // As if written at `stored_at`: the index built without reading the files
  // relies on the modification time (CYDA-31).
  file.setLastModifiedSync(storedAt);
}
