import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'background_worker.dart';
import 'breadcrumb.dart';
import 'configuration.dart';
import 'events/error_event.dart';
import 'events/log_event.dart';
import 'events/message_event.dart';
import 'events/metric_event.dart';
import 'events/performance_issue_event.dart';
import 'jank_coalescer.dart';
import 'log_buffer.dart';
import 'log_level.dart';
import 'logger.dart';
import 'offline_store.dart';
import 'scope.dart';
import 'scrubber.dart';
import 'stats.dart';
import 'transport.dart';
import 'usage_registry.dart';
import 'uuid.dart';
import 'version.dart';

/// Client coordinator: holds configuration, scope, transport, worker and
/// logs buffer, and implements the capture/send logic.
///
/// Mirrors `CloseYourIt::Client` (+ the gem's module methods). Dependencies
/// are injectable for tests. The static [CloseYourIt] façade delegates here.
class CloseYourItClient {
  CloseYourItClient(
    this.options, {
    Transport? transport,
    BackgroundWorker? worker,
    Stats? stats,
    Scope? scope,
    LogBuffer? logBuffer,
    OfflineStore? store,
    double Function()? randomSource,
  })  : stats = stats ?? Stats(onEvent: options.onDiagnostic),
        _store = store,
        scope = scope ?? Scope(maxBreadcrumbs: options.maxBreadcrumbs),
        _random = randomSource ?? _defaultRandom {
    _transport = transport ??
        Transport(
          token: options.token,
          publicKey: options.publicKey,
          stats: this.stats,
          onDebug: options.debug
              ? (message) => debugPrint('[closeyourit] $message')
              : null,
        );
    _worker = worker ??
        BackgroundWorker(stats: this.stats, maxQueue: options.maxQueue);
    _logBuffer = logBuffer ??
        LogBuffer(
          onFlush: _flushLogs,
          batchSize: options.logsBatchSize,
          flushInterval: options.logsFlushInterval,
        );
    _jankCoalescer = JankCoalescer(
      windowMs: options.jankWindowMs,
      onFlush: _emitJankRollup,
    );
  }

  final CloseYourItOptions options;

  /// Release derived from the device contexts (installDeviceContext) when the
  /// options do not set one. Explicit options always win.
  String? releaseOverride;

  /// Effective release of events: options.release, otherwise the derived one.
  String? get effectiveRelease => options.release ?? releaseOverride;

  /// URI of error/message events depending on the credential: the Sentry drop-in
  /// `…/api/{id}/store` with the [CloseYourItOptions.publicKey] (distributed apps),
  /// otherwise `…/api/v1/projects/{id}/events` with the Bearer (server-side).
  Uri get _eventsUri =>
      options.usesPublicKey ? options.storeUri : options.eventsUri;

  /// Diagnostic counters.
  final Stats stats;

  /// Current scope (user/tags/breadcrumbs/trace_id).
  final Scope scope;

  /// Current route/screen, set by the `CloseYourItNavigatorObserver` —
  /// it attributes `jank` and `rebuild_storm` to the screen. It stays `null` while
  /// no observer is registered (or during startup, or on anonymous routes): then
  /// verdicts use the `<unknown>` sentinel instead of omitting the route, so they
  /// form a dedicated group instead of collapsing into a partial signature.
  String? currentRoute;

  final double Function() _random;
  late final Transport _transport;
  late final BackgroundWorker _worker;
  late final LogBuffer _logBuffer;
  late final JankCoalescer _jankCoalescer;
  final Expando<bool> _captured = Expando<bool>();

  /// Usage telemetry registry, created only on the first useful
  /// record: with usage telemetry off (the default) no
  /// timer is ever created.
  UsageRegistry? _usageRegistry;

  /// `true` after [close]: prevents creating periodic resources on a
  /// client that is already shut down.
  bool _closed = false;

  /// Persistent offline queue (optional). When present, error events
  /// (`captureException`/`captureMessage`) are written to disk before
  /// sending and removed only on a 2xx confirmation: if the process dies or is
  /// offline, they survive and are resent at boot (see [replayPending]).
  final OfflineStore? _store;

  /// Ids persisted by **this** session whose send was already handed to the
  /// worker (CYDA-31). [replayPending] runs after the first frame, so it can
  /// find on disk errors captured meanwhile: they are already in flight and
  /// must not be sent twice. An id leaves the set once its record is off disk.
  ///
  /// Only needed until the replay has read the queue: after [replayPending]
  /// (or [close]) it is emptied and no longer fed. Until then it keeps at most
  /// [_maxTrackedIds] ids, oldest dropped first like the store evicts its
  /// oldest records, so an offline session never grows it without bound.
  final Set<String> _persistedThisSession = <String>{};

