import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

/// Shows a dialog to add tracks/albums to playlists
Future<void> showAddToPlaylistDialog({
  required BuildContext context,
  required NautuneAppState appState,
  List<JellyfinTrack>? tracks,
  JellyfinAlbum? album,
}) async {
  
  // If album provided, get its tracks
  List<String>? itemIds;
  if (tracks != null) {
    itemIds = tracks.map((t) => t.id).toList();
  } else if (album != null) {
    // Get album tracks (need to implement in appState)
    final albumTracks = await appState.getAlbumTracks(album.id);
    itemIds = albumTracks.map((t) => t.id).toList();
  }

  if (itemIds == null || itemIds.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tracks to add')),
      );
    }
    return;
  }

  if (!context.mounted) return;

  final playlists = appState.playlists ?? [];

  await showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Add to Playlist'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Create new playlist option
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create New Playlist'),
              onTap: () async {
                Navigator.pop(context);
                await _createPlaylistWithItems(context, appState, itemIds!);
              },
            ),
            const Divider(),
            // Existing playlists
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('No playlists yet'),
              )
            else
              ...playlists.map((playlist) {
                return ListTile(
                  leading: const Icon(Icons.playlist_play),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.trackCount} tracks'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _addToExistingPlaylist(
                      context,
                      appState,
                      playlist,
                      itemIds!,
                    );
                  },
                );
              }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

Future<void> _createPlaylistWithItems(
  BuildContext context,
  NautuneAppState appState,
  List<String> itemIds,
) async {
  final nameController = TextEditingController();

  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New Playlist Name'),
      content: TextField(
        controller: nameController,
        decoration: const InputDecoration(
          labelText: 'Playlist Name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Create'),
        ),
      ],
    ),
  );

  if (result == true && nameController.text.isNotEmpty && context.mounted) {
    try {
      await appState.createPlaylist(
        name: nameController.text,
        itemIds: itemIds,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Created "${nameController.text}" with ${itemIds.length} tracks'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        final isOfflineError = e.toString().contains('Offline') || 
                               e.toString().contains('queued');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isOfflineError 
                ? 'Offline: Playlist will be created when online'
                : 'Failed to create playlist: $e'
            ),
            backgroundColor: isOfflineError ? Colors.orange : Colors.red,
          ),
        );
      }
    }
  }
}

Future<void> _addToExistingPlaylist(
  BuildContext context,
  NautuneAppState appState,
  JellyfinPlaylist playlist,
  List<String> itemIds,
) async {

  try {
    await appState.addToPlaylist(
      playlistId: playlist.id,
      itemIds: itemIds,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added ${itemIds.length} tracks to "${playlist.name}"'),
          backgroundColor: Colors.green,
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      final isOfflineError = e.toString().contains('Offline') || 
                             e.toString().contains('queued');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isOfflineError 
              ? 'Offline: Tracks will be added when online'
              : 'Failed to add to playlist: $e'
          ),
          backgroundColor: isOfflineError ? Colors.orange : Colors.red,
        ),
      );
    }
  }
}
