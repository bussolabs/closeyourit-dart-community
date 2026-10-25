import 'dart:convert';
import 'dart:io';

import 'offline_retry_policy.dart';
import 'offline_store.dart';
import 'scrubber.dart';
import 'stats.dart';

/// Filesystem [OfflineStore]: one JSON file per event in [_directory].
///
/// One file per event (instead of a single rewritten queue file) makes
/// persistence robust: the synchronous write of one record cannot corrupt
/// the others, and a single malformed file is dropped without sinking the
/// queue. Not available on web (no filesystem): there persistence is
/// missing and the client stays fully functional in memory.
///
/// Every record carries expiry and retry state ([OfflineRetryPolicy]):
/// `stored_at` (age, for TTL and ordering), `attempt_count` and `next_attempt_at`
/// (backoff). So a backlog neither retries everything on each start nor grows/persists
/// without limit. Records written by earlier versions (without these fields)
/// are migrated on read with safe defaults (0 attempts, due right away).
class FileOfflineStore implements OfflineStore {
  FileOfflineStore(
    this._directory, {
    this.maxEvents = 50,
    OfflineRetryPolicy retryPolicy = const OfflineRetryPolicy(),
    Uri? endpoint,
    DateTime Function()? clock,
    void Function(DropReason reason)? onDrop,
  })  : _policy = retryPolicy,
        _endpoint = endpoint,
        _clock = clock ?? _defaultClock,
        _onDrop = onDrop;

  /// Schema version of the on-disk record. `1` = legacy (only
  /// `uri`/`payload`/`stored_at`, no retry state); `2` adds
  /// `attempt_count`/`next_attempt_at`. On read, records without `v` (or `v < 2`)
  /// are treated as legacy and migrated with defaults.
  static const int _schemaVersion = 2;

  final Directory _directory;

  /// Cap on persisted records: beyond it, [add] evicts the oldest (by
  /// `stored_at`). Avoids unbounded disk growth during long offline periods,
  /// preferring to keep the most recent crashes.
  final int maxEvents;

  /// Expiry, attempt cap and backoff applied on read/retry.
  final OfflineRetryPolicy _policy;

  /// Expected queue endpoint (reference authority). If set, a
  /// record whose `uri` points to a different host is **dropped** instead of
  /// being (re)sent: a tampered file on disk cannot redirect
  /// telemetry to an arbitrary host (defense in depth, exfiltration).
  /// `null` (tests/standalone store) → no constraint.
  final Uri? _endpoint;

  /// Time source (injectable for tests). Always UTC.
  final DateTime Function() _clock;

  /// Optional diagnostic sink: reports the store's **internal** drops
  /// (expired by TTL, evicted for capacity, corrupted records or bound for a
  /// disallowed host) that would otherwise be silent. The client wires
  /// `Stats.recordDrop` to it so diagnostics also cover the offline store (CYDA-13).
  /// `null` = no notification (unchanged behaviour).
  final void Function(DropReason reason)? _onDrop;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  /// Reports [reason] to the diagnostic sink (best-effort: never throws).
  void _reportDrop(DropReason reason) {
    final sink = _onDrop;
    if (sink == null) return;
    try {
      sink(reason);
    } on Object {
      // Diagnostics must never interfere with persistence.
    }
  }

  @override
  void add(String id,
      {required Uri uri, required Map<String, Object?> payload}) {
    try {
      _directory.createSync(recursive: true);
      _evictIfNeeded();
      final now = _clock();
      final record = <String, Object?>{
        'v': _schemaVersion,
        'uri': uri.toString(),
        // Scrub before writing: no plaintext secret on disk (defense in
        // depth, independent of the upstream scope/event scrubbing).
        'payload': Scrubber.scrubMap(payload),
        'stored_at': now.toIso8601String(),
        // New event: 0 attempts, sendable right away (the first send starts now;
        // backoff only spaces retries after a failure).
        'attempt_count': 0,
        'next_attempt_at': now.toIso8601String(),
      };
      // flush: true → the bytes reach the disk before returning (durability
      // even if the process dies right after).
      _fileFor(id).writeAsStringSync(jsonEncode(record), flush: true);
    } on Object {
      // Best-effort persistence: never throw (telemetry does not crash the host).
    }
  }

  @override
  bool remove(String id) {
    try {
      final file = _fileFor(id);
      if (file.existsSync()) file.deleteSync();
      return true; // removed or already missing: no longer pending
    } on Object {
      return false; // best-effort failed: the record stays on disk
    }
  }