  /// `true` once [replayPending] has read the queue: later ids need no tracking.
  bool _replayDone = false;

  /// Cap of [_persistedThisSession]: above the default store capacity (50),
  /// so every id still on disk stays tracked.
  static const int _maxTrackedIds = 256;

  /// `true` if offline persistence of errors is active.
  bool get hasOfflineStore => _store != null;

  static final Random _rng = Random();
  static double _defaultRandom() => _rng.nextDouble();

  /// Route sentinel for verdicts attributed to a screen (`jank`,
  /// `rebuild_storm`) when [currentRoute] is missing: it prevents all the
  /// "screenless" verdicts from collapsing into a single group with a partial
  /// signature and makes them a recognisable dedicated group. Parity with the JS client.
  static const String _unknownRoute = '<unknown>';

  /// Compatible logger (`debug`/`info`/`warn`/`error`/`fatal`).
  CloseYourItLogger get logger => CloseYourItLogger(this);

  // ---------------------------------------------------------------- errors

  /// Captures an exception. No-op if disabled, excluded, already captured or not
  /// sampled.
  void captureException(
    Object error, {
    StackTrace? stackTrace,
    bool handled = false,
    String level = 'error',
    Map<String, Object?>? request,
    Map<String, Object?>? contexts,
    List<String> inAppPackages = const [],
  }) {
    if (!options.isEnabled) return;
    if (options.isExcluded(error)) {
      stats.recordDrop(DropReason.excluded);
      return;
    }
    if (_alreadyCaptured(error)) {
      stats.recordDrop(DropReason.duplicate);
      return;
    }
    _markCaptured(error);
    if (!_sampled(options.sampleRate)) {
      stats.recordDrop(DropReason.sampled);
      return;
    }

    final event = ErrorEvent.fromError(
      error,
      stackTrace,
      environment: options.environment,
      release: effectiveRelease,
      handled: handled,
      level: level,
      scopeHash: scope.toEventHash(sendPii: options.sendPii),
      traceId: scope.ensureTraceId(),
      request: request,
      contexts: contexts,
      inAppPackages: inAppPackages,
    );
    // persist: errors are the crash that closes the app — they go to disk before
    // sending so they survive crashes/offline (Crashlytics pattern).
    _enqueue(event.toJson(), _eventsUri, persist: true);
  }

  /// Captures a diagnostic message.
  void captureMessage(String message, {String level = 'info'}) {
    if (!options.isEnabled) return;
    if (!_sampled(options.sampleRate)) {
      stats.recordDrop(DropReason.sampled);
      return;
    }

    final event = MessageEvent(
      message: message,
      environment: options.environment,
      release: effectiveRelease,
      level: level,
      scopeHash: scope.toEventHash(sendPii: options.sendPii),
      traceId: scope.ensureTraceId(),
    );
    _enqueue(event.toJson(), _eventsUri, persist: true);
  }

  // ---------------------------------------------------------------- metrics

