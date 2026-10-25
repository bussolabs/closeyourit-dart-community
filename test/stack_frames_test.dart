import 'package:closeyourit/src/stack_frames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StackFrames.parse', () {
    test('null or empty → empty list', () {
      expect(StackFrames.parse(null), isEmpty);
      expect(StackFrames.parse(StackTrace.fromString('')), isEmpty);
    });

    test('reverses the order: the crash (#0) becomes the last frame', () {
      final st = StackTrace.fromString(
        '#0      Boom.explode (package:my_app/boom.dart:10:5)\n'
        '#1      main (package:my_app/main.dart:3:3)\n',
      );
      final frames = StackFrames.parse(st);
      expect(frames.length, 2);
      expect(frames.first['function'], 'main'); // oldest first
      expect(frames.last['function'], 'Boom.explode'); // crash last
    });

    test('extracts filename, function, lineno, colno, abs_path', () {
      final st = StackTrace.fromString(
          '#0      Boom.explode (package:my_app/sub/boom.dart:10:5)\n');
      final f = StackFrames.parse(st).single;
      expect(f['filename'], 'boom.dart');
      expect(f['function'], 'Boom.explode');
      expect(f['lineno'], 10);
      expect(f['colno'], 5);
      expect(f['abs_path'], 'package:my_app/sub/boom.dart');
    });

    test('in_app: app true, flutter false, dart core false', () {
      final st = StackTrace.fromString(
        '#0      App.method (package:my_app/a.dart:1:1)\n'
        '#1      Widget.build (package:flutter/src/widgets/framework.dart:2:2)\n'
        '#2      _rootRun (dart:async/zone.dart:3:3)\n',
      );
      final frames = StackFrames.parse(st);
      final byFn = {for (final f in frames) f['function']: f['in_app']};
      expect(byFn['App.method'], isTrue);
      expect(byFn['Widget.build'], isFalse);
      expect(byFn['_rootRun'], isFalse);
    });

    test('inAppPackages forces in_app for the given packages', () {
      final st = StackTrace.fromString(
          '#0      X.y (package:shared_kit/x.dart:1:1)\n');
      final f = StackFrames.parse(st, inAppPackages: ['shared_kit']).single;
      expect(f['in_app'], isTrue);
    });
  });
}
