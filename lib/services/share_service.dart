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
class ShareService {
  static ShareService? _instance;
  static ShareService get instance => _instance ??= ShareService._();

  ShareService._();

  static const _methodChannel = MethodChannel('com.nautune.share/methods');

  /// Check if file sharing is available on this platform
  bool get isAvailable => Platform.isIOS;

  /// Share a track's audio file using the native share sheet.
  ///
  /// Returns [ShareResult] indicating the outcome.
  /// - On iOS: Uses UIActivityViewController (AirDrop, Messages, Mail, etc.)
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
}
