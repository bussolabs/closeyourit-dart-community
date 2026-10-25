import 'dart:math';

/// Minimal UUID v4 (random) generator, with no external dependencies.
abstract final class Uuid {
  static final Random _rng = Random.secure();

  /// UUID v4 with dashes (e.g. `550e8400-e29b-41d4-a716-446655440000`).
  ///
  /// Used as the metrics `sample_id`.
  static String v4() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// UUID v4 without dashes (32 hex). Used as the `event_id` of errors and logs.
  static String v4NoDashes() => v4().replaceAll('-', '');
}
