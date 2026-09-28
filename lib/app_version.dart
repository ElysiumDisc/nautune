import 'package:package_info_plus/package_info_plus.dart';

/// Centralized app version management.
/// Initialize once at app startup, then use everywhere.
class AppVersion {
  /// Fallback used until [init] reads the real value (or if it fails).
  /// Must equal pubspec.yaml `version:`; enforced by
  /// test/unit/repo_consistency_test.dart.
  static String _version = '9.1.0+1';

  /// The current app version string, `name+build` (e.g. "1.2.3+4").
  static String get current => _version;

  /// Initialize from package info. Call once at app startup.
  static Future<void> init() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _version = '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      // Keep fallback version if PackageInfo fails
    }
  }
}
