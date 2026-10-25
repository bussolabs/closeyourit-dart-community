import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// CI hardening and dependency maintenance (CYDA-17).
///
/// A moving reference (`@v6`) lets whoever controls the action's repository
/// decide which code runs on the runner that publishes to pub.dev: whoever gets
/// that repo can re-point the tag and get executed on the job holding the OIDC token.
/// Pinning to the commit SHA makes the revision verifiable, minimal permissions
/// limit what that code could do, Dependabot keeps the pins alive instead of
/// fossilising them.
///
/// On dependencies the trap is the opposite: raising a constraint too much makes the
/// package unresolvable on the declared minimum Flutter, because the SDK pins
/// some packages to an EXACT version (`meta` 1.17.0 on 3.38.1, 1.18.0 on
/// 3.44.1). These tests lock both sides of the Definition of Done.
///
/// These checks hold for every workflow in `.github/workflows`, whichever
/// repository ships them; the ones that read the private release workflows
/// by name live in test/ci_workflows_test.dart.

/// `meta` version pinned by the minimum supported Flutter (3.38.1).
const metaOnMinimumFlutter = '1.17.0';

/// `meta` version pinned by the stable exercised in CI (3.44.1).
const metaOnCurrentFlutter = '1.18.0';

final workflowsDir = Directory('.github/workflows');

File workflowFile(String name) => File('${workflowsDir.path}/$name');

YamlMap loadWorkflow(String name) =>
    loadYaml(workflowFile(name).readAsStringSync()) as YamlMap;

/// `uses:` of every step or job, with the rest of the line (where the version
/// comment lives).
final usesPattern =
    RegExp(r'^\s*-?\s*uses:[ \t]*(\S+)([^\n]*)', multiLine: true);

