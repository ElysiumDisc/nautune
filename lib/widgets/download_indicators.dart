import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../services/download_service.dart';
import '../theme/nautune_spacing.dart';
import '../utils/download_format.dart';
import '../utils/download_status.dart';

/// Collections at least this long ask for confirmation (with a size
/// estimate) before downloading.
const int kConfirmDownloadTrackCount = 25;

/// On cellular data (with Wi-Fi-only off), downloads estimated above this
/// size ask for confirmation first.
const int kConfirmCellularDownloadBytes = 100 * 1024 * 1024;

DownloadService _serviceOf(BuildContext context) =>
    Provider.of<NautuneAppState>(context, listen: false).downloadService;

/// Small per-track download state: nothing when not downloaded, a check
/// when downloaded, a progress ring while downloading, a clock when queued
/// and an error icon when the download failed.
class TrackDownloadIndicator extends StatelessWidget {
  const TrackDownloadIndicator({
    super.key,
    required this.trackId,
    this.size = 16,
  });

  final String trackId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final service = _serviceOf(context);
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final item = service.getDownload(trackId);
        if (item == null) return const SizedBox.shrink();
        final Widget icon;
        final String label;
        switch (item.status) {
          case DownloadStatus.completed:
            icon = Icon(Icons.download_done, size: size, color: colors.primary);
            label = 'Downloaded';
          case DownloadStatus.downloading:
            icon = SizedBox(
              width: size - 2,
              height: size - 2,
              child: CircularProgressIndicator(
                value: item.progress >= 0 ? item.progress : null,
                strokeWidth: 2,
                color: colors.primary,
              ),
            );
            label = 'Downloading';
          case DownloadStatus.queued:
          case DownloadStatus.paused:
            icon = Icon(Icons.schedule, size: size, color: colors.onSurfaceVariant);
            label = 'Queued for download';
          case DownloadStatus.failed:
            icon = Icon(Icons.error_outline, size: size, color: colors.error);
            label = 'Download failed';
        }
        return Semantics(
          label: label,
          child: Tooltip(
            message: label,
            child: SizedBox.square(
              dimension: size,
              child: Center(child: icon),
            ),
          ),
        );
      },
    );
  }
}

/// Visual form of [CollectionDownloadButton].
enum CollectionDownloadButtonStyle {
  /// Outlined button with a label (album header).
  outlined,

  /// Icon button (app bars).
  icon,
}

/// Download control for a whole album / playlist / artist. Shows the
/// aggregate state and does the obvious thing on tap: download (asking
/// first for big collections), show progress with a cancel option, retry
/// failures, or remove the downloads.
class CollectionDownloadButton extends StatelessWidget {
  const CollectionDownloadButton({
    super.key,
    required this.tracks,
    required this.ownerId,
    required this.collectionName,
    this.style = CollectionDownloadButtonStyle.outlined,
    this.iconColor,
    this.circleBackground,
    this.onRemoved,
  });

  final List<JellyfinTrack> tracks;

  /// Album / playlist / artist id recorded as the downloads' owner.
  final String ownerId;

  /// Shown in dialogs and snackbars ("Download “Blue”?").
  final String collectionName;
  final CollectionDownloadButtonStyle style;
  final Color? iconColor;

  /// Icon style only: draw the icon on a filled circle (for app bars over
  /// artwork, matching the neighbouring buttons).
  final Color? circleBackground;