  @override
  bool recordFailure(String id) {
    try {
      final file = _fileFor(id);
      if (!file.existsSync()) return false; // nothing to reschedule/drop
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        // unreadable record: do not retry it forever
        if (_deleteQuietly(file)) _reportDrop(DropReason.storeCorrupted);
        return false;
      }
      final attempt = _attemptOf(decoded) + 1;
      // Attempts exhausted: drop. Retrying beyond the cap does not make it
      // deliverable and would keep the queue busy forever.
      if (attempt >= _policy.maxAttempts) {
        _deleteQuietly(file);
        return true;
      }
      // Reschedule with backoff: the next attempt is not due before
      // `now + backoffFor(attempt)`, so the event does not restart on every start.
      final next = _clock().add(_policy.backoffFor(id, attempt));
      final updated = <String, Object?>{
        ...decoded.cast<String, Object?>(),
        'v': _schemaVersion,
        'attempt_count': attempt,
        'next_attempt_at': next.toIso8601String(),
      };
      file.writeAsStringSync(jsonEncode(updated), flush: true);
      return false; // rescheduled, stays pending
    } on Object {
      return false; // best-effort: on error the event stays as it is
    }
  }

  @override
  List<PendingEvent> readAll() {
    try {
      if (!_directory.existsSync()) return const [];
      final now = _clock();
      final due = <_Entry>[];
      for (final entry in _entries()) {
        // TTL: too old → drop (it will not become deliverable by retrying).
        if (now.difference(entry.storedAt) > _policy.ttl) {
          if (_deleteQuietly(entry.file)) _reportDrop(DropReason.expired);
          continue;
        }
        // Backoff in progress: not due yet → skip, it stays on disk for a
        // later start (this is what avoids the burst on every start).
        if (entry.nextAttemptAt.isAfter(now)) continue;
        due.add(entry);
      }
      due.sort((a, b) => a.storedAt.compareTo(b.storedAt));
      return due.map((e) => e.event).toList();
    } on Object {
      return const [];
    }
  }

  /// Current `*.json` files in the directory (best-effort).
  List<File> _pendingFiles() {
    if (!_directory.existsSync()) return const [];
    return _directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();
  }

  /// Parses the pending files into valid [_Entry]s; corrupted/unreadable ones and
  /// those bound for a disallowed host are dropped and deleted (not retried
  /// forever). Legacy records (without retry state) are migrated
  /// with defaults: 0 attempts, due right away (`next_attempt_at = stored_at`).
  List<_Entry> _entries() {
    final result = <_Entry>[];
    for (final file in _pendingFiles()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        final uriStr = decoded is Map ? decoded['uri'] : null;
        final payload = decoded is Map ? decoded['payload'] : null;
        final uri = uriStr is String ? Uri.tryParse(uriStr) : null;
        if (uri == null || payload is! Map) {
          if (_deleteQuietly(file)) _reportDrop(DropReason.storeCorrupted);
          continue;
        }
        // Security: a persisted uri bound for an unexpected host (tampered file)
        // must not redirect telemetry → drop.
        if (!_authorityAllowed(uri)) {
          if (_deleteQuietly(file)) _reportDrop(DropReason.storeCorrupted);
          continue;
        }
        final storedAt =
            DateTime.tryParse((decoded['stored_at'] ?? '').toString()) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        // Legacy migration: missing `next_attempt_at` → due right away.
        final nextAttemptAt =
            DateTime.tryParse((decoded['next_attempt_at'] ?? '').toString()) ??
                storedAt;
        result.add(_Entry(
          file: file,
          storedAt: storedAt,
          nextAttemptAt: nextAttemptAt,
          event: PendingEvent(
            id: _idOf(file),
            uri: uri,
            payload: payload.cast<String, Object?>(),
          ),
        ));
      } on Object {
        if (_deleteQuietly(file)) _reportDrop(DropReason.storeCorrupted);
      }
    }
    return result;
  }

  /// `true` if [uri] targets the expected endpoint (or no endpoint is enforced).
  /// Compares the authority (`www.`-normalized host, plus the port) and forbids the
  /// `https→http` downgrade: parity with the transport's redirect precautions.
  bool _authorityAllowed(Uri uri) {
    final endpoint = _endpoint;
    if (endpoint == null) return true; // no constraint
    String bareHost(String host) =>
        host.startsWith('www.') ? host.substring(4) : host;
    if (bareHost(uri.host) != bareHost(endpoint.host)) return false;
    if (uri.port != endpoint.port) return false;
    if (endpoint.scheme == 'https' && uri.scheme != 'https') return false;
    return true;
  }

  /// Record attempt counter, tolerant of types (`int`/`num`/string) and
  /// of legacy records (missing → 0).
  int _attemptOf(Map<dynamic, dynamic> decoded) {
    final raw = decoded['attempt_count'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}') ?? 0;
  }

  /// If at the cap, deletes the oldest records (by `stored_at`) to make room.
  void _evictIfNeeded() {
    final entries = _entries();
    if (entries.length < maxEvents) return;
    entries.sort((a, b) => a.storedAt.compareTo(b.storedAt));
    final toRemove = entries.length - maxEvents + 1;
    for (var i = 0; i < toRemove && i < entries.length; i++) {
      if (_deleteQuietly(entries[i].file)) _reportDrop(DropReason.evicted);
    }
  }

  File _fileFor(String id) => File('${_directory.path}/$id.json');

  String _idOf(File file) {
    final name = file.uri.pathSegments.last;
    return name.endsWith('.json')
        ? name.substring(0, name.length - '.json'.length)
        : name;
  }

  /// Deletes [file] best-effort. Returns `true` if after the call the file is no
  /// longer present (removed or already missing), `false` if the deletion failed and
  /// the file stays: the caller reports the drop **only** on `true`, so a
  /// record that survives the delete is not counted again on every read.
  bool _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
      return true;
    } on Object {
      return false;
    }
  }
}

/// Parsed record with its logical age (`stored_at`) and the schedule of the
/// next attempt (`next_attempt_at`), for TTL, ordering and backoff.
class _Entry {
  _Entry({
    required this.file,
    required this.storedAt,
    required this.nextAttemptAt,
    required this.event,
  });

  final File file;
  final DateTime storedAt;
  final DateTime nextAttemptAt;
  final PendingEvent event;
}
