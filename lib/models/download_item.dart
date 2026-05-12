import 'dart:collection';
import '../jellyfin/jellyfin_track.dart';

enum DownloadStatus {
  queued,
  downloading,
  completed,
  failed,
  paused,
}

/// Categorizes a failed download by its root cause. Persisted as the enum
/// index in Hive; do not reorder existing entries — append new kinds.
enum DownloadErrorKind {
  network,      // SocketException, HttpException, TLS, DNS, timeout
  server,       // HTTP 4xx/5xx
  storageFull,  // ENOSPC
  permission,   // Filesystem permission denied
  fileSystem,   // Other FileSystemException
  canceled,     // User canceled or pause/dispose interrupted
  unknown,
}

class DownloadItem {
  final JellyfinTrack track;
  final String localPath;
  final DownloadStatus status;
  final double progress;
  final int? totalBytes;
  final int? downloadedBytes;
  final DateTime queuedAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final DownloadErrorKind? errorKind;
  final bool isDemoAsset;
  final Set<String> owners;
  final int? fileSizeBytes; // Cached file size to avoid repeated file I/O

  DownloadItem({
    required this.track,
    required this.localPath,
    required this.status,
    this.progress = 0.0,
    this.totalBytes,
    this.downloadedBytes,
    required this.queuedAt,
    this.completedAt,
    this.errorMessage,
    this.errorKind,
    this.isDemoAsset = false,
    required this.owners,
    this.fileSizeBytes,
  });

  DownloadItem copyWith({
    JellyfinTrack? track,
    String? localPath,
    DownloadStatus? status,
    double? progress,
    int? totalBytes,
    int? downloadedBytes,
    DateTime? queuedAt,
    DateTime? completedAt,
    String? errorMessage,
    DownloadErrorKind? errorKind,
    bool clearErrorKind = false,
    bool? isDemoAsset,
    Set<String>? owners,
    int? fileSizeBytes,
  }) {
    return DownloadItem(
      track: track ?? this.track,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      queuedAt: queuedAt ?? this.queuedAt,
      completedAt: completedAt ?? this.completedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      errorKind: clearErrorKind ? null : (errorKind ?? this.errorKind),
      isDemoAsset: isDemoAsset ?? this.isDemoAsset,
      owners: owners ?? this.owners,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'trackId': track.id,
      'trackName': track.name,
      'trackArtist': track.displayArtist,
      'trackArtistIds': track.artistIds,
      'trackAlbum': track.album,
      'trackAlbumId': track.albumId,
      'trackAlbumPrimaryImageTag': track.albumPrimaryImageTag,
      'runTimeTicks': track.runTimeTicks,
      'trackContainer': track.container,
      'trackCodec': track.codec,
      'trackBitrate': track.bitrate,
      'trackSampleRate': track.sampleRate,
      'trackBitDepth': track.bitDepth,
      'trackChannels': track.channels,
      'trackProductionYear': track.productionYear,
      'localPath': localPath,
      'status': status.name,
      'progress': progress,
      'totalBytes': totalBytes,
      'downloadedBytes': downloadedBytes,
      'queuedAt': queuedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'errorMessage': errorMessage,
      'errorKind': errorKind?.index,
      'isDemoAsset': isDemoAsset,
      'owners': owners.toList(),
      'fileSizeBytes': fileSizeBytes,
    };
  }

  static DownloadItem? fromJson(Map<String, dynamic> json, JellyfinTrack track) {
    try {
      return DownloadItem(
        track: track,
        localPath: json['localPath'] as String,
        status: DownloadStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => DownloadStatus.queued,
        ),
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        totalBytes: json['totalBytes'] as int?,
        downloadedBytes: json['downloadedBytes'] as int?,
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        completedAt: json['completedAt'] != null
            ? DateTime.parse(json['completedAt'] as String)
            : null,
        errorMessage: json['errorMessage'] as String?,
        errorKind: () {
          final idx = json['errorKind'] as int?;
          if (idx == null || idx < 0 || idx >= DownloadErrorKind.values.length) {
            return null;
          }
          return DownloadErrorKind.values[idx];
        }(),
        isDemoAsset: json['isDemoAsset'] as bool? ?? false,
        owners: HashSet<String>.from(json['owners'] as List? ?? []),
        fileSizeBytes: json['fileSizeBytes'] as int?,
      );
    } catch (e) {
      return null;
    }
  }

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isDownloading => status == DownloadStatus.downloading;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isPaused => status == DownloadStatus.paused;
  bool get isQueued => status == DownloadStatus.queued;
}
