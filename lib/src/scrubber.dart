/// Client-side PII redaction, before sending.
///
/// Mirrors `CloseYourIt::Scrubber` (gem): recursively redacts the values whose
/// **key** matches the denylist of sensitive fields. Same list as the
/// backend (`Logs::Ingest::Normalize::SENSITIVE_KEY`) → defense in depth.
///
/// The backend re-scrubs anyway: this only reduces exposure in transit.
abstract final class Scrubber {
  /// Key tokens that are always redacted (substring match, case-insensitive).
  /// Aligned 1:1 with the `SENSITIVE_KEY` regex of backend + Ruby gem (PII parity):
  ///   pass secret token api_key apikey authorization cookie csrf credit card
  ///   cvv ssn iban email phone telephone mobile dob birth passport bearer
  ///   session pin pan
  /// Substring matching favours over-redaction (privacy by default):
  /// `pin`/`pan` also redact non-PII columns, a choice preferred to a leak.
  /// (`passport`/`bearer`/`pan` were already covered by `pass`/`token`/`card`;
  /// listed anyway for 1:1 parity.) Single source for [sensitiveKey] and
  /// [_sensitiveAssignment] → they cannot diverge.
  static const String _keyTokens =
      r'pass|secret|token|api[_-]?key|apikey|authorization|cookie|csrf|credit|'
      r'card|cvv|ssn|iban|email|phone|telephone|mobile|dob|birth|passport|'
      r'bearer|session|pin|pan';

  /// Keys treated as sensitive (case-insensitive match on part of the name).
  static final RegExp sensitiveKey = RegExp(_keyTokens, caseSensitive: false);

  /// HTTP authentication schemes (RFC 7235) recognised in a free-form
  /// message. The value that follows is the credential: it must be redacted
  /// together with the scheme, not after it (CYDA-26).
  static const String _authSchemes = r'bearer|basic|digest|negotiate|ntlm';

  /// Characters of a `token68` credential (RFC 7235) plus the `.` that separates
  /// the three parts of a JWT.
  static const String _credentialChar = r'[A-Za-z0-9\-._~+/=]';

  /// Non-alphabetic character that tells a credential apart from prose when
  /// the context of a header ([_authHeader]) is missing. The `.` is excluded on
  /// purpose: it is also a sentence full stop, and on its own it would make
  /// "serve Basic required." look like a credential.
  static const String _credentialSymbol = r'[0-9\-_~+/=]';

  /// Comma-separated list of `key="value"` auth-params: the `Digest` credential
  /// (RFC 7616) is not a single token and extends well past the
  /// first space — stopping there would leave `nonce` and `response` in clear text.
  static const String _authParams = r'[\w-]+\s*=\s*(?:"[^"\n]*"|[^\s,]*)'
      r'(?:\s*,\s*[\w-]+\s*=\s*(?:"[^"\n]*"|[^\s,]*))*';

  /// Authentication header in textual form: a key containing `auth`
  /// (`Authorization`, `Proxy-Authorization`, `X-Auth`…), the separator, a
  /// scheme and its credential — the whole pair collapses into [filtered].
  ///
  /// The "authentication key + scheme" context is already enough evidence:
  /// here the credential does not have to look like a secret, and even a
  /// letters-only base64 (`X-Auth: Basic YWJjOmRlZg`) is redacted.
  /// Constraining the key to `auth` is what keeps prose out: in
  /// `error: Basic authentication failed` the key is not an authentication one.
  ///
  /// The quantifiers around `auth` are bounded (`{0,32}`, beyond the length
  /// of any real header name): unbounded ones would cost quadratic
  /// backtracking on a long message without `auth` in it — 117 ms
  /// for 4 KB, growing quadratically, on the thread that is reporting the error.
  static final RegExp _authHeader = RegExp(
    r'[\w-]{0,32}auth[\w-]{0,32}\s*[=:]\s*'
    '(?:$_authSchemes)'
    r'[ \t]+'
    '(?:$_authParams|$_credentialChar+)',
    caseSensitive: false,
  );

  /// `sensitive_key=value` (or `:`) assignment inside a free-form message.
  /// Same tokens as [sensitiveKey]; redacts the whole `key=value` pair.
  /// The value stays `\S+`: a password can be made of punctuation only
  /// and must be redacted entirely, delimiters included.
  static final RegExp _sensitiveAssignment = RegExp(
    '(?:$_keyTokens)' r'[\w-]*\s*[=:]\s*\S+',
    caseSensitive: false,
  );

