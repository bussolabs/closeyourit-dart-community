/// Canonical log levels, aligned with the CloseYourIt backend
/// (`debug` < `info` < `warning` < `error` < `fatal`).
///
/// The ordinal serves both the `logsMinLevel` filter and the event severity.
/// The [wire] is the string value accepted by the `/logs` ingest.
enum LogLevel {
  debug('debug'),
  info('info'),
  warning('warning'),
  error('error'),
  fatal('fatal');

  const LogLevel(this.wire);

  /// String value sent in the payload (`level`).
  final String wire;

  /// Normalizes an arbitrary string to the canonical level.
  ///
  /// Logger aliases (parity with the gem's `LogEvent::LEVEL_ALIASES`): `warn` →
  /// [warning], `err` → [error], `unknown` → [fatal]. Unknown → [info]
  /// (like the backend).
  static LogLevel fromString(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'info':
        return LogLevel.info;
      case 'warn':
      case 'warning':
        return LogLevel.warning;
      case 'err':
      case 'error':
        return LogLevel.error;
      case 'unknown':
      case 'fatal':
        return LogLevel.fatal;
      default:
        return LogLevel.info;
    }
  }

  /// `true` if this level is ≥ [other] (for the `logsMinLevel` filter).
  bool operator >=(LogLevel other) => index >= other.index;
}
