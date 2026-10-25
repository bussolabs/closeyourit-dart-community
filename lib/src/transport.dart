import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'stats.dart';
import 'version.dart';

/// HTTP sending of events. Mirrors `CloseYourIt::Transport`.
///
/// Two mutually exclusive authentication modes:
/// - **Public DSN** (when [publicKey] is set, for distributed apps):
///   the (non-secret) key travels as the `?sentry_key=…` query, never a header;
///   so it stays CORS-safe and an inspected package does not expose a Bearer.
/// - **Bearer** (server-side): `Authorization: Bearer <token>`, sent only
///   to the same origin authority — same host (or www variant), same
///   port, no https→http downgrade — never hand the secret to an
///   untrusted service after a redirect.
///
/// Unchanged guarantees: **never throws** (telemetry must not crash
/// the host), follows up to [maxRedirects] redirects preserving the POST
/// (apex www→non-www), updates [Stats]. [timeout] is the **total budget**
/// of the send: past that time [send] returns anyway.
class Transport {
  Transport({
    required this.stats,
    this.token = '',
    this.publicKey = '',
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
    this.maxRedirects = 2,
    this.onDebug,
  }) : _client = client ?? http.Client();

  final String token;

  /// DSN public key (hexadecimal, not secret). If not empty (whitespace
  /// aside), sending authenticates via `?sentry_key=…` and the Bearer is never
  /// sent.
  final String publicKey;

  /// The normalized (trimmed) [publicKey]. Single source for the mode criterion
  /// and the `sentry_key` value, so a whitespace-only key does not enable the
  /// DSN (it would be inconsistent with `CloseYourItOptions.usesPublicKey`) and
  /// surrounding whitespace does not end up in the query, invalidating the credential.
  String get _dsnKey => publicKey.trim();

  final Stats stats;

  /// **Single** time budget of a send: it covers headers, body and all the
  /// redirects together, not each hop. Once expired, [send] stops
  /// waiting and cancels the running stream — so the time declared here is
  /// what is actually waited, and a server that never ends the response does
  /// not keep the send (nor the worker slot running it) hanging forever.
  final Duration timeout;

  final int maxRedirects;
  final http.Client _client;

  /// `true` after [close]: later sends are skipped (transport
  /// closed) and recorded as [DropReason.clientClosed] without touching the network.
  bool _closed = false;

  /// Optional diagnostic callback on send failures: without it, failures
  /// only update [Stats] and stay silent (no diagnosis without a proxy).
  final void Function(String message)? onDebug;

  /// Sends [payload] (Map or List) to [uri]. Returns the HTTP status or `null` if
  /// the send failed before receiving a response. Never throws.
  Future<int?> send(Object payload, {required Uri uri}) async {
    // Transport already closed (close): do not try the network, record the reason.
    if (_closed) {
      stats.recordDrop(DropReason.clientClosed);
      onDebug?.call('send skipped: transport closed');
      return null;
    }
    final body = jsonEncode(payload);
    final usesDsn = _dsnKey.isNotEmpty;
    final origin = uri;
    var current = uri;
    final elapsed = Stopwatch()..start();

    try {
      for (var redirects = 0;; redirects++) {
        // Budget already spent on headers, body or previous redirects: do not
        // open another hop, otherwise the real wait would be a multiple
        // of [timeout].
        final budget = _remaining(elapsed);
        if (budget == Duration.zero) {
          throw TimeoutException('send budget exhausted', timeout);
        }

        // Public DSN: the key travels as a query, re-applied on every hop
        // (a redirect with an absolute path loses the query). It is not a secret,
        // it can follow the redirect without the Bearer precautions.
        if (usesDsn) current = _withSentryKey(current);

        final headers = <String, String>{
          'Content-Type': 'application/json',
          'User-Agent': '$closeYourItSdkName/$closeYourItSdkVersion',
        };
        // Bearer only in server mode (no publicKey) and never re-sent
        // after a redirect to a different host (or an https→http downgrade):
        // the secret must never be handed to an untrusted host.
        if (!usesDsn && _sameAuthority(origin, current)) {
          headers['Authorization'] = 'Bearer $token';
        }

        final request = http.Request('POST', current)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..body = body;

        final streamed = await _client.send(request).timeout(budget);
        final status = streamed.statusCode;

        final isRedirect = status >= 300 && status < 400;
        final location = streamed.headers['location'];
        if (isRedirect && location != null && redirects < maxRedirects) {
          await _consumeBody(streamed, _remaining(elapsed),
              timeoutIsFailure: true);
          current = current.resolve(location);
          continue;
        }

        // The status is already the outcome: record it BEFORE reading the body, so
        // a truncated body does not count it a second time (neither as an
        // extra failure nor as a lost success).
        if (status >= 200 && status < 300) {
          stats.increment(StatKey.sent);
          await _consumeBody(streamed, _remaining(elapsed));
        } else {
          stats.increment(StatKey.failed);
          if (onDebug != null) {
            // Includes the R- code + message from the backend envelope (diagnostic DX).
            final detail = await _consumeBody(streamed, _remaining(elapsed),
                collect: true);
            onDebug!('send failed with status $status${_errorDetail(detail)}');
          } else {
            await _consumeBody(streamed, _remaining(elapsed));
          }
        }
        return status;
      }
    } on TimeoutException {
      // Send timeout exceeded: retryable failure, dedicated reason
      // (aggregates StatKey.failed).
      stats.recordDrop(DropReason.timeout);
      onDebug?.call('send failed: timeout');
      return null;
    } on Object catch (error) {
      // Network/protocol error before the response (aggregates StatKey.failed).
      stats.recordDrop(DropReason.network);
      onDebug?.call('send failed: ${error.runtimeType}');
      return null;
    }
  }

