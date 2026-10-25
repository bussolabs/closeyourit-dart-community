import 'dart:async';
import 'dart:math';

/// The only `kind`s accepted by the usage ingest. Mirrors the backend's
/// `Usage::Symbol::KINDS`: a kind outside the list is dropped by the server, so
/// we drop it here and do not waste the window.
const Set<String> usageKinds = {'route', 'job', 'custom'};

/// Allowed format for a symbol. Mirrors `Usage::Symbol::SYMBOL_FORMAT`:
/// symbols come from string literals or screen names, never from URLs —
/// no spaces, `?`, `=` or `&`, so queries, parameters and free text cannot
/// enter the symbol table even by mistake.
final RegExp usageSymbolFormat = RegExp(r'^[A-Za-z0-9_:#./-]{1,200}$');

/// Maximum number of symbols per single request to `/usages`.
///
/// Mirrors the backend's `MAX_SYMBOLS_PER_FLUSH`: a flush over this limit
/// is rejected with `R413-USAGE-001`. The registry never lets the cap be
/// exceeded: beyond it, it marks the window `truncated`.
const int usageMaxBatch = 5000;

/// A symbol seen at runtime, with how many times and when it was last seen.
class UsageSymbol {
  const UsageSymbol({
    required this.kind,
    required this.symbol,
    required this.count,
    required this.lastSeenAt,
  });

  /// `route` (a screen), `job` (a background job) or `custom` (a
  /// literal key).
  final String kind;

  /// The symbol name, already validated against [usageSymbolFormat].
  final String symbol;

  /// How many times it was seen in the window. **Indicative**: no reading
  /// compares a window with the previous one.
  final int count;

  /// Last time it was seen (UTC). It is the **load-bearing** datum: it answers
  /// "does this piece of code still run?".
  final DateTime lastSeenAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'symbol': symbol,
        'count': count,
        'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
      };
}

/// A closed observation window, ready to be sent.
class UsageFlush {
  const UsageFlush({
    required this.symbols,
    required this.truncated,
    required this.windowStartedAt,
    required this.windowEndedAt,
  });

  final List<UsageSymbol> symbols;

  /// `true` if the window saw more distinct symbols than the cap and some were
  /// left out. On the scanner side the flag **disqualifies the kind**: better no
  /// answer than a list of false "never seen".
  final bool truncated;

  final DateTime windowStartedAt;
  final DateTime windowEndedAt;
}

class _UsageEntry {
  _UsageEntry({
    required this.kind,
    required this.symbol,
    required this.lastSeenAt,
  });

  final String kind;
  final String symbol;
  int count = 1;
  DateTime lastSeenAt;
}

/// Usage telemetry registry (CYDA-22). Mirrors
/// `CloseYourIt::UsageRegistry` (gem, CYSK-29).
///
/// Records WHICH symbols actually run and closes the window every
/// [flushInterval], handing the batch to [onFlush]. On the hot path it costs
/// a lookup and an increment.
///
/// The rules that make it immune to losses:
/// - counts are INDICATIVE, only `lastSeenAt` is load-bearing: a lost window
///   costs a symbol that is seen again right after;
/// - the registry EMPTIES on every flush, so [maxSymbols] caps the *distinct*
///   symbols of a window — a quantity tied to usage, not to the
///   size of the code;
/// - beyond the cap the window is sent with `truncated: true`;
/// - no sampling, ever: sampling a screen opened three times a month
///   manufactures exactly the false "never seen" the channel exists to avoid.
class UsageRegistry {
  UsageRegistry({
    required this.onFlush,
    int maxSymbols = 2000,
    this.flushInterval = const Duration(minutes: 5),
    DateTime Function()? clock,
  })  : maxSymbols = min(maxSymbols, usageMaxBatch),
        _clock = clock ?? _utcNow {
    _windowStartedAt = _clock();
  }

  /// Callback invoked with the closed window: it takes care of sending.
  final void Function(UsageFlush flush) onFlush;

  /// Cap on *distinct* symbols per window, never beyond [usageMaxBatch] (the
  /// backend would reject the flush with 413).
  final int maxSymbols;

  /// Window closing interval (≤ 0 = no timer: the window closes
  /// only on [flush] or [dispose]).
  final Duration flushInterval;

  final DateTime Function() _clock;
  final Map<String, _UsageEntry> _symbols = <String, _UsageEntry>{};
  bool _truncated = false;
  late DateTime _windowStartedAt;
  Timer? _timer;
  bool _disposed = false;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Distinct symbols currently in the window.
  int get length => _symbols.length;

  /// Records that [symbol] of type [kind] was executed. Silently drops
  /// what the backend would reject (unknown kind, malformed symbol):
  /// a dirty entry must not cost the whole window.
  void record(String kind, String symbol) {
    if (_disposed) return;
    if (!usageKinds.contains(kind)) return;
    if (!usageSymbolFormat.hasMatch(symbol)) return;

    // `kind` and `symbol` together are the key: the same name as a screen and
    // as a custom key stays two distinct rows, as on the backend.
    final key = '$kind\u0000$symbol';
    final entry = _symbols[key];
    if (entry != null) {
      entry.count += 1;
      entry.lastSeenAt = _clock();
    } else if (_symbols.length >= maxSymbols) {
      // Beyond the cap the new symbol is lost, but the window declares it:
      // the flag is worth more than the missing symbol.
      _truncated = true;
    } else {
      _symbols[key] =
          _UsageEntry(kind: kind, symbol: symbol, lastSeenAt: _clock());
    }
    _ensureTimer();
  }

  /// Closes the window and hands it to [onFlush]. No-op if there is nothing to
  /// report (no symbols and no truncation to signal).
  void flush() {
    if (_symbols.isEmpty && !_truncated) return;
    try {
      onFlush(_drain());
    } on Object {
      // The periodic flush runs on the timer: an error must not propagate
      // into the app nor kill the timer. The load-bearing semantics is `lastSeenAt`,
      // a lost window falsifies nothing.
    }
  }

  UsageFlush _drain() {
    final flush = UsageFlush(
      symbols: _symbols.values
          .map((e) => UsageSymbol(
                kind: e.kind,
                symbol: e.symbol,
                count: e.count,
                lastSeenAt: e.lastSeenAt,
              ))
          .toList(growable: false),
      truncated: _truncated,
      windowStartedAt: _windowStartedAt,
      windowEndedAt: _clock(),
    );
    _symbols.clear();
    _truncated = false;
    _windowStartedAt = flush.windowEndedAt;
    return flush;
  }

  void _ensureTimer() {
    if (_timer != null || flushInterval <= Duration.zero) return;
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// Stops the timer and closes the window one last time. Afterwards, [record] is
  /// a no-op.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    flush();
  }
}