  /// Called after the user removed the collection's downloads (e.g. so an
  /// offline screen can drop tracks that are no longer playable).
  final VoidCallback? onRemoved;

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final service = appState.downloadService;
    final ids = [for (final t in tracks) t.id];
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final summary = service.summaryFor(ids);
        final state = summary.state;
        final String label;
        final String tooltip;
        final Widget icon;
        final colors = Theme.of(context).colorScheme;
        switch (state) {
          case CollectionDownloadState.none:
            label = 'Download';
            tooltip = 'Download for offline listening';
            icon = const Icon(Icons.download_outlined);
          case CollectionDownloadState.partial:
            label = 'Download ${summary.remaining} more';
            tooltip = '${summary.completed} of ${summary.total} downloaded. '
                'Download the rest';
            icon = const Icon(Icons.download_outlined);
          case CollectionDownloadState.failed:
            label = 'Retry ${summary.failed} failed';
            tooltip = '${summary.failed} downloads failed. Tap to retry';
            icon = Icon(Icons.error_outline, color: colors.error);
          case CollectionDownloadState.downloading:
            label = 'Downloading ${summary.completed}/${summary.total}';
            tooltip = 'Downloading ${summary.completed} of ${summary.total}. '
                'Tap to cancel';
            icon = SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                value: summary.progress > 0 ? summary.progress : null,
                strokeWidth: 2.5,
              ),
            );
          case CollectionDownloadState.complete:
            label = 'Downloaded';
            tooltip = 'Downloaded. Tap to remove from this device';
            icon = Icon(Icons.download_done, color: colors.primary);
        }

        final enabled = tracks.isNotEmpty;
        void onPressed() => _handleTap(context, appState, summary);

        if (style == CollectionDownloadButtonStyle.icon) {
          Widget content = IconTheme.merge(
            data: IconThemeData(
              color: iconColor,
              size: circleBackground != null ? 20 : null,
            ),
            child: icon,
          );
          if (circleBackground != null) {
            content = Container(
              padding: const EdgeInsets.all(NautuneSpacing.sm),
              decoration: BoxDecoration(
                color: circleBackground,
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(dimension: 20, child: Center(child: content)),
            );
          }
          return IconButton(
            icon: content,
            tooltip: tooltip,
            onPressed: enabled ? onPressed : null,
          );
        }
        return Tooltip(
          message: tooltip,
          child: OutlinedButton.icon(
            onPressed: enabled ? onPressed : null,
            icon: icon,
            label: Text(label),
          ),
        );
      },
    );
  }

  Future<void> _handleTap(
    BuildContext context,
    NautuneAppState appState,
    CollectionDownloadSummary summary,
  ) async {
    final service = appState.downloadService;
    final messenger = ScaffoldMessenger.of(context);
    final ids = [for (final t in tracks) t.id];

    switch (summary.state) {
      case CollectionDownloadState.downloading:
        final cancel = await _confirm(
          context,
          title: 'Downloading “$collectionName”',
          message: '${summary.completed} of ${summary.total} tracks downloaded, '
              '${summary.active} still in the queue.',
          confirmLabel: 'Cancel downloads',
          cancelLabel: 'Keep downloading',
          destructive: true,
        );
        if (cancel != true) return;
        final active = [
          for (final id in ids)
            if (service.getDownload(id) case final d?
                when d.isQueued || d.isDownloading || d.isPaused)
              id,
        ];
        final n = await service.deleteDownloads(active);
        messenger.showSnackBar(
          SnackBar(content: Text('Cancelled $n downloads')),
        );

      case CollectionDownloadState.complete:
        final bytes = [
          for (final id in ids) service.getDownload(id),
        ].fold<int>(0, (sum, d) => sum + (d?.fileSizeBytes ?? d?.totalBytes ?? 0));
        if (!context.mounted) return;
        final remove = await _confirm(
          context,
          title: 'Remove downloads?',
          message: 'Removes ${summary.total} downloaded tracks '
              '(${formatDownloadBytes(bytes)}) of “$collectionName” from this '
              'device. You can download them again any time.',
          confirmLabel: 'Remove',
          destructive: true,
        );
        if (remove != true) return;
        await service.deleteDownloads(ids);
        messenger.showSnackBar(
          SnackBar(content: Text('Removed downloads of “$collectionName”')),
        );
        onRemoved?.call();

      case CollectionDownloadState.failed:
        if (appState.isOfflineMode) {
          _showOfflineMessage(messenger);
          return;
        }
        final n = service.retryDownloads(ids);
        messenger.showSnackBar(
          SnackBar(content: Text('Retrying $n downloads')),
        );

      case CollectionDownloadState.none:
      case CollectionDownloadState.partial:
        if (appState.isOfflineMode) {
          _showOfflineMessage(messenger);
          return;
        }
        final toDownload = [
          for (final t in tracks)
            if (!(service.getDownload(t.id)?.isCompleted ?? false)) t,
        ];
        if (toDownload.isEmpty) return;
        final onCellular = await service.isOnCellular();
        if (!context.mounted) return;
        final estimate = _estimateBytes(toDownload);
        final bigOnCellular = onCellular &&
            !service.wifiOnlyDownloads &&
            (estimate ?? 0) > kConfirmCellularDownloadBytes;
        if (toDownload.length >= kConfirmDownloadTrackCount || bigOnCellular) {
          final parts = <String>[
            '${toDownload.length} tracks'
                '${estimate != null ? ', about ${formatDownloadBytes(estimate)}' : ''}.',
            if (onCellular && !service.wifiOnlyDownloads)
              'You are on cellular data.',
            if (onCellular && service.wifiOnlyDownloads)
              'Downloads will start when you are on Wi-Fi.',
          ];
          final ok = await _confirm(
            context,
            title: 'Download “$collectionName”?',
            message: parts.join(' '),
            confirmLabel: 'Download',
          );
          if (ok != true) return;
        }
        // Pass every track: already-downloaded ones gain this collection as
        // an owner (so e.g. the playlist lists them offline); the rest queue.
        final queued = await service.downloadTracks(tracks, ownerId: ownerId);
        final waitingForWifi = service.wifiOnlyDownloads && onCellular;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              queued == 0
                  ? 'Already downloading'
                  : waitingForWifi
                      ? 'Queued $queued tracks. Downloads start on Wi-Fi'
                      : 'Downloading $queued tracks',
            ),
          ),
        );
    }
  }

  static int? _estimateBytes(List<JellyfinTrack> tracks) {
    var total = 0;
    var known = 0;
    for (final t in tracks) {
      final bytes = DownloadFormat.estimateBytes(
        bitrate: t.bitrate,
        runTimeTicks: t.runTimeTicks,
      );
      if (bytes != null) {
        total += bytes;
        known++;
      }
    }
    if (known == 0) return null;
    // Extrapolate to tracks without bitrate metadata.
    return (total / known * tracks.length).round();
  }
}