  /// Adds `sentry_key=<publicKey>` to the query params of [u], keeping the
  /// existing ones. Idempotent: if the key is already present and matches, returns [u]
  /// unchanged (no duplicates across redirects).
  Uri _withSentryKey(Uri u) {
    if (u.queryParameters['sentry_key'] == _dsnKey) return u;
    return u.replace(queryParameters: <String, String>{
      ...u.queryParameters,
      'sentry_key': _dsnKey,
    });
  }

  /// The Bearer is re-sent only if the redirect stays on the **same
  /// authority** as the origin: same host (or its www variant), no
  /// https→http downgrade and **same effective port**. The host name alone
  /// is not enough: a different service answers on a different port, and it
  /// would end up holding a token that was not meant for it (CYDA-25).
  ///
  /// The port is always the effective one, so `https://h` and `https://h:443`
  /// are the same authority. The only exception to the comparison: the upgrade
  /// `http://h` → `https://h` with both default ports, which stays the
  /// same canonical service on a safer channel.
  ///
  /// The comparison is always against the origin, never against the previous hop:
  /// a redirect chain cannot move the trusted boundary one step at a time.
  bool _sameAuthority(Uri origin, Uri target) {
    if (origin.scheme == 'https' && target.scheme != 'https') return false;
    String strip(String host) =>
        host.startsWith('www.') ? host.substring(4) : host;
    if (strip(origin.host) != strip(target.host)) return false;
    if (origin.port == target.port) return true;
    bool onDefaultPort(Uri u) =>
        (u.scheme == 'http' && u.port == 80) ||
        (u.scheme == 'https' && u.port == 443);
    return origin.scheme == 'http' &&
        target.scheme == 'https' &&
        onDefaultPort(origin) &&
        onDefaultPort(target);
  }

  /// What is left of the send budget, never negative: [Duration.zero] means
  /// expired.
  Duration _remaining(Stopwatch elapsed) {
    final left = timeout - elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Consumes the body of [streamed] within [budget], returning its text only
  /// if [collect]. It does not touch [Stats]. Terminal statuses remain final;
  /// redirects use [timeoutIsFailure] to stop the send when draining times out. When the
  /// budget expires it **cancels the subscription**: without that, a response with
  /// headers but a never-ending body would leave the send hanging, taking up a
  /// slot among the in-flight sends forever.
  Future<String> _consumeBody(
    http.StreamedResponse streamed,
    Duration budget, {
    bool collect = false,
    bool timeoutIsFailure = false,
  }) async {
    final chunks = collect ? <int>[] : null;
    final subscription = streamed.stream.listen(
      chunks?.addAll,
      cancelOnError: true,
    );
    try {
      await subscription.asFuture<void>().timeout(budget);
    } on TimeoutException {
      // A redirect is not a final outcome. Once its body times out, do not
      // reopen the deadline based on a separate Stopwatch measurement.
      if (timeoutIsFailure) rethrow;
      return '';
    } on Object {
      // Budget expired or stream interrupted: unusable body, no detail.
      return '';
    } finally {
      subscription.cancel().ignore();
    }
    return chunks == null ? '' : utf8.decode(chunks, allowMalformed: true);
  }

  /// Extracts " (R…: message)" from the backend error envelope, if present
  /// in [body]. An empty, truncated or non-JSON body produces no detail.
  String _errorDetail(String body) {
    if (body.isEmpty) return '';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final error = decoded['error'] as Map;
        final parts = <Object?>[error['code'], error['message']]
            .where((part) => part != null)
            .join(': ');
        return parts.isEmpty ? '' : ' ($parts)';
      }
    } on Object {
      // non-JSON or non-envelope body: no detail.
    }
    return '';
  }

  /// Closes the underlying HTTP client. From then on every [send] is skipped and
  /// recorded as [DropReason.clientClosed] (nothing is sent to the network).
  void close() {
    _closed = true;
    _client.close();
  }
}
