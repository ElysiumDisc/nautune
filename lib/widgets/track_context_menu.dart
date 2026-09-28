import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../services/haptic_service.dart';
import '../services/share_service.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/track_info_sheet.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';

/// Shows a modal bottom sheet with common track actions.
///
/// The single track menu for the app: album, artist, favorites,
/// recently-played and the full player all go through here so the actions
/// (and their snackbars/error handling) stay identical everywhere.
///
/// [extraActionsBuilder] appends screen-specific tiles (e.g. the full
/// player's lyrics / Infinite Radio / A-B loop toggles) after the shared
/// track actions. Tiles it returns should pop `sheetContext` themselves.
void showTrackContextMenu({
  required BuildContext context,
  required JellyfinTrack track,
  required NautuneAppState appState,
  bool showGoToArtist = true,
  bool showGoToAlbum = true,
  bool showDownload = true,
  bool showShare = true,
  bool showTrackInfo = true,
  List<Widget> Function(BuildContext sheetContext)? extraActionsBuilder,
}) {
  HapticService.mediumTap();
  final parentContext = context;
  final isOffline = appState.isOfflineMode;
  final download = appState.downloadService.getDownload(track.id);

  showModalBottomSheet(
    context: parentContext,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Track header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.name,
                            style: Theme.of(sheetContext).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (track.artists.isNotEmpty)
                            Text(
                              track.displayArtist,
                              style: Theme.of(sheetContext).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      sheetContext,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Play Next'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  appState.audioPlayerService.playNext([track]);
                  ScaffoldMessenger.of(parentContext).showSnackBar(
                    SnackBar(
                      content: Text('${track.name} will play next'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to Queue'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  appState.audioPlayerService.addToQueue([track]);
                  ScaffoldMessenger.of(parentContext).showSnackBar(
                    SnackBar(
                      content: Text('${track.name} added to queue'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Add to Playlist'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await showAddToPlaylistDialog(
                    context: parentContext,
                    appState: appState,
                    tracks: [track],
                  );
                },
              ),
              // Instant Mix needs the server.
              if (!isOffline)
              ListTile(
                leading: const Icon(Icons.auto_awesome),
                title: const Text('Instant Mix'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      const SnackBar(
                        content: Text('Creating instant mix...'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                    final mixTracks = await appState.jellyfinService
                        .getInstantMix(itemId: track.id, limit: 50);
                    if (!parentContext.mounted) return;
                    if (mixTracks.isEmpty) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(
                          content: Text('No similar tracks found'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }
                    await appState.audioPlayerService.playTrack(
                      mixTracks.first,
                      queueContext: mixTracks,
                    );
                    if (!parentContext.mounted) return;
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Playing instant mix (${mixTracks.length} tracks)',
                        ),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  } catch (e) {
                    if (!parentContext.mounted) return;
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      SnackBar(
                        content: Text('Failed to create mix: $e'),
                        backgroundColor: Theme.of(
                          parentContext,
                        ).colorScheme.error,
                      ),
                    );
                  }
                },
              ),
              if (showDownload)
                _downloadTile(
                  sheetContext: sheetContext,
                  parentContext: parentContext,
                  appState: appState,
                  track: track,
                  download: download,
                ),
              if (showShare)
                ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('Share'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _shareTrack(parentContext, appState, track);
                  },
                ),
              if (showGoToArtist && track.artistIds.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person),
                  title: const Text('Go to Artist'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (track.artistIds.isEmpty) return;
                    final artistId = track.artistIds.first;
                    try {
                      // Try cache first for offline support
                      final cachedArtist = appState.artists
                          ?.where((a) => a.id == artistId)
                          .firstOrNull;
                      // Offline: the artist screen builds itself from
                      // downloads, so id + name are enough.
                      final artist =
                          cachedArtist ??
                          (isOffline
                              ? JellyfinArtist(
                                  id: artistId,
                                  name: track.artists.isNotEmpty
                                      ? track.artists.first
                                      : track.displayArtist,
                                )
                              : await appState.jellyfinService
                                  .getArtist(artistId));
                      if (!parentContext.mounted) return;
                      Navigator.of(parentContext).push(
                        MaterialPageRoute(
                          builder: (_) => ArtistDetailScreen(artist: artist),
                        ),
                      );
                    } catch (e) {
                      if (!parentContext.mounted) return;
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        SnackBar(content: Text('Could not load artist: $e')),
                      );
                    }
                  },
                ),
              if (showGoToAlbum && track.albumId != null)
                ListTile(
                  leading: const Icon(Icons.album),
                  title: const Text('Go to Album'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      // Try cache first for offline support
                      final cachedAlbum = appState.albums
                          ?.where((a) => a.id == track.albumId)
                          .firstOrNull;
                      // Offline: the album screen lists the downloaded tracks.
                      final album =
                          cachedAlbum ??
                          (isOffline
                              ? JellyfinAlbum(
                                  id: track.albumId!,
                                  name: track.album ?? 'Unknown Album',
                                  artists: [track.displayArtist],
                                  artistIds: track.artistIds,
                                  productionYear: track.productionYear,
                                  primaryImageTag: track.albumPrimaryImageTag,
                                )
                              : await appState.jellyfinService.getAlbum(
                                  track.albumId!,
                                ));
                      if (!parentContext.mounted) return;
                      Navigator.of(parentContext).push(
                        MaterialPageRoute(
                          builder: (_) => AlbumDetailScreen(album: album),
                        ),
                      );
                    } catch (e) {
                      if (!parentContext.mounted) return;
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        SnackBar(content: Text('Could not load album: $e')),
                      );
                    }
                  },
                ),
              if (showTrackInfo)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Track Info'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showModalBottomSheet(
                      context: parentContext,
                      isScrollControlled: true,
                      builder: (_) => TrackInfoSheet(track: track),
                    );
                  },
                ),
              if (extraActionsBuilder != null)
                ...extraActionsBuilder(sheetContext),
            ],
          ),
        ),
      );
    },
  );
}

