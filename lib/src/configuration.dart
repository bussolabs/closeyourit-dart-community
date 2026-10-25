import 'log_level.dart';
import 'stats.dart';

/// Hook applied to every payload before sending. Returns the payload
/// (possibly modified) or `null` to drop the event.
typedef BeforeSend = Map<String, dynamic>? Function(
    Map<String, dynamic> payload);

/// CloseYourIt client configuration.
///
/// Mirrors `CloseYourIt::Configuration` (gem `closeyourit-ruby`) adapted to
/// Flutter. Required: [endpointUrl], [projectId] and **one credential**: the
/// [publicKey] (public DSN, for distributed apps) or the secret Bearer [token]
/// (server-side). If either is missing — or the endpoint — the client
/// stays **disabled** (no-op) instead of throwing: telemetry must
/// never prevent the app from starting.
class CloseYourItOptions {
  CloseYourItOptions({
    required this.endpointUrl,
    this.token = '',
    this.publicKey = '',
    required this.projectId,
    this.environment = 'development',
    this.release,
    this.sampleRate = 1.0,
    this.sendPii = false,
    this.breadcrumbsEnabled = true,
    this.maxBreadcrumbs = 100,
    this.captureLifecycleBreadcrumbs = false,
    this.captureConnectivityBreadcrumbs = false,
    this.captureTapBreadcrumbs = false,
    this.breadcrumbThrottleMs = 500,
    this.captureRequest = true,
    this.collectDeviceContext = true,
    this.requestHeaderAllowlist = const [
      'Accept',
      'Content-Type',
      'User-Agent',
      'Referer'
    ],
    this.propagateTraceContext = false,
    this.tracePropagationAllowlist = const [],
    this.slowMethodThresholdMs = 200,
    this.captureMethodArguments = false,
    this.detectPerformanceIssues = false,
    this.captureExternalHttp = true,
    this.slowExternalThresholdMs = 1000,
    this.repeatedHttpThreshold = 5,
    this.repeatedHttpWindowMs = 5000,
    this.detectJank = true,
    this.jankFrameBudgetMs = 32,
    this.jankWindowMs = 1000,
    this.rebuildStormThreshold = 20,
    this.rebuildStormWindowMs = 1000,
    this.logsEnabled = true,
    this.logsSampleRate = 1.0,
    this.logsBatchSize = 50,
    this.logsFlushInterval = const Duration(seconds: 5),
    this.logsMinLevel = LogLevel.info,
    this.usageEnabled = false,
    this.usageFlushInterval = const Duration(minutes: 5),
    this.usageMaxSymbols = 2000,
    this.excludedExceptions = const [],
    this.maxQueue = 30,
    this.persistOffline = true,
    this.maxPersistedEvents = 50,
    this.beforeSend,
    this.onDiagnostic,
    this.enabled = true,
    this.debug = false,
  });

  /// Backend base URL (e.g. `https://app.closeyour.it`). No path.
  final String endpointUrl;

  /// Per-project secret Bearer (`cyi_…`), sent as `Authorization: Bearer`.
  /// **SERVER-ONLY**: it carries full power (ingest + reading telemetry),
  /// so it must never be shipped in a distributed app — a mobile package can be
  /// inspected and the extracted secret would read/administer the project.
  /// From client apps use the [publicKey]. Optional: if missing, the
  /// [publicKey] is required. Ignored when the [publicKey] is set.
  final String token;

  /// DSN public key (hexadecimal, **not secret**): the credential of distributed
  /// apps. Routes error events to the Sentry drop-in
  /// `POST /api/{projectId}/store` with `?sentry_key=…`, with no Bearer in the
  /// package. Logs and metrics use the native project endpoints with the same
  /// query key. Usages remain server-only. The key is ingest-only, so it neither reads data nor
  /// administers the project (CYDA-7). When set it takes precedence over [token].
  final String publicKey;

  /// Project UUID on CloseYourIt.
  final String projectId;

  /// Environment name (`development`/`staging`/`production`).
  final String environment;

  /// Application version/release (auto-detection is up to the consumer).
  final String? release;

  /// Probability of sending errors/metrics (1.0 = all, 0.0 = none).
  final double sampleRate;

  /// PII master switch: with `false` (default) no email/IP/username/query.
  final bool sendPii;

  /// Captures the breadcrumb history to attach to events.
  final bool breadcrumbsEnabled;

  /// Maximum size of the breadcrumb ring buffer.
  final int maxBreadcrumbs;

  /// Opt-in: records a synthetic breadcrumb on every app lifecycle state
  /// change (`resumed`/`inactive`/`paused`/`hidden`/`detached`). The
  /// background log flush stays on regardless: this flag governs
  /// **only** the breadcrumb. Default OFF — it is an extra diagnostic trace, not
  /// the base behaviour. It still respects [breadcrumbsEnabled].
  final bool captureLifecycleBreadcrumbs;

  /// Opt-in: records a synthetic breadcrumb on every network connectivity
  /// change (`wifi`/`cellular`/`ethernet`/`none`…), via `connectivity_plus`. Only
  /// the network **type**, never SSID, IP or other data. Toggles too close together
  /// are suppressed ([breadcrumbThrottleMs]). Default OFF. Respects
  /// [breadcrumbsEnabled].
  final bool captureConnectivityBreadcrumbs;

