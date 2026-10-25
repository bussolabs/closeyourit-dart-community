/// Retry policy of the offline queue: expiry (TTL), attempt cap and
/// exponential backoff with jitter.
///
/// Fixes the backlog that, without limits, would retry **every** event on
/// each start (network burst) and keep them on disk forever:
/// - [ttl] drops events that are too old (they will never become deliverable);
/// - [maxAttempts] drops those that are repeatedly undeliverable;
/// - [backoffFor] spaces retries with progressive delays, and the deterministic
///   jitter **staggers** them across different events so they do not all
///   restart together.
///
/// Sensible defaults centralized here (easy to promote to public options
/// if a consumer ever needs to tune them).
class OfflineRetryPolicy {
  const OfflineRetryPolicy({
    this.ttl = const Duration(days: 7),
    this.maxAttempts = 5,
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(hours: 6),
  }) : assert(maxAttempts >= 1);

  /// Maximum age of an event (from `stored_at`): beyond it, it is dropped without
  /// retrying — a days-old error is no longer actionable and would only clog the queue.
  final Duration ttl;

  /// Maximum number of send attempts before the final drop. An event that
  /// fails [maxAttempts] times is no longer retried (tracked drop).
  final int maxAttempts;

  /// Base backoff delay (first retry). It doubles on every attempt.
  final Duration baseDelay;

  /// Backoff cap: the exponential delay never exceeds this value,
  /// so an event stays retryable at predictable intervals anyway.
  final Duration maxDelay;

  /// Delay before the next attempt for event [id] after its
  /// [attemptCount]-th failure (1-based: `1` = delay after the 1st failure).
  ///
  /// Exponential backoff `baseDelay * 2^(attemptCount-1)` capped at [maxDelay],
  /// plus **equal jitter**: the result falls in `[raw/2, raw]`, where the position
  /// in the range is a **deterministic** fraction of [id] and [attemptCount].
  /// Deterministic → tests are reproducible and two distinct events get
  /// different delays (staggering), so they do not restart in sync.
  Duration backoffFor(String id, int attemptCount) {
    final exponent = attemptCount < 1 ? 0 : attemptCount - 1;
    final baseMs = baseDelay.inMilliseconds;
    final capMs = maxDelay.inMilliseconds;
    // Doubling with an overflow guard: as soon as it would exceed the cap,
    // it saturates at [capMs] (no unbounded shifts on large attempts).
    var rawMs = baseMs;
    for (var i = 0; i < exponent; i++) {
      if (rawMs >= capMs || rawMs > capMs ~/ 2) {
        rawMs = capMs;
        break;
      }
      rawMs *= 2;
    }
    if (rawMs > capMs) rawMs = capMs;
    // Equal jitter: a fixed half + a half scaled by the deterministic fraction.
    final frac = _fraction(id, attemptCount);
    final jittered = rawMs / 2 + (rawMs / 2) * frac;
    return Duration(milliseconds: jittered.round());
  }

  /// Deterministic fraction in `[0, 1)` of ([id], [attemptCount]).
  ///
  /// Based on 32-bit FNV-1a (not `String.hashCode`, which is not stable across
  /// runs): same input → same fraction on every run and platform.
  double _fraction(String id, int attemptCount) {
    var hash = 0x811c9dc5;
    final seed = '$id#$attemptCount';
    for (final unit in seed.codeUnits) {
      hash = (hash ^ unit) & 0xffffffff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return (hash % 100000) / 100000.0;
  }
}
