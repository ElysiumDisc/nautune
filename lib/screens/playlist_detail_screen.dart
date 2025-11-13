import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/now_playing_bar.dart';

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.appState,
  });

  final JellyfinPlaylist playlist;
  final NautuneAppState appState;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  bool _isLoading = false;
  Object? _error;
  List<JellyfinTrack>? _tracks;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final tracks = await widget.appState.getPlaylistTracks(widget.playlist.id);
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _removeTrack(String trackId) async {
    try {
      // Note: We need the entryId, not trackId, but for now we'll use trackId
      // In a full implementation, tracks should include their playlist entry IDs
      await widget.appState.jellyfinService.removeItemsFromPlaylist(
        playlistId: widget.playlist.id,
        entryIds: [trackId],
      );
      await _loadTracks(); // Reload
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Track removed from playlist'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove track: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist.name),
        actions: [
          // Shuffle button
          IconButton(
            icon: const Text(
              '🌊🌊',
              style: TextStyle(fontSize: 20),
            ),
            onPressed: () {
              if (_tracks != null && _tracks!.isNotEmpty) {
                widget.appState.audioService.playShuffled(_tracks!);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => _showRenameDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _showDeleteDialog(),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
                      const SizedBox(height: 16),
                      Text('Error loading playlist', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text('$_error', style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _loadTracks,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _tracks == null || _tracks!.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.music_note, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
                          const SizedBox(height: 16),
                          Text('No tracks in this playlist', style: theme.textTheme.titleLarge),
                          const SizedBox(height: 8),
                          Text('Add tracks from albums or search', style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _tracks!.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final track = _tracks![index];
                        final duration = track.duration;
                        final durationText = duration != null ? _formatDuration(duration) : '--:--';

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.secondaryContainer,
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
                            ),
                          ),
                          title: Text(
                            track.name,
                            style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
                          ),
                          subtitle: Text(
                            track.displayArtist,
                            style: TextStyle(color: theme.colorScheme.tertiary.withValues(alpha: 0.7)),  // Ocean blue
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                durationText,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => _removeTrack(track.id),
                              ),
                            ],
                          ),
                          onTap: () async {
                            try {
                              await widget.appState.audioPlayerService.playTrack(
                                track,
                                queueContext: _tracks,
                                albumId: track.albumId,
                                albumName: widget.playlist.name,
                              );
                            } catch (error) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Could not start playback: $error'),
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                        );
                      },
                    ),
      bottomNavigationBar: NowPlayingBar(
        audioService: widget.appState.audioPlayerService,
        appState: widget.appState,
      ),
    );
  }

  Future<void> _showRenameDialog() async {
    final nameController = TextEditingController(text: widget.playlist.name);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Playlist'),
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
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty && mounted) {
      try {
        await widget.appState.updatePlaylist(
          playlistId: widget.playlist.id,
          newName: nameController.text,
        );
        if (mounted) {
          setState(() {
            // Update local name
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Renamed to "${nameController.text}"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to rename: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _showDeleteDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Are you sure you want to delete "${widget.playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true && mounted) {
      try {
        await widget.appState.deletePlaylist(widget.playlist.id);
        if (mounted) {
          Navigator.pop(context); // Go back to playlist list
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "${widget.playlist.name}"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
