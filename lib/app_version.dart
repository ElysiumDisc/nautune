import 'package:package_info_plus/package_info_plus.dart';

/// Centralized app version management.
/// Initialize once at app startup, then use everywhere.
class AppVersion {
  static String _version = '6.8.0+1'; // Fallback, updated at runtime

  /// The current app version string (e.g., "5.5.6+1")
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
