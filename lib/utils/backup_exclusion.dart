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
/// Fail-soft and memoized per path for the app session. The flag lives on
/// the directory itself, so pass [force] after re-creating a directory that
/// was deleted: the memo would otherwise skip the new one.
Future<void> excludeFromBackup(String path, {bool force = false}) async {
  if (!Platform.isIOS) return;
  if (!_excludedPaths.add(path) && !force) return;
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