void _showOfflineMessage(ScaffoldMessengerState messenger) {
  messenger.showSnackBar(
    const SnackBar(
      content: Text('You are offline. Connect to the internet to download.'),
    ),
  );
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colors = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}

/// Explains a paused queue (waiting for Wi-Fi / network, storage) and lists
/// failed downloads with Retry all / Clear actions. Renders nothing when
/// everything is fine.
class DownloadQueueBanner extends StatelessWidget {
  const DownloadQueueBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = _serviceOf(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final pause = service.queuePause;
        final pauseText =
            service.activeCount > 0 ? describeQueuePause(pause) : null;
        final failed = service.failedCount;
        final incompatible = service.incompatibleDownloads.length;
        if (pauseText == null && failed == 0 && incompatible == 0) {
          return const SizedBox.shrink();
        }

        final isError = pause == DownloadQueuePause.storageFull ||
            (pauseText == null && failed > 0);
        final background = isError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.secondaryContainer;
        final foreground = isError
            ? theme.colorScheme.onErrorContainer
            : theme.colorScheme.onSecondaryContainer;

        final lines = <String>[
          ?pauseText,
          if (failed > 0) '$failed ${failed == 1 ? 'download' : 'downloads'} failed.',
          if (incompatible > 0)
            '$incompatible downloaded ${incompatible == 1 ? 'track is' : 'tracks are'} '
                'in a format iPhone can’t play offline.',
        ];

        return Container(
          width: double.infinity,
          color: background,
          padding: const EdgeInsets.fromLTRB(
            NautuneSpacing.lg,
            NautuneSpacing.md,
            NautuneSpacing.sm,
            NautuneSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (pause) {
                      DownloadQueuePause.waitingForWifi => Icons.wifi_off,
                      DownloadQueuePause.waitingForNetwork => Icons.cloud_off,
                      DownloadQueuePause.storageFull ||
                      DownloadQueuePause.storageLimit =>
                        Icons.sd_card_alert_outlined,
                      DownloadQueuePause.none => Icons.error_outline,
                    },
                    size: 20,
                    color: foreground,
                  ),
                  const SizedBox(width: NautuneSpacing.md),
                  Expanded(
                    child: Text(
                      lines.join('\n'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: NautuneSpacing.xs,
                children: [
                  if (failed > 0) ...[
                    TextButton(
                      onPressed: () => service.clearFailed(),
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      child: const Text('Dismiss failed'),
                    ),
                    TextButton(
                      onPressed: () => service.retryAllFailed(),
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      child: const Text('Retry all'),
                    ),
                  ],
                  if (incompatible > 0)
                    TextButton(
                      onPressed: () async {
                        final n = await service.redownloadIncompatible();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Re-downloading $n tracks')),
                        );
                      },
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      child: const Text('Re-download'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One row of a downloads list: status, progress and the relevant action
/// (cancel while queued/downloading, retry or dismiss when failed, delete
/// when downloaded).
class DownloadItemTile extends StatelessWidget {
  const DownloadItemTile({
    super.key,
    required this.item,
    required this.queuePause,
    this.onPlay,
  });

  final DownloadItem item;
  final DownloadQueuePause queuePause;

  /// Called when a completed download is tapped.
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final service = _serviceOf(context);
    final track = item.track;

    final Widget status;
    final String detail;
    Color? detailColor;
    switch (item.status) {
      case DownloadStatus.completed:
        status = Icon(Icons.download_done, color: colors.primary);
        final bytes = item.fileSizeBytes ?? item.totalBytes;
        detail = bytes != null ? formatDownloadBytes(bytes) : 'Downloaded';
      case DownloadStatus.downloading:
        final indeterminate = item.progress < 0;
        status = SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(
            value: indeterminate ? null : item.progress,
            strokeWidth: 3,
            color: colors.primary,
          ),
        );
        final done = formatDownloadBytes(item.downloadedBytes ?? 0);
        final total = item.totalBytes ?? 0;
        detail = indeterminate || total <= 0
            ? 'Downloading… $done'
            : '${(item.progress * 100).toStringAsFixed(0)}% • $done / '
                '${formatDownloadBytes(total)}';
        detailColor = colors.primary;
      case DownloadStatus.queued:
      case DownloadStatus.paused:
        status = Icon(Icons.schedule, color: colors.onSurfaceVariant);
        detail = switch (queuePause) {
          DownloadQueuePause.waitingForWifi => 'Waiting for Wi-Fi',
          DownloadQueuePause.waitingForNetwork => 'Waiting for connection',
          DownloadQueuePause.storageFull => 'Paused: storage full',
          DownloadQueuePause.storageLimit => 'Paused: storage limit reached',
          DownloadQueuePause.none =>
            item.errorKind == DownloadErrorKind.network
                ? 'Queued to retry'
                : 'Queued',
        };
      case DownloadStatus.failed:
        status = Icon(Icons.error_outline, color: colors.error);
        detail = '${describeDownloadError(item.errorKind)} • Tap to retry';
        detailColor = colors.error;
    }

    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: NautuneRadius.allSm,
          color: colors.primaryContainer.withValues(alpha: 0.6),
        ),
        child: Center(child: status),
      ),
      title: Text(
        track.name,
        style: TextStyle(color: colors.tertiary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            track.displayArtist,
            style: TextStyle(color: colors.tertiary.withValues(alpha: 0.7)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(color: detailColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: switch (item.status) {
        DownloadStatus.completed => IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove download',
            onPressed: () async {
              final ok = await _confirm(
                context,
                title: 'Remove download?',
                message: 'Remove “${track.name}” from this device?',
                confirmLabel: 'Remove',
                destructive: true,
              );
              if (ok == true) await service.deleteDownload(track.id);
            },
          ),
        DownloadStatus.failed => IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            onPressed: () => service.cancelDownload(track.id),
          ),
        _ => IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel download',
            onPressed: () => service.cancelDownload(track.id),
          ),
      },
      onTap: switch (item.status) {
        DownloadStatus.completed => onPlay,
        DownloadStatus.failed => () => service.retryDownload(track.id),
        _ => null,
      },
    );
  }
}