  /// Opt-in: records a synthetic interaction (tap) breadcrumb when the app
  /// is wrapped by `CloseYourItUserInteraction`. It captures **only** the type and
  /// current route — never the typed text nor the tapped widget's data (privacy).
  /// Taps close together are suppressed ([breadcrumbThrottleMs]). Default OFF.
  /// Respects [breadcrumbsEnabled].
  final bool captureTapBreadcrumbs;

  /// Minimum interval (ms) between two automatic breadcrumbs from the same
  /// high-frequency source (connectivity, taps): suppresses rapid network toggles
  /// and rapid-fire taps so they do not saturate the ring buffer. It does not apply
  /// to the lifecycle (few transitions, all meaningful). `0` disables the throttle.
  final int breadcrumbThrottleMs;

  /// Captures method/url/headers of HTTP requests (Dio interceptor).
  final bool captureRequest;

  /// Whether to collect the device/OS/app contexts at init (device_info_plus +
  /// package_info_plus) and derive the `version+build` release when missing.
  final bool collectDeviceContext;

  /// HTTP headers allowed in the request context (never `Authorization`/`Cookie`).
  final List<String> requestHeaderAllowlist;

  /// Opt-in: propagates the W3C Trace Context (`traceparent`/`tracestate`) to
  /// outgoing HTTP requests (Dio interceptor), correlating the mobile call with
  /// the backend logs. Default OFF. Effective only towards the hosts in
  /// [tracePropagationAllowlist]: the headers never go to unlisted destinations,
  /// nor carry `baggage`/`tracestate` with sensitive keys.
  final bool propagateTraceContext;

  /// Hosts the trace context may be propagated to. Exact or
  /// subdomain match (`x.it` covers `api.x.it`). Empty (default) → no
  /// propagation even with [propagateTraceContext] on: fail-safe against
  /// leaking the internal context to third parties.
  final List<String> tracePropagationAllowlist;

  /// Threshold (ms) above which a `measure` produces a `slow_method` metric.
  final int slowMethodThresholdMs;

  /// Opt-in: include the arguments of the measured block (scrubbed).
  final bool captureMethodArguments;

  /// Performance issue detection (aggregated verdicts). OPT-IN, default OFF: on
  /// mobile the only backend-compatible counterpart is `slow_external_http` (slow
  /// external HTTP call, via the Dio interceptor). Mirrors the Ruby client.
  final bool detectPerformanceIssues;

  /// Instruments external HTTP calls (Dio interceptor) for
  /// `slow_external_http` verdicts. Effective only with [detectPerformanceIssues].
  final bool captureExternalHttp;

  /// Threshold (ms) above which a single external HTTP call becomes a
  /// `slow_external_http` verdict.
  final int slowExternalThresholdMs;

  /// N identical calls (host + path) within the window beyond which a
  /// `repeated_http` verdict fires (the mobile N+1).
  final int repeatedHttpThreshold;

  /// Width (ms) of the sliding window for [repeatedHttpThreshold].
  final int repeatedHttpWindowMs;

  /// Detects slow frames (`jank`). Effective only with [detectPerformanceIssues].
  final bool detectJank;

  /// Duration (ms) beyond which a frame counts as jank (default 32 ≈ <30fps).
  final int jankFrameBudgetMs;

  /// Width (ms) of the jank coalescing window. Over-budget frames of the same
  /// route within the window merge into ONE aggregated verdict
  /// (frame count + worst), emitted when the window ends: at most one `jank` per
  /// route every [jankWindowMs], so a janky scroll neither enqueues a POST per
  /// frame nor saturates the shared queue.
  final int jankWindowMs;

  /// N rebuilds of the same widget (via `CloseYourItRebuildProbe`) within the window
  /// beyond which a `rebuild_storm` verdict fires.
  final int rebuildStormThreshold;

  /// Width (ms) of the sliding window for [rebuildStormThreshold].
  final int rebuildStormWindowMs;

  /// Enables the logs domain (`CloseYourIt.log`/`logger`).
  final bool logsEnabled;

  /// Probability of sending a log (1.0 = all).
  final double logsSampleRate;

  /// Number of logs accumulated before an immediate flush.
  final int logsBatchSize;

  /// Periodic flush interval of the logs buffer.
  final Duration logsFlushInterval;

  /// Minimum forwarded log level (below it: dropped).
  final LogLevel logsMinLevel;

  /// Enables usage telemetry (`CloseYourIt.used`/`usedRoute`): which parts
  /// of the app actually run. **Opt-in, default OFF** — unlike the gem, the
  /// `usages` channel is Bearer-only (no public endpoint), so in a
  /// distributed app with the [publicKey] it stays silent anyway: turning it on by
  /// default would open a periodic window with nowhere to go.
  final bool usageEnabled;

  /// Closing interval of the usage window: a single POST per window, per
  /// process. `Duration.zero` disables the periodic flush (the one on
  /// `flush`/`close` remains).
  final Duration usageFlushInterval;

