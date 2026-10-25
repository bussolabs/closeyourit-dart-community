import 'package:dio/dio.dart';

import '../client.dart';
import '../close_your_it.dart';
import '../scrubber.dart';
import '../uuid.dart';
import 'trace_context.dart';

/// Dio interceptor that feeds CloseYourIt from HTTP calls.
///
/// - request/response → `http` breadcrumb;
/// - 5xx error → `captureException` (handled);
/// - non-5xx error → `warning` breadcrumb.
///
/// It **never** sends sensitive headers (`Authorization`/`Cookie`…): the request
/// context is filtered by the allowlist and further by the [Scrubber].
class CloseYourItDioInterceptor extends Interceptor {
  CloseYourItDioInterceptor({
    CloseYourItClient? client,
    int Function()? nowMs,
    String Function()? spanIdGenerator,
  })  : _injected = client,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newSpanId = spanIdGenerator ?? defaultSpanIdGenerator;

  final CloseYourItClient? _injected;

  /// Clock source (ms epoch), injectable in the repeated_http window tests.
  final int Function() _nowMs;

  /// Source of the W3C parent-id (span-id), injectable for deterministic tests
  /// of trace context propagation.
  final String Function() _newSpanId;

  /// Recent timestamps per `host\npath` key — repeated_http sliding window.
  final Map<String, List<int>> _httpWindow = <String, List<int>>{};

