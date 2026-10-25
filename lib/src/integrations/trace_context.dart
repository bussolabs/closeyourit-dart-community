import 'dart:math';

import '../scrubber.dart';

/// W3C Trace Context (`traceparent`/`tracestate`) — parser, validator and
/// generator (CYDA-16).
///
/// The Flutter client propagates its own correlation `trace_id` to downstream
/// services so a mobile call and the backend logs can be correlated
/// end-to-end, using the W3C standard (<https://www.w3.org/TR/trace-context/>).
/// Two invariants drive the module:
///
///  - **compliance**: we only emit W3C-valid headers (the backend rejects
///    malformed ones) and we reject malformed incoming ones instead of
///    propagating them;
///  - **no internal information**: `tracestate` and `baggage` are filtered
///    with the same [Scrubber] PII denylist before leaving.
///
/// The host allowlist and the opt-in live in the Dio interceptor: here there is
/// only the W3C mechanics, pure and testable in isolation.

/// A parsed and validated `traceparent`: `version-trace_id-parent_id-flags`.
///
/// `parse` applies the W3C rules (lengths, lowercase hex, ids not
/// all-zero, `version` other than `ff`) and returns `null` on any
/// deviation — a malformed header must be neither reused nor propagated.
class TraceParent {
  const TraceParent({
    this.version = '00',
    required this.traceId,
    required this.parentId,
    this.flags = '01',
  });

  /// Format version (2 hex). We always emit `00`, the only standard one.
  final String version;

  /// 16-byte trace-id (32 lowercase hex), shared by every span of the trace.
  final String traceId;

  /// 8-byte parent-id (span-id) (16 lowercase hex): identifies THIS span.
  final String parentId;

  /// Trace-flags (2 hex). Bit 0 = `sampled`; we propagate `01` by default.
  final String flags;

  /// Parses a `traceparent` header; `null` if missing or malformed.
  ///
  /// Strict on the `version-00` format: exactly four fields, trace-id and
  /// parent-id lowercase hexadecimal and not all-zero, `version` != `ff`
  /// (reserved). Uppercase is rejected: the spec mandates lowercase.
  static TraceParent? parse(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;

    final parts = value.split('-');
    if (parts.length != 4) return null;

    final version = parts[0];
    final traceId = parts[1];
    final parentId = parts[2];
    final flags = parts[3];

    if (!_isHex(version, 2) || version == 'ff') return null;
    if (!TraceContext.isValidTraceId(traceId)) return null;
    if (!TraceContext.isValidParentId(parentId)) return null;
    if (!_isHex(flags, 2)) return null;

    return TraceParent(
      version: version,
      traceId: traceId,
      parentId: parentId,
      flags: flags,
    );
  }

  /// Serializes into the `version-trace_id-parent_id-flags` header.
  String toHeader() => '$version-$traceId-$parentId-$flags';
}

/// Pure W3C Trace Context constants and helpers shared by the interceptor.
abstract final class TraceContext {
  /// Standard W3C headers (always lowercase on the way out).
  static const String traceparentHeader = 'traceparent';
  static const String tracestateHeader = 'tracestate';
  static const String baggageHeader = 'baggage';

  /// CloseYourIt vendor key in `tracestate`. The value `1` is an opaque
  /// "trace sampled/originated by CloseYourIt" marker: additive and ignored by
  /// systems that do not know it, it introduces no contract with the backend
  /// (the authoritative trace-id travels in `traceparent`).
  static const String vendorKey = 'cyi';
  static const String _vendorMember = '$vendorKey=1';

  /// W3C cap on members in `tracestate`.
  static const int _maxTraceStateMembers = 32;

  static final RegExp _traceIdRe = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _parentIdRe = RegExp(r'^[0-9a-f]{16}$');

