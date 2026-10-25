import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CYDA-21 — pub.dev must receive the release number, not another one.
///
/// `dart pub publish` sends the `version` from pubspec.yaml and never looks at the release tag.
/// Nobody compares the two: the release can be called 0.8.0 and publish 0.7.2, and end up
/// green. With the number computed by the server the two diverge BY CONSTRUCTION if it was not
/// updated inside — not by oversight — and if that number has already shipped pub.dev rejects the
/// good release: the tag is left created and nothing is published.
///
/// We RUN the script, we do not read it: what really stops publishing is the exit
/// code, and a test that compared the text would say green even with a broken script.
///
/// No version number written by hand in here: the real version is read from the pubspec, and
/// fake numbers are built in a temporary copy. A number copied into a test is the failure
/// that held back 0.7.1.
void main() {
  final realVersion = RegExp(r'^version:\s*(.+)$', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync())!
      .group(1)!
      .trim();

  // `GITHUB_REF_NAME` must always be set, even empty: the script uses it as a fallback when
  // the argument is missing, and inside GitHub Actions that variable already exists and is `main`.
  // Without clearing it the "no tag" case is never exercised here — locally it passes, in CI the
  // script receives `main` and answers about the version number instead of the missing tag.
  ProcessResult run(String tag, {String? pubspec, String refName = ''}) =>
      Process.runSync(
        'sh',
        ['tool/check_release.sh', tag],
        environment: {
          'GITHUB_REF_NAME': refName,
          if (pubspec != null) 'PUBSPEC': pubspec,
        },
      );

  String output(ProcessResult r) => '${r.stdout}${r.stderr}';

  group('the tag and the package version', () {
    test('match: the script passes', () {
      final result = run('v$realVersion');

      expect(result.exitCode, 0, reason: output(result));
      expect(output(result), contains('aligned'));
    });

    test('do not match: it stops and prints both numbers', () {
      final result = run('v99.99.99');

      expect(result.exitCode, isNot(0));
      expect(output(result), contains('::error::'));
      expect(output(result), contains('99.99.99'));
      expect(output(result), contains(realVersion));
    });

    // This repository has no pre-release channel: a tag with a hyphen is not a preview to
    // publish elsewhere, it is a mistake, and saying it now costs less than finding out on pub.dev.
    test('a pre-release tag stops, and explains why', () {
      final result = run('v$realVersion-beta.1');

      expect(result.exitCode, isNot(0));
      expect(output(result), contains('pre-release channel'));
    });

    // Fail-closed: a doubt is not a permission. Without this, a malformed pubspec would pass and
    // publishing would start without anyone knowing which number is shipping.
    test('a pubspec without a version stops', () async {
      final dir = await Directory.systemTemp.createTemp('cyda21');
      addTearDown(() => dir.delete(recursive: true));
      final fake = File('${dir.path}/pubspec.yaml');
      await fake.writeAsString('name: closeyourit\ndescription: no version\n');

      final result = run('v$realVersion', pubspec: fake.path);

      expect(result.exitCode, isNot(0));
      expect(output(result), contains('declares no version'));
    });

    test('an unreadable pubspec stops', () {
      final result = run('v$realVersion',
          pubspec: '/path/that/does/not/exist/pubspec.yaml');

      expect(result.exitCode, isNot(0));
      expect(output(result), contains('cannot read'));
    });

    test('without a tag it does not pass silently', () {
      final result = run('');

      expect(result.exitCode, isNot(0));
      expect(output(result), contains('no tag'));
    });
  });
}
