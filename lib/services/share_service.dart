import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../jellyfin/jellyfin_track.dart';
import 'download_service.dart';

/// Result of a share operation
enum ShareResult {
  success,       // User completed sharing
  cancelled,     // User cancelled share sheet
  notDownloaded, // Track not available locally
  fileNotFound,  // File was expected but missing
  error,         // Platform error occurred
}

/// Service for sharing audio files via native platform sharing.
///
/// On iOS: Uses UIActivityViewController (AirDrop, Messages, Mail, Files, etc.)
/// On Linux: Opens file manager showing the file location
class ShareService {
  static ShareService? _instance;
  static ShareService get instance => _instance ??= ShareService._();

  ShareService._();

  static const _methodChannel = MethodChannel('com.nautune.share/methods');

  /// Check if file sharing is available on this platform
  bool get isAvailable => Platform.isIOS || Platform.isLinux || Platform.isMacOS;

  /// Share a track's audio file using the native share sheet.
  ///
  /// Returns [ShareResult] indicating the outcome.
  /// - On iOS: Uses UIActivityViewController (AirDrop, Messages, Mail, etc.)
  /// - On Linux: Opens file manager showing the file location
  Future<ShareResult> shareTrack({
    required JellyfinTrack track,
    required DownloadService downloadService,
  }) async {
    // Check if track is downloaded
    final localPath = await downloadService.getLocalPath(track.id);
    if (localPath == null) {
      debugPrint('ShareService: Track not downloaded: ${track.name}');
      return ShareResult.notDownloaded;
    }

    // Verify file exists (already checked in getLocalPath, but double-check)
    final file = File(localPath);
    if (!await file.exists()) {
      debugPrint('ShareService: File not found: $localPath');
      return ShareResult.fileNotFound;
    }

    debugPrint('ShareService: Sharing "${track.name}" from $localPath');

    if (Platform.isIOS) {
      return _shareIOS(
        filePath: localPath,
        trackName: track.name,
        artistName: track.displayArtist,
      );
    } else if (Platform.isLinux) {
      return _shareLinux(filePath: localPath);
    } else if (Platform.isMacOS) {
      return _shareMacOS(filePath: localPath);
    }

    debugPrint('ShareService: Platform not supported');
    return ShareResult.error;
  }

  /// iOS sharing via UIActivityViewController
  Future<ShareResult> _shareIOS({
    required String filePath,
    required String trackName,
    required String artistName,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<dynamic>('shareFile', {
        'filePath': filePath,
        'trackName': trackName,
        'artistName': artistName,
      });

      if (result == true) {
        debugPrint('ShareService: iOS share completed');
        return ShareResult.success;
      } else if (result == false) {
        debugPrint('ShareService: iOS share cancelled');
        return ShareResult.cancelled;
      } else {
        return ShareResult.error;
      }
    } on PlatformException catch (e) {
      debugPrint('ShareService iOS error: ${e.code} - ${e.message}');
      if (e.code == 'FILE_NOT_FOUND') {
        return ShareResult.fileNotFound;
      }
      return ShareResult.error;
    } catch (e) {
      debugPrint('ShareService iOS error: $e');
      return ShareResult.error;
    }
  }

  /// Linux sharing - opens file manager with file selected
  Future<ShareResult> _shareLinux({required String filePath}) async {
    try {
      final file = File(filePath);

      // Try nautilus with --select to highlight the file
      try {
        final nautilusResult = await Process.run('nautilus', ['--select', filePath]);
        if (nautilusResult.exitCode == 0) {
          debugPrint('ShareService: Opened nautilus with file selected');
          return ShareResult.success;
        }
      } catch (_) {
        // nautilus not available, try alternatives
      }

      // Try dolphin (KDE file manager)
      try {
        final dolphinResult = await Process.run('dolphin', ['--select', filePath]);
        if (dolphinResult.exitCode == 0) {
          debugPrint('ShareService: Opened dolphin with file selected');
          return ShareResult.success;
        }
      } catch (_) {
        // dolphin not available
      }

      // Fallback: open the directory with xdg-open
      final directory = file.parent.path;
      final xdgResult = await Process.run('xdg-open', [directory]);

      if (xdgResult.exitCode == 0) {
        debugPrint('ShareService: Opened directory with xdg-open');
        return ShareResult.success;
      } else {
        debugPrint('ShareService Linux: xdg-open failed with code ${xdgResult.exitCode}');
        return ShareResult.error;
      }
    } catch (e) {
      debugPrint('ShareService Linux error: $e');
      return ShareResult.error;
    }
  }

  /// macOS sharing - reveal file in Finder
  Future<ShareResult> _shareMacOS({required String filePath}) async {
    try {
      // Reveal file in Finder
      final result = await Process.run('open', ['-R', filePath]);

      if (result.exitCode == 0) {
        debugPrint('ShareService: Revealed file in Finder');
        return ShareResult.success;
      } else {
        debugPrint('ShareService macOS: open -R failed');
        return ShareResult.error;
      }
    } catch (e) {
      debugPrint('ShareService macOS error: $e');
      return ShareResult.error;
    }
  }
}