  /// Authentication scheme quoted in prose, without a header key in front
  /// (`request rejected with Bearer eyJ…`). Without that context the
  /// credential must be recognised by its shape: at least 8 `token68` characters
  /// and at least one [_credentialSymbol], so "bearer of bad news" stays readable.
  /// Only horizontal whitespace is allowed between scheme and credential: a scheme
  /// at the end of a line must not swallow the next line of a multi-line message.
  static final RegExp _authCredential = RegExp(
    '\\b(?:$_authSchemes)[ \\t]+'
    '(?=$_credentialChar{8,})'
    '$_credentialChar*$_credentialSymbol$_credentialChar*',
    caseSensitive: false,
  );

  /// Replacement value for redacted fields.
  static const String filtered = '[FILTERED]';

  /// Returns a deep copy of [input] with sensitive values redacted.
  ///
  /// A key matching [sensitiveKey] redacts the whole value
  /// (even if it is a map/list). Nested Maps and Lists are traversed.
  static Map<String, Object?> scrubMap(Map<String, Object?> input) {
    final result = <String, Object?>{};
    input.forEach((key, value) {
      result[key] = sensitiveKey.hasMatch(key) ? filtered : _scrubValue(value);
    });
    return result;
  }

  static Object? _scrubValue(Object? value) {
    if (value is Map) {
      return scrubMap(value.map((k, v) => MapEntry(k.toString(), v)));
    }
    if (value is List) {
      return value.map(_scrubValue).toList();
    }
    return value;
  }

  /// Redacts `sensitive_key=value` pairs in a free-form text message
  /// (e.g. an exception message), before sending.
  ///
  /// The backend does NOT re-scrub messages by default → this is the only defense
  /// against secrets that ended up in `exception.message` by mistake. Defensive
  /// mirror of `CloseYourIt::Scrubber#scrub_message`.
  ///
  /// **Redaction contract, shared by every SDK** (JS, Python, Ruby,
  /// Dart): authentication scheme and credential collapse into a **single**
  /// [filtered] — `Authorization: Bearer <credential>` becomes `[FILTERED]`,
  /// never `[FILTERED] <credential>` nor `[FILTERED] [FILTERED]`. Text that
  /// is not a credential stays intact and readable.
  /// [_authHeader] goes first: on `Authorization: Bearer <credential>`
  /// [_sensitiveAssignment] would stop at `Bearer` (its `\S+` ends at the
  /// first space) and leave the credential in clear text.
  static String scrubMessage(String input) => input
      .replaceAll(_authHeader, filtered)
      .replaceAll(_sensitiveAssignment, filtered)
      .replaceAll(_authCredential, filtered);

  /// Safe representation of [uri] for breadcrumbs, request context and error
  /// details (CYDA-8). The query of an HTTP request can carry passwords,
  /// tokens, emails or one-time codes: by **default** (`sendPii` false) it is
  /// removed entirely, leaving only `scheme://host/path` — a safe origin and
  /// path. With [sendPii] the query is included but parameters whose key
  /// matches the shared PII denylist ([sensitiveKey]) are redacted to
  /// [filtered], reusing [scrubMap] (no duplicated denylist, CYDA-4).
  ///
  /// `userInfo` (the `user:pass@` credentials) and `fragment` are **always**
  /// excluded. Robust on relative or malformed URIs too (missing scheme/host).
  static String sanitizeUri(Uri uri, {bool sendPii = false}) {
    final origin = _origin(uri);
    if (!sendPii || uri.query.isEmpty) return origin;
    // queryParametersAll keeps repeated keys; scrubMap redacts the sensitive
    // ones (the whole list value → [filtered]) and traverses the others.
    final scrubbed = scrubMap(uri.queryParametersAll);
    final pairs = <String>[];
    scrubbed.forEach((key, value) {
      final safeKey = Uri.encodeQueryComponent(key);
      if (value is List) {
        // Benign parameter: re-encode every value, otherwise a value that
        // contains `&`/`=` would produce spurious parameters in the rebuilt URL.
        for (final item in value) {
          pairs.add('$safeKey=${Uri.encodeQueryComponent('$item')}');
        }
      } else {
        // Sensitive key: [value] is the [filtered] placeholder, keep it
        // readable (`[`/`]` do not break the split on `&`/`=`).
        pairs.add('$safeKey=$value');
      }
    });
    return pairs.isEmpty ? origin : '$origin?${pairs.join('&')}';
  }

  /// `scheme://host[:port]/path` of [uri], without query, fragment or userInfo.
  /// Rebuilt with [Uri] so a non-standard port is kept and the scheme's default
  /// one omitted; robust on relative/malformed URIs (missing authority
  /// → only the path remains).
  static String _origin(Uri uri) {
    return Uri(
      scheme: uri.scheme.isEmpty ? null : uri.scheme,
      host: uri.host.isEmpty ? null : uri.host,
      port: uri.port,
      path: uri.path,
    ).toString();
  }
}