  /// `true` if [host] is covered by [allowlist]: exact match (case-insensitive)
  /// or a subdomain of an entry (`api.x.it` is covered by `x.it` thanks to the
  /// `.` boundary, but `evilx.it` is not). Empty allowlist → no host allowed
  /// (fail-safe: propagation stays silent until hosts are listed).
  static bool hostAllowed(String host, List<String> allowlist) {
    if (host.isEmpty) return false;
    final h = host.toLowerCase();
    for (final entry in allowlist) {
      final e = entry.trim().toLowerCase();
      if (e.isEmpty) continue;
      if (h == e || h.endsWith('.$e')) return true;
    }
    return false;
  }

  /// `true` if [value] is a valid W3C trace-id: 32 lowercase hex, not all-zero.
  static bool isValidTraceId(String value) =>
      _traceIdRe.hasMatch(value) && !_isAllZero(value);

  /// `true` if [value] is a valid parent-id (span-id): 16 lowercase hex, non-zero.
  static bool isValidParentId(String value) =>
      _parentIdRe.hasMatch(value) && !_isAllZero(value);

  /// Builds the `tracestate` header to propagate: the [vendorKey] vendor entry
  /// first (leftmost = most recent, per W3C) followed by the still-valid
  /// members of [incoming].
  ///
  /// Removes members with a sensitive key ([Scrubber.sensitiveKey]) — so an
  /// internal `baggage` does not leak — and any upstream `cyi` (no
  /// duplicates), then truncates the total to [_maxTraceStateMembers].
  static String buildTraceState(String? incoming) {
    final members = <String>[_vendorMember];
    for (final member in _splitMembers(incoming)) {
      if (members.length >= _maxTraceStateMembers) break;
      final key = _memberKey(member);
      if (key == null) continue;
      if (key == vendorKey) continue; // already represented by our entry
      if (Scrubber.sensitiveKey.hasMatch(key)) continue;
      members.add(member);
    }
    return members.join(',');
  }

  /// Filters the outgoing `baggage` header by removing members with a sensitive
  /// key; returns `null` if nothing is left (the header must then be omitted).
  /// We never generate baggage: at most we clean the one set by the caller.
  static String? filterBaggage(String? incoming) {
    final kept = <String>[];
    for (final member in _splitMembers(incoming)) {
      final key = _memberKey(member);
      if (key == null) continue;
      if (Scrubber.sensitiveKey.hasMatch(key)) continue;
      kept.add(member);
    }
    return kept.isEmpty ? null : kept.join(',');
  }

  static Iterable<String> _splitMembers(String? raw) {
    if (raw == null) return const <String>[];
    return raw.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty);
  }

  /// Key (lowercase) of a `key=value` member; `null` if it has no `=`.
  /// The sensitivity match is on the key only, before `;` (baggage properties).
  static String? _memberKey(String member) {
    final eq = member.indexOf('=');
    if (eq <= 0) return null;
    final key = member.substring(0, eq).split(';').first.trim().toLowerCase();
    return key.isEmpty ? null : key;
  }

  static bool _isAllZero(String value) {
    for (var i = 0; i < value.length; i++) {
      if (value.codeUnitAt(i) != 0x30) return false; // '0'
    }
    return true;
  }
}

bool _isHex(String value, int length) {
  if (value.length != length) return false;
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final isDigit = c >= 0x30 && c <= 0x39;
    final isLowerAf = c >= 0x61 && c <= 0x66;
    if (!isDigit && !isLowerAf) return false;
  }
  return true;
}

final Random _spanRng = Random.secure();

/// Generates a W3C parent-id (span-id): 8 random bytes → 16 lowercase hex, never
/// all-zero. A new id for every request, so concurrent calls do not share
/// the span. Injectable in the interceptor for deterministic tests.
String defaultSpanIdGenerator() {
  final bytes = List<int>.generate(8, (_) => _spanRng.nextInt(256));
  if (bytes.every((b) => b == 0)) bytes[7] = 1; // avoid the null span-id
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
