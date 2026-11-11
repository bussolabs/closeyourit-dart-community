/// Diagnostic counter of telemetry operations.
enum StatKey {
  /// Events accepted for sending.
  enqueued,

  /// Events dropped because the queue was full.
  dropped,

  /// Successful sends (HTTP 2xx).
  sent,

  /// Failed sends (network error or non-2xx HTTP).
  failed,

  /// Events persisted to disk (offline queue, they survive crashes/offline).
  persisted,

  /// Events read back from disk and re-enqueued on the next boot.
  replayed,

  /// Events permanently dropped from the offline queue: a non-retryable
  /// rejection (4xx other than 408/425/429) does not become valid by retrying, so
  /// the event is removed from disk instead of clogging the queue forever (CYDA-10).
  discarded,
}

/// **Structured** reason why an event was suppressed, not delivered or
/// dropped: it makes every point where the pipeline would otherwise stay silent
/// diagnosable (a developer understands *why* an event did not arrive without
/// reading internal files). Orthogonal to [StatKey]: some reasons aggregate an
/// existing flow counter ([statKey]), others are visible only here (CYDA-13).
enum DropReason {
  /// Error/metric/log not picked by sampling (`sampleRate`).
  sampled(null),

  /// Payload dropped by the `beforeSend` hook (`return null`).
  beforeSend(null),

  /// Payload dropped because the `beforeSend` hook threw: the error is
  /// swallowed (never surfaced to the app) and the payload is not sent.
  /// Distinct from [beforeSend] so a faulty hook stays diagnosable (CYDA-30).
  beforeSendError(null),

  /// Exception type in `excludedExceptions`: not sent.
  excluded(null),

  /// Error already captured in this process: deduplicated, not re-sent.
  duplicate(null),

  /// In-flight send queue full (`maxQueue`): the immediate send is skipped
  /// (never backpressure). A persisted event stays on disk anyway.
  queueFull(StatKey.dropped),

  /// Send expired past the transport timeout (retryable outcome).
  timeout(StatKey.failed),

  /// Send failed because of a network/protocol error before the response.
  network(StatKey.failed),

  /// Send skipped because the transport has already been closed ([close]).
  clientClosed(null),

  /// Permanent rejection by the backend (non-retryable 4xx): dropped from disk.
  permanentReject(StatKey.discarded),

  /// Rejected because too large (413): the server-side payload budget
  /// (CYRA-112) is exceeded, retrying does not make it valid. Dropped from disk.
  tooLarge(StatKey.discarded),

  /// Send attempts exhausted (`maxAttempts`): dropped from disk.
  maxAttempts(StatKey.discarded),

  /// Expired on disk past the offline queue TTL: removed without retrying.
  expired(null),

  /// Evicted from the offline queue because it hit the capacity cap
  /// (`maxPersistedEvents`): the oldest one gives way to a recent event.
  evicted(null),

  /// Unreadable/corrupted record on disk, or bound for a host that is not allowed:
  /// dropped (it will never be (re)sent).
  storeCorrupted(null);

  const DropReason(this.statKey);

  /// [StatKey] flow counter that this reason increments in aggregate, or
  /// `null` if the reason is visible only among the [DropReason]s. Preserves the
  /// historical semantics of `dropped`/`failed`/`discarded`.
  final StatKey? statKey;
}

/// A structured diagnostic signal delivered to the callback: **either** an
/// increment of a flow counter ([stat]) **or** a drop with its
/// [reason]. Exactly one of the two is non-null. It carries no payload nor
/// arbitrary strings (enums only): no sensitive data flows through diagnostics.
class DiagnosticEvent {
  const DiagnosticEvent._({this.stat, this.reason});

  /// Flow signal: counter [key] was incremented.
  factory DiagnosticEvent.stat(StatKey key) => DiagnosticEvent._(stat: key);

  /// Drop/suppression signal with reason [reason].
  factory DiagnosticEvent.drop(DropReason reason) =>
      DiagnosticEvent._(reason: reason);

  /// Incremented flow counter, or `null` if the signal is a drop.
  final StatKey? stat;

  /// Drop reason, or `null` if the signal is a flow one.
  final DropReason? reason;

  /// `true` if the signal is a drop/suppression ([reason] non-null).
  bool get isDrop => reason != null;
}

/// Optional callback invoked on every diagnostic signal ([DiagnosticEvent]).
/// It is purely in-process: the SDK generates no new telemetry from it (no
/// recursive event). It must neither throw nor block (it is invoked synchronously
/// on the capture path); an exception inside it is swallowed.
typedef DiagnosticCallback = void Function(DiagnosticEvent event);

