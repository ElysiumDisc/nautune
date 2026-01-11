import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';

class PlaylistDetailScreen extends StatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlist,
  });

  final JellyfinPlaylist playlist;

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  bool _isLoading = false;
  Object? _error;
  List<JellyfinTrack>? _tracks;
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get appState with listening enabled
    final currentAppState = Provider.of<NautuneAppState>(context, listen: true);

    if (!_hasInitialized) {
      _appState = currentAppState;
      _previousOfflineMode = currentAppState.isOfflineMode;
      _previousNetworkAvailable = currentAppState.networkAvailable;
      _hasInitialized = true;
      _loadTracks();
    } else {
      _appState = currentAppState;
      final currentOfflineMode = currentAppState.isOfflineMode;
      final currentNetworkAvailable = currentAppState.networkAvailable;

      if (_previousOfflineMode != currentOfflineMode ||
          _previousNetworkAvailable != currentNetworkAvailable) {
        debugPrint('🔄 PlaylistDetail: Connectivity changed');
        _previousOfflineMode = currentOfflineMode;
        _previousNetworkAvailable = currentNetworkAvailable;
        _loadTracks();
      }
    }
  }

  Future<void> _loadTracks() async {
    if (_appState == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final tracks = await _appState!.getPlaylistTracks(widget.playlist.id);
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

  void _onReorder(int oldIndex, int newIndex) async {
    if (_tracks == null) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = _tracks!.removeAt(oldIndex);
    _tracks!.insert(newIndex, item);
    setState(() {}); // Optimistic update

    try {
      await _appState!.jellyfinService.movePlaylistItem(
        playlistId: widget.playlist.id,
        itemId: item.id,
        newIndex: newIndex,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reorder: $e')),
        );
        _loadTracks(); // Revert
      }
    }
  }

  Future<void> _downloadPlaylist() async {
    if (_tracks == null || _tracks!.isEmpty) return;
    
    final count = _tracks!.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Checking $count tracks for download...')),
    );

    int started = 0;
    // Copy list to avoid concurrent modification issues
    final tracksToDownload = List<JellyfinTrack>.from(_tracks!);
    
    for (final track in tracksToDownload) {
      if (!mounted) break;
      try {
        final downloadService = _appState!.downloadService;
        final existing = downloadService.getDownload(track.id);
        
        if (existing == null || existing.isFailed) {
           await downloadService.downloadTrack(track);
           started++;
        }
      } catch (_) {
        // Ignore individual failures
      }
    }
    
    if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(started > 0 
            ? 'Queued $started new downloads' 
            : 'All tracks already downloaded or queued'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _removeTrack(String trackId) async {
    try {
      await _appState!.jellyfinService.removeItemsFromPlaylist(
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
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Download Playlist',
            onPressed: _downloadPlaylist,
          ),
          IconButton(
            icon: const Icon(Icons.shuffle),
            tooltip: 'Shuffle',
            onPressed: () {
              if (_tracks != null && _tracks!.isNotEmpty) {
                _appState!.audioService.playShuffled(_tracks!);
              }
            },
          ),
          PopupMenuButton(
            itemBuilder: (context) => [
              PopupMenuItem(
                child: const ListTile(
                  leading: Icon(Icons.edit),
                  title: Text('Rename'),
                  contentPadding: EdgeInsets.zero,
                ),
                onTap: () => Future.delayed(Duration.zero, _showRenameDialog),
              ),
              PopupMenuItem(
                child: const ListTile(
                  leading: Icon(Icons.delete, color: Colors.red),
                  title: Text('Delete', style: TextStyle(color: Colors.red)),
                  contentPadding: EdgeInsets.zero,
                ),
                onTap: () => Future.delayed(Duration.zero, _showDeleteDialog),
              ),
            ],
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
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _tracks!.length,
                      onReorder: _onReorder,
                      itemBuilder: (context, index) {
                        final track = _tracks![index];
                        final duration = track.duration;
                        final durationText = duration != null ? _formatDuration(duration) : '--:--';

                        return ListTile(
                          key: ValueKey(track.id), // Important for ReorderableListView
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: (track.primaryImageTag != null || track.albumPrimaryImageTag != null)
                                  ? JellyfinImage(
                                      itemId: track.primaryImageTag != null ? track.id : (track.albumId ?? track.id),
                                      imageTag: track.primaryImageTag ?? track.albumPrimaryImageTag ?? '',
                                      trackId: track.id,
                                      boxFit: BoxFit.cover,
                                      errorBuilder: (context, url, error) => Container(
                                        color: theme.colorScheme.secondaryContainer,
                                        child: Center(
                                          child: Text('${index + 1}', style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      color: theme.colorScheme.secondaryContainer,
                                      child: Center(
                                        child: Text('${index + 1}', style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
                                      ),
                                    ),
                            ),
                          ),
                          title: Text(
                            track.name,
                            style: TextStyle(color: theme.colorScheme.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.displayArtist,
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                durationText,
                                style: theme.textTheme.bodySmall,
                              ),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => _removeTrack(track.id),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.drag_handle, color: Colors.grey),
                            ],
                          ),
                          onTap: () async {
                            try {
                              await _appState!.audioPlayerService.playTrack(
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
        audioService: _appState!.audioPlayerService,
        appState: _appState!,
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
        await _appState!.updatePlaylist(
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
        await _appState!.deletePlaylist(widget.playlist.id);
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