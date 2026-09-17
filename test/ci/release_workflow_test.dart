@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release/release_notes.dart';

/// Guards `.github/workflows/release.yml` (docs/RELEASING.md).
///
/// The workflow only runs when a maintainer pushes a release tag, so nothing
/// exercises it on a pull request. These checks hold the properties whose loss
/// would only show in a published release: an APK users cannot update, a
/// download link that 404s, a version the app does not report.
void main() {
  final release = File('.github/workflows/release.yml').readAsStringSync();

  /// A job's block: from its key to the next top-level job, or EOF.
  String job(String name) {
    final start = release.indexOf('\n  $name:\n');
    expect(start, greaterThanOrEqualTo(0), reason: 'no `$name` job');
    final next = RegExp(r'\n  [a-z][a-z0-9_-]*:\n')
        .allMatches(release, start + 1)
        .map((m) => m.start)
        .firstWhere((i) => i > start, orElse: () => release.length);
    return release.substring(start, next);
  }

  group('release trigger', () {
    test('is a pushed vMAJOR.MINOR.PATCH tag and nothing else', () {
      // Act
      final trigger = release.substring(
        release.indexOf('\non:\n'),
        release.indexOf('\npermissions:'),
      );

      // Assert — a branch push or a PR must never publish a release.
      expect(trigger, contains('tags:'));
      expect(trigger, contains('- "v[0-9]+.[0-9]+.[0-9]+"'));
      expect(trigger, isNot(contains('branches')));
      expect(trigger, isNot(contains('pull_request')));
    });

    test('write access is granted per job, not workflow-wide', () {
      // Act
      final topLevel = release.substring(
        release.indexOf('\npermissions:'),
        release.indexOf('\njobs:'),
      );

      // Assert — the android job handles the signing key and needs no token.
      expect(topLevel, contains('contents: read'));
      expect(topLevel, isNot(contains('write')));
      expect(job('android'), isNot(contains('contents: write')));
    });
  });

  group('release android job', () {
    test('builds one APK per ABI, for v7 and v8 only', () {
      // Arrange
      final android = job('android');

      // Assert
      final build = RegExp(
        r'flutter build apk --release --split-per-abi[^#]*?'
        r'--target-platform android-arm,android-arm64\b',
      );
      expect(build.hasMatch(android), isTrue);
    });

    test('refuses to publish an APK signed with the debug key', () {
      // Arrange
      final android = job('android');

      // Assert — build.gradle.kts falls back to the debug key when
      // key.properties is missing, and Android never lets a later release
      // with another certificate install over such an APK.
      expect(android, contains('Check signing secrets'));
      expect(android, contains("grep -q 'CN=Android Debug'"));
    });

    test('uploads the file names the release notes link to', () {
      // Arrange
      final android = job('android');
      final body =
          ReleaseNotes.build(
            tag: 'v9.9.9',
            previousTag: null,
            repository: 'MostroP2P/app',
            date: DateTime.utc(2026),
            commits: const [],
            pullRequests: const [],
          ).renderReleaseBody();

      // Assert
      expect(android, contains('for abi in armeabi-v7a arm64-v8a; do'));
      expect(android, contains(r'apk="dist/mostro-$TAG-$abi.apk"'));
      for (final abi in ['armeabi-v7a', 'arm64-v8a']) {
        expect(
          body,
          contains('/releases/download/v9.9.9/mostro-v9.9.9-$abi.apk'),
        );
      }
    });

    test('uses the same Flutter as CI', () {
      // Arrange
      final ci = File('.github/workflows/ci.yml').readAsStringSync();
      final pin = RegExp(r'FLUTTER_VERSION: "([^"]+)"');

      // Assert
      expect(pin.firstMatch(release)?.group(1), pin.firstMatch(ci)?.group(1));
    });
  });

  group('android signing configuration', () {
    test('key.properties and keystores are never committed', () {
      // Act
      final ignore = File('android/.gitignore').readAsStringSync();

      // Assert
      expect(ignore, contains('key.properties'));
      expect(ignore, contains('**/*.jks'));
    });

    test('ndk.abiFilters is not set for a split-per-abi build', () {
      // Act
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();

      // Assert — AGP fails the build with "Conflicting configuration" when
      // both are present, which only the release workflow would run into.
      final guard = gradle.indexOf('findProperty("split-per-abi")');
      expect(guard, greaterThanOrEqualTo(0));
      expect(guard, lessThan(gradle.indexOf('abiFilters +=')));
    });
  });

  group('app version', () {
    test('pubspec.yaml and rust/Cargo.toml declare the same version', () {
      // Arrange
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final cargo = File('rust/Cargo.toml').readAsStringSync();

      // Act
      final dart = RegExp(
        r'^version: ([0-9.]+)',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1);
      final rust = RegExp(
        r'^version = "([0-9.]+)"',
        multiLine: true,
      ).firstMatch(cargo)?.group(1);

      // Assert — the About screen reports the Rust one, the release workflow
      // checks a tag against both; scripts/bump-version.sh moves them together.
      expect(dart, isNotNull);
      expect(dart, rust);
    });
  });
}