/// Thread-safe-by-isolate (single-threaded Dart) operation counters, with
/// the structured drop reasons and an optional diagnostic callback.
class Stats {
  Stats({DiagnosticCallback? onEvent}) : _onEvent = onEvent;

  final DiagnosticCallback? _onEvent;
  final Map<StatKey, int> _counts = {for (final k in StatKey.values) k: 0};
  final Map<DropReason, int> _drops = {for (final r in DropReason.values) r: 0};

  /// Reentrancy guard: if the callback itself generates telemetry (e.g. it
  /// calls `CloseYourIt.capture*` or the logger), the resulting signal must not
  /// re-invoke the callback — otherwise a potentially unbounded recursion.
  bool _notifying = false;

  /// Increments counter [key] and notifies the callback as a flow signal.
  void increment(StatKey key) {
    _counts[key] = (_counts[key] ?? 0) + 1;
    _notify(DiagnosticEvent.stat(key));
  }

  /// Records a drop/suppression with its [reason]: increments the reason
  /// counter, the associated aggregate flow counter ([DropReason.statKey])
  /// if any, and notifies the callback as a drop signal.
  void recordDrop(DropReason reason) {
    _drops[reason] = (_drops[reason] ?? 0) + 1;
    final aggregate = reason.statKey;
    if (aggregate != null) {
      _counts[aggregate] = (_counts[aggregate] ?? 0) + 1;
    }
    _notify(DiagnosticEvent.drop(reason));
  }

  /// Current value of flow counter [key].
  int operator [](StatKey key) => _counts[key] ?? 0;

  /// Current value of drop reason [reason].
  int drops(DropReason reason) => _drops[reason] ?? 0;

  /// **Immutable** snapshot of counters and reasons: a picture that does not
  /// change while telemetry carries on.
  DiagnosticsSnapshot snapshot() => DiagnosticsSnapshot._(
        Map<StatKey, int>.unmodifiable(_counts),
        Map<DropReason, int>.unmodifiable(_drops),
      );

  /// Flat snapshot of the flow counters only (backward compatible).
  Map<String, int> toMap() =>
      {for (final e in _counts.entries) e.key.name: e.value};

  /// Resets every counter and reason.
  void reset() {
    for (final k in StatKey.values) {
      _counts[k] = 0;
    }
    for (final r in DropReason.values) {
      _drops[r] = 0;
    }
  }

  void _notify(DiagnosticEvent event) {
    final callback = _onEvent;
    // Reentrancy: a notification in progress does not trigger another one (if the
    // callback generates telemetry, counters update but the callback does not recur).
    if (callback == null || _notifying) return;
    _notifying = true;
    try {
      callback(event);
    } on Object {
      // Diagnostics must never crash the host: a callback that throws
      // is swallowed (counters stay consistent anyway).
    } finally {
      _notifying = false;
    }
  }
}

/// Immutable picture of diagnostics: the flow counters ([counts]) and the
/// structured drop reasons ([reasons]). The maps are read-only.
class DiagnosticsSnapshot {
  DiagnosticsSnapshot._(this.counts, this.reasons);

  /// Empty snapshot (client not initialized).
  factory DiagnosticsSnapshot.empty() => DiagnosticsSnapshot._(
        Map<StatKey, int>.unmodifiable(const {}),
        Map<DropReason, int>.unmodifiable(const {}),
      );

  /// Flow counters by [StatKey] (read-only).
  final Map<StatKey, int> counts;

  /// Structured drop reasons by [DropReason] (read-only).
  final Map<DropReason, int> reasons;

  /// Value of flow counter [key] (0 if missing).
  int operator [](StatKey key) => counts[key] ?? 0;

  /// Value of drop reason [reason] (0 if missing).
  int reason(DropReason reason) => reasons[reason] ?? 0;

  /// Diagnostic serialization: the flat flow counts, plus a `reasons`
  /// section with only the reasons that occurred (count > 0). The section is
  /// omitted if no reason occurred. Enum names and integers only: no sensitive data.
  Map<String, Object?> toMap() {
    final map = <String, Object?>{
      for (final e in counts.entries) e.key.name: e.value,
    };
    final occurred = <String, int>{
      for (final e in reasons.entries)
        if (e.value > 0) e.key.name: e.value,
    };
    if (occurred.isNotEmpty) map['reasons'] = occurred;
    return map;
  }
}
