import 'package:closeyourit/closeyourit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LogLevel.fromString', () {
    test('maps the canonical values', () {
      expect(LogLevel.fromString('debug'), LogLevel.debug);
      expect(LogLevel.fromString('info'), LogLevel.info);
      expect(LogLevel.fromString('warning'), LogLevel.warning);
      expect(LogLevel.fromString('error'), LogLevel.error);
      expect(LogLevel.fromString('fatal'), LogLevel.fatal);
    });

    test('Logger aliases: warn→warning, err→error, unknown→fatal', () {
      expect(LogLevel.fromString('warn'), LogLevel.warning);
      expect(LogLevel.fromString('err'), LogLevel.error);
      expect(LogLevel.fromString('unknown'), LogLevel.fatal);
    });

    test('aliases are case-insensitive and tolerate spaces', () {
      expect(LogLevel.fromString('  ERR '), LogLevel.error);
      expect(LogLevel.fromString('Unknown'), LogLevel.fatal);
    });

    test('case-insensitive and tolerates spaces', () {
      expect(LogLevel.fromString('  ERROR '), LogLevel.error);
      expect(LogLevel.fromString('Warn'), LogLevel.warning);
    });

    test('unknown and null → info (like the backend)', () {
      expect(LogLevel.fromString('verbose'), LogLevel.info);
      expect(LogLevel.fromString(''), LogLevel.info);
      expect(LogLevel.fromString(null), LogLevel.info);
    });
  });

  group('LogLevel ordering', () {
    test('wire exposes the correct string', () {
      expect(LogLevel.warning.wire, 'warning');
      expect(LogLevel.fatal.wire, 'fatal');
    });

    test('>= comparison for the min-level filter', () {
      expect(LogLevel.error >= LogLevel.info, isTrue);
      expect(LogLevel.info >= LogLevel.info, isTrue);
      expect(LogLevel.debug >= LogLevel.info, isFalse);
    });
  });
}
