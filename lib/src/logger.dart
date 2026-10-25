import 'client.dart';
import 'log_level.dart';

/// Compatible (`Logger`-style) logger that forwards every message to the
/// CloseYourIt logs domain. Mirrors `CloseYourIt::LogDevice`.
///
/// If [_client] is `null` (client not initialized) every method is a no-op.
class CloseYourItLogger {
  CloseYourItLogger(this._client);

  final CloseYourItClient? _client;

  /// `debug` level log.
  void debug(String message,
          {String? logger, Map<String, Object?>? attributes}) =>
      _client?.log(LogLevel.debug, message,
          logger: logger, attributes: attributes);

  /// `info` level log.
  void info(String message,
          {String? logger, Map<String, Object?>? attributes}) =>
      _client?.log(LogLevel.info, message,
          logger: logger, attributes: attributes);

  /// `warning` level log (`warn` → `warning`).
  void warn(String message,
          {String? logger, Map<String, Object?>? attributes}) =>
      _client?.log(LogLevel.warning, message,
          logger: logger, attributes: attributes);

  /// `error` level log.
  void error(String message,
          {String? logger, Map<String, Object?>? attributes}) =>
      _client?.log(LogLevel.error, message,
          logger: logger, attributes: attributes);

  /// `fatal` level log.
  void fatal(String message,
          {String? logger, Map<String, Object?>? attributes}) =>
      _client?.log(LogLevel.fatal, message,
          logger: logger, attributes: attributes);
}