/// The download entry of the track menu, reflecting the current state:
/// Download / Cancel download / Retry download / Remove download.
Widget _downloadTile({
  required BuildContext sheetContext,
  required BuildContext parentContext,
  required NautuneAppState appState,
  required JellyfinTrack track,
  required DownloadItem? download,
}) {
  final service = appState.downloadService;
  final messenger = ScaffoldMessenger.of(parentContext);
  final colors = Theme.of(sheetContext).colorScheme;

  void showMessage(String text) => messenger.showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );

  switch (download?.status) {
    case DownloadStatus.completed:
      return ListTile(
        leading: Icon(Icons.download_done, color: colors.primary),
        title: const Text('Remove Download'),
        subtitle: const Text('Downloaded for offline listening'),
        onTap: () async {
          Navigator.pop(sheetContext);
          await service.deleteDownload(track.id);
          showMessage('Removed "${track.name}" from downloads');
        },
      );
    case DownloadStatus.queued:
    case DownloadStatus.downloading:
    case DownloadStatus.paused:
      final progress = download!.isDownloading && download.progress > 0
          ? ' (${(download.progress * 100).toStringAsFixed(0)}%)'
          : '';
      return ListTile(
        leading: const Icon(Icons.cancel_outlined),
        title: const Text('Cancel Download'),
        subtitle: Text(download.isDownloading
            ? 'Downloading$progress'
            : 'Queued for download'),
        onTap: () async {
          Navigator.pop(sheetContext);
          await service.cancelDownload(track.id);
          showMessage('Download cancelled');
        },
      );
    case DownloadStatus.failed:
      return ListTile(
        leading: Icon(Icons.refresh, color: colors.error),
        title: const Text('Retry Download'),
        subtitle: const Text('The last download attempt failed'),
        onTap: () async {
          Navigator.pop(sheetContext);
          if (appState.isOfflineMode) {
            showMessage('You are offline. Connect to the internet to download.');
            return;
          }
          await service.retryDownload(track.id);
          showMessage('Retrying download of "${track.name}"');
        },
      );
    case null:
      return ListTile(
        leading: const Icon(Icons.download_outlined),
        title: const Text('Download'),
        onTap: () async {
          Navigator.pop(sheetContext);
          if (appState.isOfflineMode) {
            showMessage('You are offline. Connect to the internet to download.');
            return;
          }
          try {
            await service.downloadTrack(track);
            final waitsForWifi =
                service.wifiOnlyDownloads && await service.isOnCellular();
            showMessage(waitsForWifi
                ? 'Queued "${track.name}". Downloads start on Wi-Fi'
                : 'Downloading "${track.name}"');
          } catch (e) {
            messenger.showSnackBar(
              SnackBar(
                content: Text('Could not download "${track.name}"'),
                backgroundColor: colors.error,
              ),
            );
          }
        },
      );
  }
}

Future<void> _shareTrack(
  BuildContext parentContext,
  NautuneAppState appState,
  JellyfinTrack track,
) async {
  final messenger = ScaffoldMessenger.of(parentContext);
  final theme = Theme.of(parentContext);
  final downloadService = appState.downloadService;
  final shareService = ShareService.instance;

  if (!shareService.isAvailable) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Sharing not available on this platform'),
        duration: Duration(seconds: 2),
      ),
    );
    return;
  }

  final result = await shareService.shareTrack(
    track: track,
    downloadService: downloadService,
  );

  if (!parentContext.mounted) return;

  switch (result) {
    case ShareResult.success:
      messenger.showSnackBar(
        SnackBar(
          content: Text('Shared "${track.name}"'),
          duration: const Duration(seconds: 2),
        ),
      );
    case ShareResult.cancelled:
      break;
    case ShareResult.notDownloaded:
      final shouldDownload = await showDialog<bool>(
        context: parentContext,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Track Not Downloaded'),
          content: Text(
            'To share "${track.name}", it needs to be downloaded first. '
            'Would you like to download it now?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (shouldDownload == true && parentContext.mounted) {
        await downloadService.downloadTrack(track);
        messenger.showSnackBar(
          SnackBar(
            content: Text('Downloading "${track.name}"...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    case ShareResult.fileNotFound:
      messenger.showSnackBar(
        SnackBar(
          content: Text('File for "${track.name}" not found'),
          backgroundColor: theme.colorScheme.error,
          duration: const Duration(seconds: 3),
        ),
      );
    case ShareResult.error:
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to share "${track.name}"'),
          backgroundColor: theme.colorScheme.error,
          duration: const Duration(seconds: 3),
        ),
      );
  }
}