  CloseYourItClient? get _client => _injected ?? CloseYourIt.client;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final client = _client;
    if (client != null) {
      final safeUrl =
          Scrubber.sanitizeUri(options.uri, sendPii: client.options.sendPii);
      client.addBreadcrumb(
        message: '${options.method} $safeUrl',
        category: 'http',
        type: 'http',
        data: {'method': options.method, 'url': safeUrl},
      );
      if (client.options.captureRequest) {
        // Per-request snapshot (does NOT mutate the shared global scope): it travels
        // in RequestOptions.extra with the request and feeds the event only
        // if THIS request fails. So concurrent calls do not swap
        // URL/method/headers, nor leave leftovers in the scope (CYDA-9).
        options.extra[_requestKey] = <String, Object?>{
          'method': options.method,
          'url': safeUrl,
          'headers': _allowlistedHeaders(
              options.headers, client.options.requestHeaderAllowlist),
        };
      }
      // Time the call for the slow_external_http verdict (opt-in).
      if (client.options.detectPerformanceIssues &&
          client.options.captureExternalHttp) {
        options.extra[_startedKey] = Stopwatch()..start();
      }
      // Propagate the W3C Trace Context to allowed hosts (opt-in).
      if (client.options.propagateTraceContext) {
        _injectTraceContext(options, client);
      }
    }
    handler.next(options);
  }

  /// Injects W3C `traceparent`/`tracestate` into the outgoing request, so the
  /// mobile call can be correlated with the backend logs (CYDA-16).
  ///
  /// Security constraints: it is sent ONLY to the hosts in
  /// [CloseYourItOptions.tracePropagationAllowlist] (external hosts excluded) and
  /// never carries internal information — `tracestate` and `baggage` are filtered
  /// with the [Scrubber] PII denylist. It continues an upstream trace if the
  /// request already carries a valid `traceparent` (nested request); it generates
  /// a new parent-id on every call, so concurrent requests do not
  /// share the span.
  void _injectTraceContext(RequestOptions options, CloseYourItClient client) {
    if (!TraceContext.hostAllowed(
        options.uri.host, client.options.tracePropagationAllowlist)) {
      return; // destination not allowed: no header propagated
    }

    final headers = options.headers;
    final incoming =
        TraceParent.parse(_readHeader(headers, TraceContext.traceparentHeader));
    final traceId = incoming?.traceId ?? _w3cTraceId(client);
    final flags = incoming?.flags ?? '01';

    _writeHeader(headers, TraceContext.traceparentHeader,
        '00-$traceId-${_newSpanId()}-$flags');
    _writeHeader(
        headers,
        TraceContext.tracestateHeader,
        TraceContext.buildTraceState(
            _readHeader(headers, TraceContext.tracestateHeader)));

    // We never generate baggage: at most we clean the one set by the caller.
    final baggage = TraceContext.filterBaggage(
        _readHeader(headers, TraceContext.baggageHeader));
    if (baggage == null) {
      _removeHeader(headers, TraceContext.baggageHeader);
    } else {
      _writeHeader(headers, TraceContext.baggageHeader, baggage);
    }
  }

  /// W3C trace-id from the scope correlation `trace_id`: the internal one is
  /// already 32 hex (UUID v4), hence compliant and propagated as-is to correlate
  /// mobile and backend. A hand-set non-hexadecimal `trace_id` cannot be
  /// propagated in W3C: a compliant one is generated for the header (internal
  /// correlation stays on the original id).
  String _w3cTraceId(CloseYourItClient client) {
    final scopeId = client.scope.ensureTraceId().toLowerCase();
    return TraceContext.isValidTraceId(scopeId) ? scopeId : Uuid.v4NoDashes();
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    final client = _client;
    if (client != null) {
      final safeUrl = Scrubber.sanitizeUri(response.requestOptions.uri,
          sendPii: client.options.sendPii);
      client.addBreadcrumb(
        message: 'HTTP ${response.statusCode} $safeUrl',
        category: 'http',
        type: 'http',
        data: {
          'method': response.requestOptions.method,
          'url': safeUrl,
          'status_code': response.statusCode,
        },
      );
    }
    _recordTiming(response.requestOptions);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final client = _client;
    final status = err.response?.statusCode;
    if (client != null) {
      final safeUrl = Scrubber.sanitizeUri(err.requestOptions.uri,
          sendPii: client.options.sendPii);
      if (status != null && status >= 500) {
        client.captureException(
          err,
          stackTrace: err.stackTrace,
          handled: true,
          request: _requestSnapshot(err.requestOptions),
          contexts: {
            'response': {
              'status_code': status,
              'url': safeUrl,
              'method': err.requestOptions.method,
            },
          },
        );
      } else {
        client.addBreadcrumb(
          message: 'HTTP ${status ?? 'error'} $safeUrl',
          category: 'http',
          type: 'http',
          level: 'warning',
          data: {'status_code': status, 'type': err.type.name},
        );
      }
    }
    _recordTiming(err.requestOptions);
    handler.next(err);
  }

  /// Key in `RequestOptions.extra` where the call Stopwatch is kept.
  static const String _startedKey = '__cyi_started';

  /// Key in `RequestOptions.extra` where the request context snapshot of THIS
  /// request is kept: per-request isolation instead of the global scope,
  /// so concurrent errors do not swap the context (CYDA-9).
  static const String _requestKey = '__cyi_request';

  /// Retrieves the request snapshot stashed in onRequest for this request.
  /// `null` if `captureRequest` is disabled (no snapshot created).
  Map<String, Object?>? _requestSnapshot(RequestOptions options) {
    final snapshot = options.extra[_requestKey];
    return snapshot is Map<String, Object?> ? snapshot : null;
  }

  /// Reads the Stopwatch stashed in onRequest and, if present, passes the duration
  /// to the client for a possible slow_external_http verdict (the client decides
  /// the threshold) + feeds the windowed counter for repeated_http.
  void _recordTiming(RequestOptions options) {
    final sw = options.extra.remove(_startedKey);
    if (sw is! Stopwatch) return;
    sw.stop();
    final host = options.uri.host;
    final path = _templatizePath(options.uri.path);
    _client?.recordExternalHttp(
      host: host,
      path: path,
      durationMs: sw.elapsedMicroseconds / 1000.0,
    );
    _trackRepeated(host, path);
  }

  /// Sliding window per host+path: on the N-th identical call within the window
  /// it emits a repeated_http verdict (the mobile N+1). It emits ONCE when the
  /// threshold is crossed (count == threshold); the backend dedups by fingerprint anyway.
  void _trackRepeated(String host, String path) {
    final client = _client;
    if (client == null) return;
    final options = client.options;
    if (!options.detectPerformanceIssues || !options.captureExternalHttp) {
      return;
    }

    final now = _nowMs();
    final key = '$host\n$path';
    final cutoff = now - options.repeatedHttpWindowMs;
    final hits = (_httpWindow[key] ??= <int>[])
      ..removeWhere((t) => t < cutoff)
      ..add(now);

    if (hits.length == options.repeatedHttpThreshold) {
      client.recordRepeatedHttp(host: host, path: path, count: hits.length);
    }
  }

  /// Path with uuids and runs of ≥3 digits → placeholders (same route = same
  /// backend signature). Keeps API versions such as `/v1`.
  static String _templatizePath(String path) {
    return path
        .replaceAll(
            RegExp(
                r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
                caseSensitive: false),
            '<uuid>')
        .replaceAll(RegExp(r'\d{3,}'), '<n>');
  }

  /// Reads a header by name, case-insensitively (Dio does not normalize case).
  String? _readHeader(Map<String, dynamic> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value?.toString();
    }
    return null;
  }

  /// Sets a header to [value] with the canonical lowercase name, first removing
  /// any variants with a different case (no duplicate headers).
  void _writeHeader(Map<String, dynamic> headers, String name, String value) {
    _removeHeader(headers, name);
    headers[name] = value;
  }

  /// Removes every case-insensitive variant of [name].
  void _removeHeader(Map<String, dynamic> headers, String name) {
    final lower = name.toLowerCase();
    headers.keys
        .where((k) => k.toLowerCase() == lower)
        .toList()
        .forEach(headers.remove);
  }

  /// Allowed headers, always excluding sensitive ones ([Scrubber.sensitiveKey]).
  Map<String, Object?> _allowlistedHeaders(
      Map<String, dynamic> headers, List<String> allow) {
    final allowed = allow.map((h) => h.toLowerCase()).toSet();
    final out = <String, Object?>{};
    headers.forEach((key, value) {
      final lower = key.toLowerCase();
      if (allowed.contains(lower) && !Scrubber.sensitiveKey.hasMatch(lower)) {
        out[key] = value.toString();
      }
    });
    return out;
  }
}
