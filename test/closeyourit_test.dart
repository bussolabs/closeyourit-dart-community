import 'dart:io';

import 'package:closeyourit/closeyourit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SDK identity', () {
    // The test name promised "consistent with the pubspec" but compared against a number
    // written by hand: every release broke it without saying anything about real consistency,
    // and silencing it only took rewriting the number — that is, disabling the check. Now the
    // expected version is read from the pubspec: a clean release passes on its own, and a version
    // forgotten in `lib/src/version.dart` (the one that ends up in every sent event)
    // fails here instead of on whoever receives the data.
    test('exposes a name and version consistent with the pubspec', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
          .firstMatch(pubspec)!
          .group(1);

      expect(closeYourItSdkName, 'closeyourit-dart');
      expect(closeYourItSdkVersion, version);
    });
  });
}