  /// Measures the duration of [body]; emits a `slow_method` metric if ≥ threshold.
  /// It records even if [body] throws (the metric is in the `finally`).
  Future<T> measure<T>(String label, FutureOr<T> Function() body) async {
    if (!options.isEnabled) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000.0;
      if (ms >= options.slowMethodThresholdMs) {
        _enqueue(
          MetricEvent(
                  label: label,
                  durationMs: ms,
                  environment: options.environment,
                  traceId: scope.ensureTraceId())
              .toJson(),
          options.metricsUri,
        );
      }
    }
  }

  /// Records an external HTTP call (from the Dio interceptor): if the duration
  /// exceeds the threshold it emits a `slow_external_http` verdict. No-op if
  /// detection is OFF, below threshold, or towards the CloseYourIt endpoint (no loop).
  /// [path] is already templated (id → placeholder) by the interceptor.
  void recordExternalHttp({
    required String host,
    required String path,
    required double durationMs,
  }) {
    if (!options.isEnabled) return;
    if (!options.detectPerformanceIssues || !options.captureExternalHttp) {
      return;
    }
    if (durationMs < options.slowExternalThresholdMs) return;
    if (host.isEmpty || host == options.endpointHost) return;

    _enqueue(
      PerformanceIssueEvent(
        subtype: 'slow_external_http',
        durationMs: durationMs,
        environment: options.environment,
        traceId: scope.ensureTraceId(),
        httpHost: host,
        httpUrl: path,
      ).toJson(),
      options.metricsUri,
    );
  }

  /// Emits a `repeated_http` verdict (N identical calls in the window =
  /// the mobile N+1). The Dio interceptor handles counting/windowing.
  void recordRepeatedHttp({
    required String host,
    required String path,
    required int count,
  }) {
    if (!options.isEnabled) return;
    if (!options.detectPerformanceIssues || !options.captureExternalHttp) {
      return;
    }
    if (host.isEmpty || host == options.endpointHost) return;

    _enqueue(
      PerformanceIssueEvent(
        subtype: 'repeated_http',
        durationMs: 0,
        environment: options.environment,
        traceId: scope.ensureTraceId(),
        httpHost: host,
        httpUrl: path,
        queryCount: count,
      ).toJson(),
      options.metricsUri,
    );
  }

  /// Records an over-budget frame for `jank` coalescing. Instead of one
  /// POST per frame, the frames of the same [route] (default: the current screen)
  /// merge into an aggregated verdict, emitted when the window ends
  /// ([CloseYourItOptions.jankWindowMs]) by [_emitJankRollup] — so a janky
  /// scroll neither enqueues one event per frame nor starves concurrent errors on
  /// the shared queue. Called by the FrameTimingObserver.
  ///
  /// Without [route] or [currentRoute] (no NavigatorObserver, startup or anonymous
  /// route) the frame merges into the `<unknown>` sentinel group instead of into
  /// a verdict with the route omitted: so "screenless" jank stays a
  /// dedicated group and does not collapse into a partial signature.
  void recordJank({required double frameMs, String? route}) {
    if (!options.isEnabled) return;
    if (!options.detectPerformanceIssues || !options.detectJank) return;
    if (frameMs <= options.jankFrameBudgetMs) return;

    _jankCoalescer.record(frameMs, route ?? currentRoute ?? _unknownRoute);
  }

  /// Enqueues the aggregated `jank` verdict of a window: `duration_ms` = worst
  /// frame, `query_count` = number of coalesced over-budget frames.
  void _emitJankRollup(JankRollup rollup) {
    _enqueue(
      PerformanceIssueEvent(
        subtype: 'jank',
        durationMs: rollup.worstMs,
        environment: options.environment,
        traceId: scope.ensureTraceId(),
        route: rollup.route,
        queryCount: rollup.frames,
      ).toJson(),
      options.metricsUri,
    );
  }

  /// Emits a `rebuild_storm` verdict (widget rebuilt too many times in the
  /// window). `CloseYourItRebuildProbe` handles counting/windowing.
  void recordRebuildStorm({
    required String widget,
    required int count,
    required double windowMs,
  }) {
    if (!options.isEnabled) return;
    if (!options.detectPerformanceIssues) return;

    _enqueue(
      PerformanceIssueEvent(
        subtype: 'rebuild_storm',
        durationMs: windowMs,
        environment: options.environment,
        traceId: scope.ensureTraceId(),
        source: widget,
        route: currentRoute ?? _unknownRoute,
        queryCount: count,
      ).toJson(),
      options.metricsUri,
    );
  }

  // ------------------------------------------------------------------- logs

  /// Buffers a structured log (sent in batches).
  void log(
    LogLevel level,
    String message, {
    String? logger,
    Map<String, Object?>? attributes,
  }) {
    if (!options.isEnabled || !options.logsEnabled) return;
    if (!(level >= options.logsMinLevel)) return;
    if (!_sampled(options.logsSampleRate)) {
      stats.recordDrop(DropReason.sampled);
      return;
    }

    _logBuffer.add(
      LogEvent(
        message: message,
        level: level,
        environment: options.environment,
        logger: logger,
        release: effectiveRelease,
        traceId: scope.ensureTraceId(),
        attributes: attributes,
      ),
    );
  }

  // -------------------------------------------------------- usage telemetry

  /// Declares that a piece of code was EXECUTED: [symbol] must be a
  /// **literal** string (never interpolated with data), because it is the only
  /// honest way to answer "is this screen ever opened?". [kind] is
  /// `custom` (literal key), `route` (a screen) or `job`.
  ///
  /// On the hot path it costs a lookup and an increment; there is a single send per
  /// window ([CloseYourItOptions.usageFlushInterval]). No-op if usage telemetry
  /// is off or if the credential is the public DSN: the `usages` channel is
  /// Bearer-only (server-side). Public logs and metrics remain available.
  void recordUsage(String symbol, {String kind = 'custom'}) =>
      _usage?.record(kind, symbol);

  /// The usage registry, or `null` when usage telemetry cannot send.
  UsageRegistry? get _usage {
    if (!options.isEnabled || !options.usageEnabled) return null;
    if (options.usesPublicKey) return null; // usage channel: Bearer only.
    // Nothing is created on an already closed client: without this, a late
    // record on a client never used for usage would create a new
    // registry — and its periodic timer would stay on forever,
    // flushing towards a closed transport.
    if (_closed) return null;
    return _usageRegistry ??= UsageRegistry(
      onFlush: _flushUsage,
      maxSymbols: options.usageMaxSymbols,
      flushInterval: options.usageFlushInterval,
    );
  }

  /// Sends a closed window: ONE POST, a payload free of user data by
  /// construction (symbols are validated against the contract format).
  void _flushUsage(UsageFlush flush) {
    _enqueue(
      <String, Object?>{
        'environment': options.environment,
        if (effectiveRelease != null) 'release': effectiveRelease,
        'sdk': const <String, Object?>{
          'name': closeYourItSdkName,
          'version': closeYourItSdkVersion,
        },
        'window_started_at': flush.windowStartedAt.toIso8601String(),
        'window_ended_at': flush.windowEndedAt.toIso8601String(),
        'truncated': flush.truncated,
        'symbols': flush.symbols.map((s) => s.toJson()).toList(),
      },
      options.usagesUri,
    );
  }

  // ------------------------------------------------------------------ scope

  /// Sets the current user.
  void setUser(
          {String? id, String? email, String? ipAddress, String? username}) =>
      scope.setUser(
          id: id, email: email, ipAddress: ipAddress, username: username);

  /// Sets a tag.
  void setTag(String key, String value) => scope.setTag(key, value);

  /// Adds several tags.
  void setTags(Map<String, String> tags) => scope.setTags(tags);

  /// Sets an extra value.
  void setExtra(String key, Object? value) => scope.setExtra(key, value);

  /// Sets a named context.
  void setContext(String key, Map<String, Object?> value) =>
      scope.setContext(key, value);

  /// Sets the correlation ID.
  void setTraceId(String? id) => scope.setTraceId(id);

  /// Starts a new logical correlation unit (new trace_id). Invoked
  /// by the `CloseYourItNavigatorObserver` on every navigation so every screen
  /// has its own trace_id — parity with the JS client's "per page". A trace
  /// pinned by hand with [setTraceId] survives navigation (it does not rotate).
  String rotateTraceId() => scope.rotateTraceId();

  /// Runs [fn] on the current scope.
  void configureScope(void Function(Scope scope) fn) => fn(scope);

  /// Clears the scope.
  void clearScope() => scope.clear();

  /// Adds a breadcrumb (no-op if breadcrumbs are disabled).
  void addBreadcrumb({
    required String message,
    String? category,
    String type = 'default',
    String level = 'info',
    Map<String, Object?>? data,
  }) {
    if (!options.breadcrumbsEnabled) return;
    scope.addBreadcrumb(
      Breadcrumb(
          message: message,
          category: category,
          type: type,
          level: level,
          data: data),
    );
  }

  // ------------------------------------------------------------ lifecycle

  /// Flushes the buffered logs, the pending jank rollups and usage window, then
  /// waits for in-flight sends.
  Future<void> flush() async {
    _logBuffer.flush();
    _jankCoalescer.flush();
    _usageRegistry?.flush();
    await _worker.flush();
  }

  /// Shuts down the client: flushes the pending logs, jank rollups and usage window,
  /// waits for sends, closes the transport.
  Future<void> close() async {
    _closed = true;
    _replayDone = true;
    _persistedThisSession.clear();
    _logBuffer.dispose();
    _jankCoalescer.flush();
    _usageRegistry?.dispose();
    await _worker.flush();
    _transport.close();
  }

  // -------------------------------------------------------------- internals

  void _enqueue(Map<String, Object?> payload, Uri uri, {bool persist = false}) {
    final hook = options.beforeSend;
    Map<String, Object?> body = payload;
    if (hook != null) {
      final Map<String, Object?>? scrubbed;
      try {
        scrubbed = hook(body);
      } catch (e) {
        _recordHookError(e);
        return;
      }
      if (scrubbed == null) {
        stats.recordDrop(DropReason.beforeSend);
        return;
      }
      body = scrubbed;
    }

    final store = _store;
    if (persist && store != null) {
      // Synchronous persistence BEFORE sending: if the process dies (or is
      // offline) the event is already on disk. The store scrubs the payload → no
      // plaintext secret on disk (the scrubbed copy is sent, so it is the
      // same thing that may be resent at boot).
      final id = Uuid.v4NoDashes();
      store.add(id, uri: uri, payload: body);
      stats.increment(StatKey.persisted);
      final onDisk = Scrubber.scrubMap(body);
      final accepted = _worker.perform(() async {
        final status = await _transport.send(onDisk, uri: uri);
        _settlePersisted(store, id, status);
      });
      // If the in-flight queue is saturated the event is NOT lost: it stays on disk
      // and replayPending resends it on the next start.
      if (accepted) {
        _trackPersisted(id);
        stats.increment(StatKey.enqueued);
      }
      return;
    }

    // Non-persisted send (metrics/logs/events without an offline queue): it does not
    // go through [_settlePersisted], so we record the reason for a permanent
    // rejection here from the status, otherwise it would stay a plain failed.
    final accepted = _worker.perform(() async {
      final status = await _transport.send(body, uri: uri);
      _recordRejectionReason(status);
    });
    if (accepted) stats.increment(StatKey.enqueued);
  }

  /// Records the structured reason for the backend's **permanent** rejection of a
  /// **non-persisted** send, from [status]: 413 = payload over the server-side
  /// budget (CYRA-112 → [DropReason.tooLarge]); every other non-retryable non-2xx
  /// is a [DropReason.permanentReject]. Success, retryable outcomes and network
  /// errors (already `failed`/`network`/`timeout` in the transport) produce no reason:
  /// they are not final drops. Symmetric with the queue drop in [_settlePersisted]
  /// (both aggregate `discarded`), so a 413 is diagnosable everywhere.
  void _recordRejectionReason(int? status) {
    if (status == null || _isSuccess(status) || _isRetryable(status)) return;
    stats.recordDrop(
        status == 413 ? DropReason.tooLarge : DropReason.permanentReject);
  }

  /// Picks up the events persisted by previous boots and re-enqueues them for
  /// sending. Every event is removed from disk on a 2xx confirmation **or** on a
  /// permanent rejection (see [_settlePersisted]); if offline again or on a
  /// retryable outcome it stays, and is retried on the next boot. No-op without a store
  /// or once the client is closed.
  ///
  /// Must be called **once at startup**, after the transport init. The façade
  /// defers it until the first frame (CYDA-31): errors persisted meanwhile by
  /// this session are already in flight and are skipped (no double send).
  void replayPending() {
    if (_closed || !options.isEnabled) return;
    final store = _store;
    if (store == null) return;
    final pending = store.readAll();
    // From here on the queue has been read: what this session persists later
    // is never replayed by this client, so the ids stop being tracked.
    final inFlight = Set<String>.of(_persistedThisSession);
    _replayDone = true;
    _persistedThisSession.clear();
    for (final event in pending) {
      if (inFlight.contains(event.id)) continue;
      final accepted = _worker.perform(() async {
        final status = await _transport.send(event.payload, uri: event.uri);
        _settlePersisted(store, event.id, status);
      });
      if (accepted) stats.increment(StatKey.replayed);
    }
  }

  /// Remembers [id] as already in flight, until the replay has read the queue
  /// (see [_persistedThisSession]).
  void _trackPersisted(String id) {
    if (_replayDone) return;
    _persistedThisSession.add(id);
    if (_persistedThisSession.length > _maxTrackedIds) {
      // Insertion-ordered set: the first id is the oldest one.
      _persistedThisSession.remove(_persistedThisSession.first);
    }
  }

  /// Decides the on-disk fate of a persisted event after its send, from the
  /// response [status]:
  /// - confirmed 2xx → removed;
  /// - permanent rejection (non-2xx and non-retryable: 4xx such as 400/401/403/413,
  ///   unresolved redirects…) → dropped from disk, because retrying does not make it
  ///   valid and it would clog the queue forever; the reason is tracked
  ///   ([StatKey.discarded] + debug log), so the drop is diagnosable;
  /// - retryable (network/null, 408, 425, 429, 5xx) → the attempt is recorded and
  ///   rescheduled with backoff ([OfflineStore.recordFailure]) so it does not restart
  ///   on every start; if attempts are exhausted it is dropped like a
  ///   permanent one (tracked drop).
  void _settlePersisted(OfflineStore store, String id, int? status) {
    if (_isSuccess(status)) {
      if (store.remove(id)) _persistedThisSession.remove(id);
      return;
    }
    if (_isRetryable(status)) {
      // Transient: space out the next attempt (backoff+jitter). If the
      // attempt cap is exhausted the store drops the record and reports it: then
      // count/log the drop, as for a permanent rejection.
      if (store.recordFailure(id)) {
        _persistedThisSession.remove(id);
        // Attempts exhausted: dedicated reason (aggregates StatKey.discarded).
        stats.recordDrop(DropReason.maxAttempts);
        if (options.debug) {
          debugPrint('[closeyourit] offline event dropped: attempts '
              'exhausted, it will not be retried');
        }
      }
      return;
    }
    // Permanent rejection: drop. Count/log the drop only if the removal from
    // disk is confirmed: if [remove] fails (best-effort) the event stays and is
    // retried on the next boot, without inflating diagnostics with drops that never happened.
    if (!store.remove(id)) return;
    _persistedThisSession.remove(id);
    // 413 = payload over the server-side budget (CYRA-112): dedicated reason; every
    // other permanent rejection is a generic permanentReject. Both aggregate
    // StatKey.discarded (historical semantics unchanged).
    stats.recordDrop(
        status == 413 ? DropReason.tooLarge : DropReason.permanentReject);
    if (options.debug) {
      debugPrint('[closeyourit] offline event dropped: permanent rejection '
          '(status $status), it will not be retried');
    }
  }

  static bool _isSuccess(int? status) =>
      status != null && status >= 200 && status < 300;

  /// `true` if a send with this [status] must be retried later. Retryable:
  /// network error ([status] null), 408 Request Timeout, 425 Too Early, 429 Too
  /// Many Requests and 5xx (transient server errors). Every other non-2xx outcome is
  /// a permanent rejection: retrying will not make it valid (DoD CYDA-10).
  static bool _isRetryable(int? status) {
    if (status == null) return true;
    if (status == 408 || status == 425 || status == 429) return true;
    return status >= 500 && status < 600;
  }

  void _flushLogs(List<LogEvent> batch) {
    if (batch.isEmpty) return;
    final hook = options.beforeSend;
    List<Map<String, Object?>> payloads = batch.map((e) => e.toJson()).toList();
    if (hook != null) {
      // The hook runs log by log: a throw drops only that log, the rest of the
      // batch is still sent (CYDA-30).
      final kept = <Map<String, Object?>>[];
      for (final payload in payloads) {
        final Map<String, Object?>? scrubbed;
        try {
          scrubbed = hook(payload);
        } catch (e) {
          _recordHookError(e);
          continue;
        }
        // Every log suppressed by the hook is a diagnosable drop (beforeSend).
        if (scrubbed == null) {
          stats.recordDrop(DropReason.beforeSend);
          continue;
        }
        kept.add(scrubbed);
      }
      payloads = kept;
      if (payloads.isEmpty) return;
    }
    // The backend rejects batches over logsMaxBatch (413): split into sequential
    // sends of ≤ logsMaxBatch so no log is lost.
    for (var start = 0; start < payloads.length; start += logsMaxBatch) {
      final end = min(start + logsMaxBatch, payloads.length);
      final chunk = payloads.sublist(start, end);
      final accepted = _worker.perform(() async {
        final status = await _transport.send(chunk, uri: options.logsUri);
        _recordRejectionReason(status);
      });
      if (accepted) stats.increment(StatKey.enqueued);
    }
  }

  /// The `beforeSend` hook threw: the payload is dropped and counted, the error
  /// never reaches the app. The debug warning carries no payload content and no
  /// exception text (either may hold the very data the hook should scrub).
  void _recordHookError(Object error) {
    stats.recordDrop(DropReason.beforeSendError);
    if (options.debug) {
      debugPrint('[closeyourit] beforeSend hook threw '
          '(${error.runtimeType}): payload dropped');
    }
  }

  bool _sampled(double rate) {
    if (rate >= 1.0) return true;
    if (rate <= 0.0) return false;
    return _random() < rate;
  }

  bool _canMark(Object error) =>
      error is! String && error is! num && error is! bool;

  bool _alreadyCaptured(Object error) =>
      _canMark(error) && _captured[error] == true;

  void _markCaptured(Object error) {
    if (_canMark(error)) _captured[error] = true;
  }
}
