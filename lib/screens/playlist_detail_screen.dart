import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/download_indicators.dart';
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
  int _loadGeneration = 0;

  /// Shown in the app bar; follows renames made here.
  late String _name = widget.playlist.name;

  /// The id the server needs to move/remove this entry: its playlist entry
  /// id where the server sent one (older servers require it), else the item
  /// id (10.11+ accept that).
  static String _entryId(JellyfinTrack track) =>
      track.playlistItemId ?? track.id;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitialized) {
      _appState = Provider.of<NautuneAppState>(context, listen: false);
      _previousOfflineMode = _appState!.isOfflineMode;
      _previousNetworkAvailable = _appState!.networkAvailable;
      _hasInitialized = true;
      _appState!.addListener(_onConnectivityChanged);
      _loadTracks();
    }
  }

  void _onConnectivityChanged() {
    if (!mounted || _appState == null) return;
    final offline = _appState!.isOfflineMode;
    final network = _appState!.networkAvailable;
    if (_previousOfflineMode != offline || _previousNetworkAvailable != network) {
      debugPrint('🔄 PlaylistDetail: Connectivity changed');
      _previousOfflineMode = offline;
      _previousNetworkAvailable = network;
      _loadTracks();
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  Future<void> _loadTracks() async {
    if (_appState == null) return;
    // Overlapping loads (connectivity flapping, reorder reverts): only the
    // latest one lands.
    final generation = ++_loadGeneration;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final tracks = await _appState!.getPlaylistTracks(widget.playlist.id);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  void _onReorder(int oldIndex, int newIndex) async {
    final current = _tracks;
    if (current == null) return;
    // Optimistic update on a copy (a queue may hold the old list).
    final reordered = List<JellyfinTrack>.of(current);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    setState(() => _tracks = reordered);

    try {
      await _appState!.jellyfinService.movePlaylistItem(
        playlistId: widget.playlist.id,
        itemId: _entryId(item),
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

  Future<void> _removeTrack(JellyfinTrack track) async {
    try {
      await _appState!.jellyfinService.removeItemsFromPlaylist(
        playlistId: widget.playlist.id,
        entryIds: [_entryId(track)],
      );
      await _loadTracks(); // Reload
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Track removed from playlist'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove track: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Editing the track list needs the server (rename/delete go through the
    // offline sync queue in app state).
    final isOffline = _appState!.isOfflineMode;

    return Scaffold(
      appBar: AppBar(
        title: Text(_name),
        actions: [
          CollectionDownloadButton(
            style: CollectionDownloadButtonStyle.icon,
            tracks: _tracks ?? const <JellyfinTrack>[],
            ownerId: widget.playlist.id,
            collectionName: widget.playlist.name,
            // Offline the list only holds downloaded tracks.
            onRemoved: () {
              if (isOffline && mounted) _loadTracks();
            },
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
                child: ListTile(
                  leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                  title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
                          Icon(isOffline ? Icons.cloud_off : Icons.music_note, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
                          const SizedBox(height: 16),
                          Text(
                            isOffline ? 'Not available offline' : 'No tracks in this playlist',
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              isOffline
                                  ? 'None of this playlist\'s tracks are downloaded. Download the playlist next time you\'re online.'
                                  : 'Add tracks from albums or search',
                              style: theme.textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _tracks!.length,
                      buildDefaultDragHandles: !isOffline,
                      onReorderItem: _onReorder,
                      itemBuilder: (context, index) {
                        final track = _tracks![index];
                        final duration = track.duration;
                        final durationText = duration != null ? _formatDuration(duration) : '--:--';

                        return ListTile(
                          // Entry ids are unique even when a song is in the
                          // playlist twice.
                          key: ValueKey(track.playlistItemId ?? '${track.id}#$index'),
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
                                      maxWidth: JellyfinImage.listArtwork,
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
                              TrackDownloadIndicator(trackId: track.id),
                              const SizedBox(width: 4),
                              Text(
                                durationText,
                                style: theme.textTheme.bodySmall,
                              ),
                              if (!isOffline) ...[
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline),
                                  tooltip: 'Remove from playlist',
                                  onPressed: () => _removeTrack(track),
                                ),
                                const SizedBox(width: 8),
                                Icon(Icons.drag_handle, color: theme.colorScheme.onSurfaceVariant),
                              ],
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

  /// Offline, app state queues playlist edits and throws to say so.
  static bool _isQueuedOffline(Object error) =>
      error.toString().contains('queued');

  Future<void> _showRenameDialog() async {
    final nameController = TextEditingController(text: _name);
    String? newName;
    try {
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
      final name = nameController.text.trim();
      if (result == true && name.isNotEmpty) newName = name;
    } finally {
      nameController.dispose();
    }
    if (newName == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    try {
      await _appState!.updatePlaylist(
        playlistId: widget.playlist.id,
        newName: newName,
      );
      if (mounted) setState(() => _name = newName!);
      messenger.showSnackBar(SnackBar(content: Text('Renamed to "$newName"')));
    } catch (e) {
      if (_isQueuedOffline(e)) {
        if (mounted) setState(() => _name = newName!);
        messenger.showSnackBar(const SnackBar(
          content: Text('Offline: the rename will sync when you\'re online'),
        ));
      } else {
        messenger.showSnackBar(SnackBar(
          content: Text('Failed to rename: $e'),
          backgroundColor: errorColor,
        ));
      }
    }
  }

  Future<void> _showDeleteDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Are you sure you want to delete "$_name"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    try {
      await _appState!.deletePlaylist(widget.playlist.id);
      if (mounted) navigator.pop(); // Go back to playlist list
      messenger.showSnackBar(SnackBar(content: Text('Deleted "$_name"')));
    } catch (e) {
      if (_isQueuedOffline(e)) {
        if (mounted) navigator.pop();
        messenger.showSnackBar(SnackBar(
          content: Text('Offline: "$_name" will be deleted when you\'re online'),
        ));
      } else {
        messenger.showSnackBar(SnackBar(
          content: Text('Failed to delete: $e'),
          backgroundColor: errorColor,
        ));
      }
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}