  /// Cap on **distinct** symbols per window. The registry empties on every
  /// flush, so it measures a window's usage, not the size of the code.
  /// Beyond the cap the window travels with `truncated: true`.
  final int usageMaxSymbols;

  /// Exception type names not to send (matched on `runtimeType`).
  final List<String> excludedExceptions;

  /// Maximum number of in-flight sends before dropping (never backpressure).
  final int maxQueue;

  /// Persists error events (`captureException`/`captureMessage`) to disk
  /// before sending, so a crash that closes the app or an offline period does not
  /// lose them: they are resent on the next start (Crashlytics pattern). On web
  /// (no filesystem) it has no effect. The on-disk payload is always scrubbed.
  final bool persistOffline;

  /// Cap on events persisted to disk: beyond it, the oldest are evicted
  /// (preferring to keep recent crashes). Avoids unbounded growth during
  /// long offline periods.
  final int maxPersistedEvents;

  /// Scrub/drop hook applied to every payload.
  final BeforeSend? beforeSend;

  /// Optional diagnostic callback: receives a [DiagnosticEvent] on every signal
  /// (send, persistence, replay, or a drop with its structured reason). It is
  /// purely in-process — the SDK generates no new telemetry from it — and must not
  /// throw or block (an exception inside it is swallowed). For a point-in-time
  /// reading use the immutable `CloseYourIt.diagnostics` snapshot instead.
  final DiagnosticCallback? onDiagnostic;

  /// Master switch: with `false` the client is entirely a no-op.
  final bool enabled;

  /// If `true`, transport send failures are logged via `debugPrint`
  /// (status + `R…` code from the backend envelope). Without it, failures stay silent.
  final bool debug;

  /// `true` if the client can send. Equivalent to `disabledReason == null`.
  bool get isEnabled => disabledReason == null;

  /// `true` if the [publicKey] is configured: the client authenticates via the
  /// public DSN (`?sentry_key=…`) and never sends the Bearer. Takes precedence over [token].
  bool get usesPublicKey => publicKey.trim().isNotEmpty;

  /// Reason why the client is disabled, or `null` if active.
  ///
  /// Disabled if: [enabled] is `false`; [endpointUrl] or [projectId] is empty;
  /// **every** credential is missing ([publicKey] and [token] both empty);
  /// `http://` with a Bearer [token] towards a non-loopback host (the secret
  /// would travel in clear, whatever the [environment]); or `http://` in
  /// `production` (insecure).
  ///
  /// The returned texts stay in Italian: consumer apps assert on them.
  String? get disabledReason {
    if (!enabled) return 'disabilitato da configurazione (enabled: false)';
    if (endpointUrl.trim().isEmpty) return 'endpointUrl mancante';
    if (publicKey.trim().isEmpty && token.trim().isEmpty) {
      return 'credenziale mancante (publicKey o token)';
    }
    if (projectId.trim().isEmpty) return 'projectId mancante';
    final insecure = endpointUrl.trim().startsWith('http://');
    if (insecure && !usesPublicKey && !_isLoopbackEndpoint) {
      return 'endpoint http:// non ammesso con un token (solo localhost)';
    }
    if (insecure && environment == 'production') {
      return 'endpoint http:// non ammesso in produzione';
    }
    return null;
  }

  /// `true` if the endpoint host is `localhost`, `127.0.0.1` or `::1`: the only
  /// hosts where a clear-text Bearer never leaves the machine.
  bool get _isLoopbackEndpoint {
    final host = Uri.tryParse(endpointUrl.trim())?.host ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  /// `endpointUrl` without a trailing slash.
  String get _base => endpointUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// Error/message ingest URI (Bearer): `…/api/v1/projects/{id}/events`.
  Uri get eventsUri => Uri.parse('$_base/api/v1/projects/$projectId/events');

  /// Error/message ingest URI with the [publicKey]: Sentry drop-in
  /// `…/api/{id}/store` (outside `/api/v1`, authenticated via `?sentry_key=…`).
  /// Logs and metrics use their native project endpoints with the same public key.
  Uri get storeUri => Uri.parse('$_base/api/$projectId/store');

  /// Metrics ingest URI: `…/api/v1/projects/{id}/metrics`.
  Uri get metricsUri => Uri.parse('$_base/api/v1/projects/$projectId/metrics');

  /// Logs ingest URI: `…/api/v1/projects/{id}/logs`.
  Uri get logsUri => Uri.parse('$_base/api/v1/projects/$projectId/logs');

  /// Usage telemetry ingest URI: `…/api/v1/projects/{id}/usages`.
  /// Bearer only: a usage channel writable by a distributed app would be an
  /// invitation to pollute the project's symbol table.
  Uri get usagesUri => Uri.parse('$_base/api/v1/projects/$projectId/usages');

  /// CloseYourIt endpoint host (to exclude telemetry from detection).
  String? get endpointHost => Uri.tryParse(_base)?.host;

  /// `true` if the exception type name is in [excludedExceptions].
  bool isExcluded(Object error) =>
      excludedExceptions.contains(error.runtimeType.toString());
}
