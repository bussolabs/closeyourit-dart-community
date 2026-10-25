import 'package:stack_trace/stack_trace.dart';

/// Converts a Dart [StackTrace] into Sentry-format frames (`stacktrace.frames`).
///
/// Order: from the oldest (bottom) to the most recent (top of the stack) —
/// the Sentry convention, where `frames.last` is the crash point. A Dart
/// [StackTrace] is newest-first instead, so it is reversed.
abstract final class StackFrames {
  /// Packages treated as "framework" (not `in_app`).
  static const List<String> _frameworkPackages = ['flutter', 'closeyourit'];

  /// Extracts the Sentry frames from [stackTrace].
  ///
  /// [inAppPackages]: app package names treated as `in_app: true`
  /// (on top of the default heuristic). If empty, every non-framework
  /// `package:` frame plus those of the main isolate are in-app.
  static List<Map<String, Object?>> parse(
    StackTrace? stackTrace, {
    List<String> inAppPackages = const [],
  }) {
    if (stackTrace == null) return const [];

    final trace = Trace.from(stackTrace);
    final frames = trace.frames
        .where((f) => f.member != null || f.uri.toString().isNotEmpty)
        .map((f) => _frameToJson(f, inAppPackages))
        .toList();

    // Sentry: oldest first, crash last.
    return frames.reversed.toList();
  }

  static Map<String, Object?> _frameToJson(
      Frame frame, List<String> inAppPackages) {
    final uri = frame.uri;
    final filename =
        uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.toString();

    return <String, Object?>{
      'filename': filename,
      'abs_path': uri.toString(),
      if (frame.member != null) 'function': frame.member,
      if (frame.line != null) 'lineno': frame.line,
      if (frame.column != null) 'colno': frame.column,
      'in_app': _isInApp(frame, inAppPackages),
    };
  }

  static bool _isInApp(Frame frame, List<String> inAppPackages) {
    if (frame.isCore) return false; // dart:core, dart:async, ...
    final package = frame.package;
    if (package == null) return true; // main isolate / app entrypoint
    if (inAppPackages.contains(package)) return true;
    return !_frameworkPackages.contains(package);
  }
}
