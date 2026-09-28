import '../models/download_item.dart';

/// Why the download queue is not currently making progress.
enum DownloadQueuePause {
  /// Running normally (or idle).
  none,

  /// Wi-Fi-only downloads is on and the device is on cellular data.
  waitingForWifi,

  /// The last attempt failed with a network error (or there is no network);
  /// retried automatically when connectivity returns or after a backoff.
  waitingForNetwork,

  /// The device ran out of space. Needs a user retry after freeing space.
  storageFull,

  /// The user's download storage limit has been reached.
  storageLimit,
}

/// Human-readable, actionable explanation for a paused queue, or null when
/// the queue is running.
String? describeQueuePause(DownloadQueuePause pause) {
  switch (pause) {
    case DownloadQueuePause.none:
      return null;
    case DownloadQueuePause.waitingForWifi:
      return 'Waiting for Wi-Fi. Downloads resume automatically '
          '(Wi-Fi-only downloads is on).';
    case DownloadQueuePause.waitingForNetwork:
      return 'Waiting for a connection. Downloads resume automatically.';
    case DownloadQueuePause.storageFull:
      return 'Your device is out of storage. Free up space, then tap Retry.';
    case DownloadQueuePause.storageLimit:
      return 'Download storage limit reached. Raise the limit in Settings '
          'or remove some downloads.';
  }
}

/// Delay before the [attempt]-th (1-based) automatic retry of the download
/// queue after network failures: 5s, 10s, 20s, 40s, 80s, then 2 min.
Duration networkRetryDelay(int attempt) {
  final exp = (attempt - 1).clamp(0, 5);
  final seconds = 5 * (1 << exp);
  return Duration(seconds: seconds > 120 ? 120 : seconds);
}

/// Short user-facing reason for a failed download.
String describeDownloadError(DownloadErrorKind? kind) {
  switch (kind) {
    case DownloadErrorKind.network:
      return 'Connection problem';
    case DownloadErrorKind.server:
      return 'Server error';
    case DownloadErrorKind.storageFull:
      return 'Not enough storage';
    case DownloadErrorKind.permission:
      return 'Storage permission denied';
    case DownloadErrorKind.fileSystem:
      return 'Could not save file';
    case DownloadErrorKind.canceled:
      return 'Cancelled';
    case DownloadErrorKind.unknown:
    case null:
      return 'Download failed';
  }
}

/// Human-readable byte count (B / KB / MB / GB).
String formatDownloadBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Overall download state of a group of tracks (album, playlist, artist).
enum CollectionDownloadState {
  /// No track of the collection is downloaded or queued.
  none,

  /// Some tracks are downloaded, nothing is in progress or failed.
  partial,

  /// At least one track is queued or downloading.
  downloading,

  /// Nothing in progress, but some tracks failed.
  failed,

  /// Every track is downloaded.
  complete,
}

/// Aggregate download status for a collection of tracks.
class CollectionDownloadSummary {
  const CollectionDownloadSummary({
    required this.total,
    required this.completed,
    required this.downloading,
    required this.queued,
    required this.failed,
    required this.progress,
  });

  /// Summarise [items], one entry per track in the collection (null = the
  /// track has no download record).
  factory CollectionDownloadSummary.fromItems(Iterable<DownloadItem?> items) {
    var total = 0;
    var completed = 0;
    var downloading = 0;
    var queued = 0;
    var failed = 0;
    var progressSum = 0.0;
    for (final item in items) {
      total++;
      if (item == null) continue;
      switch (item.status) {
        case DownloadStatus.completed:
          completed++;
          progressSum += 1.0;
        case DownloadStatus.downloading:
          downloading++;
          final p = item.progress;
          if (p > 0) progressSum += p.clamp(0.0, 1.0);
        case DownloadStatus.queued:
        case DownloadStatus.paused:
          queued++;
        case DownloadStatus.failed:
          failed++;
      }
    }
    return CollectionDownloadSummary(
      total: total,
      completed: completed,
      downloading: downloading,
      queued: queued,
      failed: failed,
      progress: total == 0 ? 0.0 : progressSum / total,
    );
  }

  final int total;
  final int completed;
  final int downloading;
  final int queued;
  final int failed;

  /// 0.0–1.0 across the whole collection (completed tracks count as 1).
  final double progress;

  /// Tracks queued or transferring.
  int get active => downloading + queued;

  /// Tracks with no download record, or whose download failed.
  int get remaining => total - completed - active;

  CollectionDownloadState get state {
    if (total == 0) return CollectionDownloadState.none;
    if (active > 0) return CollectionDownloadState.downloading;
    if (completed == total) return CollectionDownloadState.complete;
    if (failed > 0) return CollectionDownloadState.failed;
    if (completed > 0) return CollectionDownloadState.partial;
    return CollectionDownloadState.none;
  }
}
