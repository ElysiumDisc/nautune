import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

/// What the user picked in the playlist dialog.
sealed class _PlaylistChoice {
  const _PlaylistChoice();
}

class _CreateNew extends _PlaylistChoice {
  const _CreateNew();
}

class _AddTo extends _PlaylistChoice {
  const _AddTo(this.playlist);
  final JellyfinPlaylist playlist;
}

/// Shows a dialog to add tracks (or an album's tracks) to a playlist.
///
/// The returned future completes when the whole flow is done: the playlist
/// picked, a new one named and created, or the dialog cancelled. Callers can
/// therefore tear down their UI (e.g. end a multi-select) after awaiting it
/// without cutting the flow short. Snackbars go to the [ScaffoldMessenger]
/// found at the start, so they still show if [context] is gone by then.
Future<void> showAddToPlaylistDialog({
  required BuildContext context,
  required NautuneAppState appState,
  List<JellyfinTrack>? tracks,
  JellyfinAlbum? album,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);

  List<String>? itemIds;
  if (tracks != null) {
    itemIds = tracks.map((t) => t.id).toList();
  } else if (album != null) {
    try {
      final albumTracks = await appState.getAlbumTracks(album.id);
      itemIds = albumTracks.map((t) => t.id).toList();
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not load the album\'s tracks: $e')),
      );
      return;
    }
  }

  if (itemIds == null || itemIds.isEmpty) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('No tracks to add')),
    );
    return;
  }

  if (!context.mounted) return;

  final playlists = appState.playlists ?? const <JellyfinPlaylist>[];

  final choice = await showDialog<_PlaylistChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add to Playlist'),
      // A fixed width answers the dialog's intrinsic-width query, so the
      // playlist list below can scroll however many playlists there are.
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create New Playlist'),
              onTap: () => Navigator.pop(dialogContext, const _CreateNew()),
            ),
            const Divider(),
            if (playlists.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('No playlists yet'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return ListTile(
                      leading: const Icon(Icons.playlist_play),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${playlist.trackCount} tracks'),
                      onTap: () =>
                          Navigator.pop(dialogContext, _AddTo(playlist)),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  switch (choice) {
    case null:
      return;
    case _CreateNew():
      if (!context.mounted) return;
      final name = await _askPlaylistName(context);
      if (name == null) return;
      await _createPlaylistWithItems(messenger, appState, name, itemIds);
    case _AddTo(:final playlist):
      await _addToExistingPlaylist(messenger, appState, playlist, itemIds);
  }
}

Future<String?> _askPlaylistName(BuildContext context) async {
  final nameController = TextEditingController();
  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final name = nameController.text.trim();
    return result == true && name.isNotEmpty ? name : null;
  } finally {
    nameController.dispose();
  }
}

/// Offline edits are queued by app state, which throws to say so.
bool _isQueuedOffline(Object error) =>
    error.toString().contains('Offline') || error.toString().contains('queued');

Future<void> _createPlaylistWithItems(
  ScaffoldMessengerState? messenger,
  NautuneAppState appState,
  String name,
  List<String> itemIds,
) async {
  try {
    await appState.createPlaylist(name: name, itemIds: itemIds);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Created "$name" with ${itemIds.length} tracks'),
        backgroundColor: Colors.green,
      ),
    );
  } catch (e) {
    final queued = _isQueuedOffline(e);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(queued
            ? 'Offline: Playlist will be created when online'
            : 'Failed to create playlist: $e'),
        backgroundColor: queued ? Colors.orange : Colors.red,
      ),
    );
  }
}

Future<void> _addToExistingPlaylist(
  ScaffoldMessengerState? messenger,
  NautuneAppState appState,
  JellyfinPlaylist playlist,
  List<String> itemIds,
) async {
  try {
    await appState.addToPlaylist(playlistId: playlist.id, itemIds: itemIds);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Added ${itemIds.length} tracks to "${playlist.name}"'),
        backgroundColor: Colors.green,
      ),
    );
  } catch (e) {
    final queued = _isQueuedOffline(e);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(queued
            ? 'Offline: Tracks will be added when online'
            : 'Failed to add to playlist: $e'),
        backgroundColor: queued ? Colors.orange : Colors.red,
      ),
    );
  }
}
