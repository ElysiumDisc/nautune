import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native channel (ios/Runner/AppDelegate.swift) that sets
/// `URLResourceValues.isExcludedFromBackup` on a file or directory.
const MethodChannel _fileAttributesChannel =
    MethodChannel('nautune/file_attributes');

final Set<String> _excludedPaths = {};

/// Mark [path] (and, for a directory, its contents) as excluded from
/// iCloud/iTunes backup. Re-downloadable media must not be backed up
/// (App Review guideline 2.23).
///
/// Fail-soft and memoized per path for the app session.
Future<void> excludeFromBackup(String path) async {
  if (!Platform.isIOS || !_excludedPaths.add(path)) return;
  try {
    await _fileAttributesChannel
        .invokeMethod<bool>('excludeFromBackup', {'path': path});
  } on MissingPluginException catch (e) {
    debugPrint('excludeFromBackup unavailable: $e');
  } on PlatformException catch (e) {
    _excludedPaths.remove(path);
    debugPrint('excludeFromBackup failed for $path: $e');
  }
}