/// A verifiable pin: `owner/repo[/path]@<sha 40 hex>`.
final pinnedPattern = RegExp(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$');

/// The comment that keeps the pin readable and that Dependabot rewrites on every bump.
final versionCommentPattern = RegExp(r'#\s*v\d+\.\d+\.\d+');

void main() {
  final workflowNames = workflowsDir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.yml') || n.endsWith('.yaml'))
      .toList()
    ..sort();

  group('CI workflows — actions pinned to a verifiable revision', () {
    test('the pin checks below see at least one external action', () {
      final external = workflowNames.expand((name) => usesPattern
          .allMatches(workflowFile(name).readAsStringSync())
          .map((match) => match.group(1)!)
          .where((ref) => !ref.startsWith('./')));
      expect(
        external,
        isNotEmpty,
        reason: 'if the regex stops finding the `uses:` the tests below '
            'would pass vacuously',
      );
    });

    for (final name in workflowNames) {
      test('$name uses only SHA-pinned actions with the version as a comment',
          () {
        final source = workflowFile(name).readAsStringSync();
        for (final match in usesPattern.allMatches(source)) {
          final ref = match.group(1)!;
          final trailing = match.group(2)!;
          // This repo's reusable workflows travel with the commit of the
          // repo itself: there is no third party to trust.
          if (ref.startsWith('./')) continue;

          expect(
            ref,
            matches(pinnedPattern),
            reason: '$name: `$ref` points to a moving reference; the full '
                'commit SHA is required',
          );
          if (ref.startsWith('bussolabs/ci-templates/')) continue;
          expect(
            trailing,
            matches(versionCommentPattern),
            reason:
                '$name: the pin of `$ref` lacks the `# vX.Y.Z` comment that '
                'makes the version readable and guides Dependabot',
          );
        }
      });
    }
  });

  group('CI workflows — minimal permissions', () {
    for (final name in workflowNames) {
      test('$name grants read-only repository access by default', () {
        final permissions = loadWorkflow(name)['permissions'];
        expect(
          permissions,
          isA<YamlMap>(),
          reason: '$name: without an explicit `permissions` the repository '
              'default applies, which can be read-write on everything',
        );
        final map = permissions! as YamlMap;
        expect(map['contents'], 'read',
            reason: '$name: needed for the checkout');
        expect(
          map.keys.where((k) => map[k] == 'write'),
          isEmpty,
          reason: '$name: no write at workflow level; whoever needs it '
              'asks for it in their own job',
        );
      });
    }
  });

  group('CI Pub configuration isolation', () {
    for (final workflow in workflowNames) {
      test('$workflow isolates Linux Pub configuration before Flutter setup',
          () {
        final jobs = loadWorkflow(workflow)['jobs']! as YamlMap;
        for (final job in jobs.values.whereType<YamlMap>()) {
          final steps = job['steps'];
          if (steps is! YamlList) continue;
          final flutterIndex = steps.indexWhere((step) =>
              step is YamlMap &&
              (step['uses'] as String? ?? '')
                  .startsWith('subosito/flutter-action@'));
          if (flutterIndex < 0) continue;
          final setupIndex = steps.indexWhere((step) =>
              step is YamlMap &&
              step['run'] == 'sh tool/setup_ci_pub_config.sh');
          expect(setupIndex, greaterThanOrEqualTo(0));
          expect(setupIndex, lessThan(flutterIndex));
          expect((steps[setupIndex] as YamlMap)['if'],
              r"${{ runner.os == 'Linux' }}");
        }
      });
    }

    test('configuration directory is private and unique for each job',
        () async {
      final root = Directory.systemTemp.createTempSync('cyi-pub-config-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final paths = <String>[];
      for (var attempt = 0; attempt < 2; attempt++) {
        final envFile = File('${root.path}/environment-$attempt');
        envFile.writeAsStringSync('EXISTING=value\n');
        final result = await Process.run('sh', [
          'tool/setup_ci_pub_config.sh'
        ], environment: {
          'RUNNER_TEMP': root.path,
          'GITHUB_ENV': envFile.path
        });
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final lines = envFile.readAsLinesSync();
        expect(lines.first, 'EXISTING=value');
        final path = lines
            .singleWhere((line) => line.startsWith('XDG_CONFIG_HOME='))
            .split('=')
            .last;
        paths.add(path);
        expect(path, startsWith('${root.path}/cyi-pub-config.'));
        final directory = Directory(path);
        expect(directory.existsSync(), isTrue);
        expect(directory.statSync().mode & 0x1ff, 0x1c0);
        expect(directory.listSync(), isEmpty);
      }
      expect(paths.toSet(), hasLength(2));
    });
  });

  group('Android SDK isolation', () {
    test('concurrent jobs receive distinct Android SDK roots', () async {
      final root = Directory.systemTemp.createTempSync('cyi-android-test-');
      addTearDown(() => root.deleteSync(recursive: true));
      final files = List.generate(2, (i) => File('${root.path}/job-$i'));
      final results = await Future.wait(files.map((file) => Process.run(
          'sh', ['tool/setup_ci_android_sdk.sh'],
          environment: {'RUNNER_TEMP': root.path, 'GITHUB_ENV': file.path})));
      final paths = <String>{};
      for (var i = 0; i < results.length; i++) {
        expect(results[i].exitCode, 0, reason: '${results[i].stderr}');
        final lines = files[i].readAsLinesSync();
        final path = lines
            .singleWhere((line) => line.startsWith('ANDROID_SDK_ROOT='))
            .split('=')
            .last;
        expect(lines, contains('ANDROID_HOME=$path'));
        expect(path, startsWith('${root.path}/cyi-android-sdk.'));
        expect(Directory(path).existsSync(), isTrue);
        expect(Directory(path).statSync().mode & 0x1ff, 0x1c0);
        expect(Directory(path).listSync(), isEmpty);
        paths.add(path);
      }
      expect(paths, hasLength(2));
    });
  });

  group('maintenance — automated updates', () {
    test('Dependabot covers actions and pub packages', () {
      final file = File('.github/dependabot.yml');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'without automation SHA pins age silently',
      );

      final config = loadYaml(file.readAsStringSync()) as YamlMap;
      expect(config['version'], 2);

      final updates = config['updates']! as YamlList;
      final ecosystems =
          updates.map((u) => (u as YamlMap)['package-ecosystem']).toSet();
      expect(ecosystems, containsAll(<String>['github-actions', 'pub']));

      for (final update in updates) {
        final entry = update as YamlMap;
        expect(
          (entry['schedule']! as YamlMap)['interval'],
          isNotNull,
          reason: 'every ecosystem must have a declared schedule',
        );
      }

      // `dependency-type` inside a group only applies where Dependabot tells
      // development and production dependencies apart: elsewhere the group does not
      // apply and the option goes unnoticed.
      const ecosystemsWithDependencyType = <String>{
        'bundler',
        'composer',
        'mix',
        'maven',
        'npm',
        'pip',
      };
      for (final update in updates) {
        final entry = update as YamlMap;
        final groups = entry['groups'];
        if (groups is! YamlMap) continue;
        for (final group in groups.values) {
          if ((group as YamlMap)['dependency-type'] == null) continue;
          expect(
            ecosystemsWithDependencyType,
            contains(entry['package-ecosystem']),
            reason: '${entry['package-ecosystem']}: `dependency-type` in '
                'groups is not supported by this ecosystem, the group '
                'would be a dead letter',
          );
        }
      }

      final pubDirectories = updates
          .where((u) => (u as YamlMap)['package-ecosystem'] == 'pub')
          .map((u) => (u as YamlMap)['directory'])
          .toSet();
      expect(
        pubDirectories,
        containsAll(<String>['/', '/example']),
        reason: 'the example app is part of the build matrix too',
      );
    });
  });

  group('dependencies — constraints compatible with the supported Flutter', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;

    test('the meta constraint accepts the version pinned by the SDK', () {
      final dependencies = pubspec['dependencies']! as YamlMap;
      final constraint =
          VersionConstraint.parse(dependencies['meta']! as String);

      expect(
        constraint.allows(Version.parse(metaOnMinimumFlutter)),
        isTrue,
        reason: 'Flutter 3.38.1 pins meta $metaOnMinimumFlutter: a higher '
            'constraint makes the package unresolvable on the declared minimum',
      );
      expect(
        constraint.allows(Version.parse(metaOnCurrentFlutter)),
        isTrue,
        reason: 'Flutter 3.44.1 pins meta $metaOnCurrentFlutter',
      );
    });
  });
}
