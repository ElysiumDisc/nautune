import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../providers/syncplay_provider.dart';
import '../services/haptic_service.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/track_info_sheet.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';

/// Shows a modal bottom sheet with common track actions.
///
/// Used across library_screen, album_detail_screen, artist_detail_screen,
/// and recently_played_screen to avoid duplicating context menu code.
void showTrackContextMenu({
  required BuildContext context,
  required JellyfinTrack track,
  required NautuneAppState appState,
  bool showGoToArtist = true,
  bool showGoToAlbum = true,
}) {
  HapticService.mediumTap();
  final parentContext = context;

  showModalBottomSheet(
    context: parentContext,
    builder: (sheetContext) {
      final syncPlay = parentContext.read<SyncPlayProvider>();
      return SafeArea(
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
                          style: Theme.of(sheetContext).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (track.artists.isNotEmpty)
                          Text(
                            track.displayArtist,
                            style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                              color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
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
            // Add to Fleet (if session active)
            if (syncPlay.isInSession)
              ListTile(
                leading: Icon(Icons.group_add, color: Theme.of(sheetContext).colorScheme.primary),
                title: Text(
                  'Add to ${syncPlay.groupName ?? "Fleet"}',
                  style: TextStyle(color: Theme.of(sheetContext).colorScheme.primary),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    await syncPlay.addTrackToQueue(track);
                    if (parentContext.mounted) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        SnackBar(content: Text('${track.name} added to fleet')),
                      );
                    }
                  } catch (e) {
                    if (parentContext.mounted) {
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
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
                  final mixTracks = await appState.jellyfinService.getInstantMix(
                    itemId: track.id,
                    limit: 50,
                  );
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
                      content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } catch (e) {
                  if (!parentContext.mounted) return;
                  ScaffoldMessenger.of(parentContext).showSnackBar(
                    SnackBar(
                      content: Text('Failed to create mix: $e'),
                      backgroundColor: Theme.of(parentContext).colorScheme.error,
                    ),
                  );
                }
              },
            ),
            if (showGoToArtist && track.artistIds.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Go to Artist'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  try {
                    // Try cache first for offline support
                    final cachedArtist = appState.artists
                        ?.where((a) => a.id == track.artistIds.first)
                        .firstOrNull;
                    final artist = cachedArtist ??
                        await appState.jellyfinService.getArtist(track.artistIds.first);
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
                    final album = cachedAlbum ??
                        await appState.jellyfinService.getAlbum(track.albumId!);
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
          ],
        ),
      );
    },
  );
}
