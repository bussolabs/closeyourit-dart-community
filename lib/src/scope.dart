import 'breadcrumb.dart';
import 'breadcrumb_buffer.dart';
import 'scrubber.dart';
import 'uuid.dart';

/// Context attached to events: user, tags, extra, contexts, request, trace_id and
/// breadcrumb history.
///
/// Mirrors `CloseYourIt::Scope`. In Flutter (single isolate) it is a global
/// mutable holder managed by the façade; there is no per-fiber isolation as in Rails.
///
/// The [traceId] correlates logs/errors/metrics of the same logical unit and is
/// never left missing: [ensureTraceId] generates one on the first event unless
/// set by hand with [setTraceId], and [rotateTraceId] rotates it on every
/// navigation (via NavigatorObserver). Parity with the other SDKs (JS
/// per page, Ruby per request).
class Scope {
  Scope({int maxBreadcrumbs = 100, String Function()? traceIdGenerator})
      : breadcrumbs = BreadcrumbBuffer(maxSize: maxBreadcrumbs),
        _traceIdGenerator = traceIdGenerator ?? Uuid.v4NoDashes;

  /// Breadcrumb ring buffer.
  final BreadcrumbBuffer breadcrumbs;

  final Map<String, Object?> _user = <String, Object?>{};
  final Map<String, String> _tags = <String, String>{};
  final Map<String, Object?> _extra = <String, Object?>{};
  final Map<String, Object?> _contexts = <String, Object?>{};

  /// Context of the current HTTP request (already filtered by the header allowlist).
  Map<String, Object?>? request;

  /// Generates the trace_id when auto-populated (injectable in tests).
  final String Function() _traceIdGenerator;

  /// Correlation ID shared by logs/errors/metrics of the same logical
  /// unit. Auto-populated by [ensureTraceId] on the first event (unless set
  /// by hand with [setTraceId]) and rotated by [rotateTraceId] on every navigation.
  /// `null` until generated/set.
  String? traceId;

  /// `true` if [traceId] was pinned by hand with [setTraceId] (non-null id):
  /// in that case [rotateTraceId] (navigation) does NOT overwrite it, so an
  /// explicitly correlated flow survives screen changes.
  bool _traceIdPinned = false;

  /// Sets the user. Without `sendPii` only [id] is serialized.
  void setUser(
      {String? id, String? email, String? ipAddress, String? username}) {
    _user
      ..clear()
      ..addAll(<String, Object?>{
        if (id != null) 'id': id,
        if (email != null) 'email': email,
        if (ipAddress != null) 'ip_address': ipAddress,
        if (username != null) 'username': username,
      });
  }

  /// Sets a single tag.
  void setTag(String key, String value) => _tags[key] = value;

  /// Adds several tags.
  void setTags(Map<String, String> tags) => _tags.addAll(tags);

  /// Sets a scalar extra value.
  void setExtra(String key, Object? value) => _extra[key] = value;

  /// Sets a named context (nested map).
  void setContext(String key, Map<String, Object?> value) =>
      _contexts[key] = value;

  /// Sets the correlation ID.
  ///
  /// A non-null [id] "pins" the trace: it survives navigation
  /// until released with `setTraceId(null)` or [clear]. Passing `null`
  /// releases the pin and restarts auto-population.
  void setTraceId(String? id) {
    traceId = id;
    _traceIdPinned = id != null;
  }

  /// Returns the current trace_id, generating and storing one if missing.
  ///
  /// Auto-population consistent with the other SDKs (JS per page, Ruby
  /// per request): without an explicit [setTraceId], events of the same
  /// logical unit (same tap/screen, until you navigate or clear the
  /// scope) share the same trace_id and stay correlatable. A hand-set
  /// [traceId] is NOT overwritten.
  String ensureTraceId() => traceId ?? (traceId = _traceIdGenerator());

  /// Starts a new logical correlation unit: generates and stores a new
  /// trace_id. Used by the NavigatorObserver on every navigation — parity with
  /// the JS client's "per page".
  ///
  /// A trace pinned by hand with [setTraceId] takes precedence and is NOT
  /// rotated: the explicitly correlated flow (e.g. a multi-screen checkout)
  /// survives navigation until it is released.
  String rotateTraceId() =>
      _traceIdPinned ? ensureTraceId() : (traceId = _traceIdGenerator());

  /// Sets the request context (typically from the Dio interceptor).
  void setRequest(Map<String, Object?>? value) => request = value;

  /// Adds a breadcrumb to the history.
  void addBreadcrumb(Breadcrumb crumb) => breadcrumbs.add(crumb);

  /// Resets the whole scope.
  void clear() {
    _user.clear();
    _tags.clear();
    _extra.clear();
    _contexts.clear();
    request = null;
    traceId = null;
    _traceIdPinned = false;
    breadcrumbs.clear();
  }

  /// Serializes to Sentry keys, including only the sections that have values.
  ///
  /// `user` is reduced to its `id` unless [sendPii]. Tags/extra/contexts go
  /// through the [Scrubber]. Breadcrumbs become `{values:[...]}`.
  Map<String, Object?> toEventHash({required bool sendPii}) {
    final hash = <String, Object?>{};

    final user = _userHash(sendPii: sendPii);
    if (user.isNotEmpty) hash['user'] = user;
    if (_tags.isNotEmpty) {
      hash['tags'] = Scrubber.scrubMap(Map<String, Object?>.from(_tags));
    }
    if (_extra.isNotEmpty) hash['extra'] = Scrubber.scrubMap(_extra);
    if (_contexts.isNotEmpty) hash['contexts'] = Scrubber.scrubMap(_contexts);
    if (request != null) hash['request'] = request;
    final crumbs = breadcrumbs.toJson();
    if (crumbs != null) hash['breadcrumbs'] = crumbs;

    return hash;
  }

  Map<String, Object?> _userHash({required bool sendPii}) {
    if (_user.isEmpty) return const <String, Object?>{};
    if (sendPii) return Map<String, Object?>.from(_user);
    final id = _user['id'];
    return id == null ? const <String, Object?>{} : <String, Object?>{'id': id};
  }
}
