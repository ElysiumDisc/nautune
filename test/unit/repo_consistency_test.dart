// Anti-drift guard: fails CI (codemagic.yaml runs `flutter test`) when the
// app version, iOS deployment target, build config or docs fall out of sync
// with their single source of truth.
//
// Single sources of truth:
//   - App version:           pubspec.yaml `version:` (name+build)
//   - Release notes:         CHANGELOG.md (only place a version is written)
//   - iOS deployment target: ios/Runner.xcodeproj/project.pbxproj
//
// See DEVELOPMENT.md → "Releasing & versioning".
//
// `flutter test` runs with the package root as the working directory, so all
// paths below are repo-relative.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

bool _exists(String path) =>
    File(path).existsSync() || Directory(path).existsSync();

/// Human-facing docs that must stay accurate: README, DEVELOPMENT and every
/// Markdown file under docs/.
List<String> _docs() => [
      'README.md',
      'DEVELOPMENT.md',
      if (Directory('docs').existsSync())
        ...Directory('docs')
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => p.endsWith('.md')),
    ];

void main() {
  final pubspec = _read('pubspec.yaml');
  final versionMatch =
      RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$', multiLine: true)
          .firstMatch(pubspec);
  final versionName = versionMatch?.group(1);
  final fullVersion =
      versionMatch == null ? null : '$versionName+${versionMatch.group(2)}';

  group('app version', () {
    test('pubspec.yaml has a semver version with build number', () {
      expect(versionMatch, isNotNull,
          reason: 'pubspec.yaml needs `version: X.Y.Z+N`');
    });

    test('AppVersion fallback matches pubspec.yaml', () {
      final src = _read('lib/app_version.dart');
      final fallback =
          RegExp(r"_version\s*=\s*'([^']+)'").firstMatch(src)?.group(1);
      expect(fallback, fullVersion,
          reason: 'Update the fallback in lib/app_version.dart');
    });

    test('CHANGELOG.md starts with an entry for the pubspec version', () {
      final firstHeading = RegExp(r'^#+ .*$', multiLine: true)
          .firstMatch(_read('CHANGELOG.md'))
          ?.group(0);
      expect(firstHeading, isNotNull, reason: 'CHANGELOG.md has no headings');
      final heading = RegExp(r'^### v(\d+\.\d+\.\d+) - \S')
          .firstMatch(firstHeading!)
          ?.group(1);
      expect(heading, versionName,
          reason: 'The first heading in CHANGELOG.md must be '
              '"### v$versionName - Title" (found "$firstHeading")');
    });

    test('CHANGELOG.md version headings are unique', () {
      final versions = RegExp(r'^#+ v(\d+\.\d+\.\d+)\b', multiLine: true)
          .allMatches(_read('CHANGELOG.md'))
          .map((m) => m.group(1)!)
          .toList();
      expect(versions.toSet().length, versions.length,
          reason: 'Duplicate CHANGELOG headings: $versions');
    });

    test('Info.plist takes its version from the Flutter build', () {
      final plist = _read('ios/Runner/Info.plist');
      expect(plist, contains(r'<string>$(FLUTTER_BUILD_NAME)</string>'));
      expect(plist, contains(r'<string>$(FLUTTER_BUILD_NUMBER)</string>'));
    });

    test('docs do not hardcode an app version', () {
      // Versions belong in CHANGELOG.md only; anything else drifts.
      final pattern = RegExp(r'\bv?\d+\.\d+\.\d+\+\d+\b');
      for (final doc in _docs()) {
        final hit = pattern.firstMatch(_read(doc))?.group(0);
        expect(hit, isNull, reason: '$doc hardcodes the version string $hit');
      }
    });
  });

  group('CI (codemagic.yaml)', () {
    final codemagic = _read('codemagic.yaml');

    test('runs the test suite and analyzer, so this guard gates releases', () {
      expect(codemagic, matches(RegExp(r'^\s*flutter test\b', multiLine: true)),
          reason: 'codemagic.yaml must run `flutter test`');
      expect(codemagic,
          matches(RegExp(r'^\s*flutter analyze\b', multiLine: true)),
          reason: 'codemagic.yaml must run `flutter analyze`');
    });

    test('does not override the pubspec version at build time', () {
      // DEVELOPMENT.md documents pubspec.yaml as the only version source.
      expect(codemagic, isNot(contains('--build-name')));
      expect(codemagic, isNot(contains('--build-number')));
    });
  });

  test('iOS deployment target agrees across project, Podfile, framework', () {
    final pbx = _read('ios/Runner.xcodeproj/project.pbxproj');
    final targets = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);')
        .allMatches(pbx)
        .map((m) => m.group(1)!)
        .toSet();
    expect(targets, hasLength(1), reason: 'pbxproj targets differ: $targets');
    final target = targets.single;

    final podfile = RegExp(r"^platform :ios, '([\d.]+)'", multiLine: true)
        .firstMatch(_read('ios/Podfile'))
        ?.group(1);
    expect(podfile, target, reason: 'ios/Podfile platform');

    final framework =
        RegExp(r'<key>MinimumOSVersion</key>\s*<string>([\d.]+)</string>')
            .firstMatch(_read('ios/Flutter/AppFrameworkInfo.plist'))
            ?.group(1);
    expect(framework, target, reason: 'AppFrameworkInfo.plist');

    final major = target.split('.').first;
    final readme = _read('README.md');
    expect(readme, contains('iOS $major'),
        reason: 'README.md requirements should state iOS $major+');
  });

  test('pubspec asset entries exist', () {
    final parts =
        pubspec.split(RegExp(r'^\s+assets:\s*$', multiLine: true));
    expect(parts, hasLength(2), reason: 'expected one flutter assets list');
    // The list runs until the next top-level key.
    final block = parts[1].split(RegExp(r'^\S', multiLine: true)).first;
    final entries = RegExp(r'^\s+-\s+(\S+)\s*$', multiLine: true)
        .allMatches(block)
        .map((m) => m.group(1)!)
        .toList();
    expect(entries, isNotEmpty);
    for (final entry in entries) {
      final exists = entry.endsWith('/')
          ? Directory(entry).existsSync()
          : File(entry).existsSync();
      expect(exists, isTrue, reason: 'pubspec asset missing: $entry');
    }
  });

  group('docs', () {
    test('relative links and images resolve', () {
      final link = RegExp(r'''\]\(([^)\s]+)(?:\s+"[^"]*")?\)|src="([^"]+)"''');
      for (final doc in _docs()) {
        final base = File(doc).parent.path;
        for (final m in link.allMatches(_read(doc))) {
          final target = (m.group(1) ?? m.group(2))!.split('#').first;
          if (target.isEmpty ||
              target.contains('://') ||
              target.startsWith('mailto:')) {
            continue;
          }
          expect(_exists('$base/$target'), isTrue,
              reason: '$doc links to missing $target');
        }
      }
    });

    test('backticked repo paths exist', () {
      // e.g. `lib/services/download_service.dart`, `ios/Runner/Info.plist`.
      // Skips globs and placeholders.
      final path = RegExp(
          r'`((?:lib|ios|test|assets|docs|scripts|screenshots)/[^`\s]*)`');
      for (final doc in _docs()) {
        for (final m in path.allMatches(_read(doc))) {
          final target = m.group(1)!;
          if (RegExp(r'[*<>{}…]|X\.Y\.Z').hasMatch(target)) continue;
          expect(_exists(target), isTrue,
              reason: '$doc references missing path $target');
        }
      }
    });

    test('every screenshot is referenced from README.md', () {
      final readme = _read('README.md');
      for (final file in Directory('screenshots').listSync().whereType<File>()) {
        final name = file.uri.pathSegments.last;
        if (name.startsWith('.')) continue;
        expect(readme, contains('screenshots/$name'),
            reason: 'Unused screenshot $name: reference it or delete it');
      }
    });

    test('no removed platforms or features are documented', () {
      // Nautune is iOS-only; these were removed in 9.0. CHANGELOG.md is
      // history and is exempt.
      const removed = [
        'AppImage',
        'Flatpak',
        'fastforge',
        'PulseAudio',
        'MPRIS',
        'TUI',
        'Helm',
        'SyncPlay',
        'Fleet Mode',
        'Collab',
        'Rewind',
        'Android Auto',
        'flutter run -d linux',
        'flutter build linux',
      ];
      for (final doc in _docs()) {
        final text = _read(doc);
        for (final term in removed) {
          final hit = RegExp('\\b${RegExp.escape(term)}\\b').hasMatch(text);
          expect(hit, isFalse, reason: '$doc mentions removed "$term"');
        }
      }
    });

    test('the platform folders stay removed', () {
      for (final dir in ['android', 'linux', 'macos', 'windows', 'web']) {
        expect(Directory(dir).existsSync(), isFalse,
            reason: '$dir/ is back; Nautune is iOS-only (update the docs '
                'and this test if that is intentional)');
      }
    });
  });

  test('the bundled Jellyfin spec referenced by the docs exists', () {
    final dev = _read('DEVELOPMENT.md');
    final spec = RegExp(r'docs/jellyfin-openapi-[\d.]+\.json')
        .firstMatch(dev)
        ?.group(0);
    expect(spec, isNotNull,
        reason: 'DEVELOPMENT.md should point at the bundled OpenAPI spec');
    expect(File(spec!).existsSync(), isTrue, reason: '$spec is missing');
  });
}
