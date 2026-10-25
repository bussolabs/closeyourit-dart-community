/// A persisted event awaiting (re)send.
///
/// Emitted by [OfflineStore.readAll] at boot: [payload] is already scrubbed (no
/// plaintext secret on disk), [uri] is the ingest endpoint it must be resent to.
class PendingEvent {
  const PendingEvent({
    required this.id,
    required this.uri,
    required this.payload,
  });

  /// Unique record identifier (used by [OfflineStore.remove]).
  final String id;

  /// Ingest endpoint the event must be (re)sent to.
  final Uri uri;

  /// Event payload, already passed through the PII scrubber.
  final Map<String, Object?> payload;
}

/// Persistent queue of events not yet confirmed by the backend.
///
/// Fixes the loss of the crash that closes the app: an [ErrorEvent] in an
/// in-memory queue vanishes if the process dies (or is offline) before sending.
/// By persisting it to disk (Crashlytics pattern), it survives the crash and is
/// resent on the next start.
///
/// Contract: **never throws** (telemetry must not crash the host);
/// [add] is **synchronous** so the event is on disk before the process can
/// die; the implementation **scrubs** the payload before writing it (no
/// plaintext secret on disk).
abstract interface class OfflineStore {
  /// Persists [payload] under [id], bound for [uri]. Synchronous and best-effort.
  void add(String id,
      {required Uri uri, required Map<String, Object?> payload});

  /// Removes record [id] (confirmed send or permanent rejection). Best-effort:
  /// returns `true` if after the call the record is no longer pending (removed or
  /// already missing), `false` if the removal failed and the record stays on disk.
  /// The caller uses the outcome so it does not count a drop that never happened.
  bool remove(String id);

  /// Records a **failed but retryable** send attempt for [id]:
  /// increments the attempt counter and reschedules the next send with
  /// backoff+jitter (so a backlog does not retry everything on each start). If
  /// attempts are exhausted, it drops the record from disk (no longer deliverable).
  ///
  /// Returns `true` if the record was **dropped** because attempts ran out
  /// (the caller counts it as a drop), `false` if it was rescheduled
  /// or no longer present. Best-effort: never throws.
  bool recordFailure(String id);

  /// Reads the pending records **due now**, oldest-first: excludes those
  /// waiting on backoff (future `next_attempt_at`, which stay on disk) and drops
  /// those past the TTL. Never throws (empty list on error); corrupted records
  /// are dropped.
  List<PendingEvent> readAll();
}
