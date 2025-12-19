import 'dart:collection';
import '../jellyfin/jellyfin_track.dart';

enum DownloadStatus {
  queued,
  downloading,
  completed,
  failed,
  paused,
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
  final bool isDemoAsset;
  final Set<String> owners;

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
    this.isDemoAsset = false,
    required this.owners,
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
    bool? isDemoAsset,
    Set<String>? owners,
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
      isDemoAsset: isDemoAsset ?? this.isDemoAsset,
      owners: owners ?? this.owners,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'trackId': track.id,
      'trackName': track.name,
      'trackArtist': track.displayArtist,
      'trackAlbum': track.album,
      'runTimeTicks': track.runTimeTicks,
      'trackContainer': track.container,
      'trackCodec': track.codec,
      'trackBitrate': track.bitrate,
      'trackSampleRate': track.sampleRate,
      'trackBitDepth': track.bitDepth,
      'trackChannels': track.channels,
      'localPath': localPath,
      'status': status.name,
      'progress': progress,
      'totalBytes': totalBytes,
      'downloadedBytes': downloadedBytes,
      'queuedAt': queuedAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'errorMessage': errorMessage,
      'isDemoAsset': isDemoAsset,
      'owners': owners.toList(),
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
        isDemoAsset: json['isDemoAsset'] as bool? ?? false,
        owners: HashSet<String>.from(json['owners'] as List? ?? []),
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
