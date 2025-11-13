import 'package:flutter/material.dart';
import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({
    super.key, 
    required this.appState,
  });

  final NautuneAppState appState;

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  bool _showByAlbum = true;
  int _currentTab = 0; // 0 = Library, 1 = Downloads Management

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              _currentTab == 0 ? Icons.library_music : Icons.download,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(_currentTab == 0 ? 'Offline Library' : 'Download Manager'),
          ],
        ),
        actions: [
          // Toggle between library view and download management
          IconButton(
            icon: Icon(_currentTab == 0 ? Icons.manage_accounts : Icons.library_music),
            tooltip: _currentTab == 0 ? 'Manage Downloads' : 'View Library',
            onPressed: () {
              setState(() {
                _currentTab = _currentTab == 0 ? 1 : 0;
              });
            },
          ),
        ],
      ),
      body: _currentTab == 0 
        ? _buildOfflineLibrary(context, theme)
        : _buildDownloadsTab(context, theme),
    );
  }

  Widget _buildOfflineLibrary(BuildContext context, ThemeData theme) {
    return ListenableBuilder(
      listenable: widget.appState.downloadService,
      builder: (context, _) {
        final downloads = widget.appState.downloadService.completedDownloads;

        if (downloads.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 64,
                  color: theme.colorScheme.secondary.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Offline Content',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Download albums to listen offline',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: true,
                          label: Text('By Album'),
                          icon: Icon(Icons.album, size: 18),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text('By Artist'),
                          icon: Icon(Icons.person, size: 18),
                        ),
                      ],
                      selected: {_showByAlbum},
                      onSelectionChanged: (Set<bool> newSelection) {
                        setState(() {
                          _showByAlbum = newSelection.first;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _showByAlbum
                  ? _buildByAlbum(theme, downloads)
                  : _buildByArtist(theme, downloads),
            ),
          ],
        );
      },
    );
  }

  Widget _buildByAlbum(ThemeData theme, List downloads) {
    // Group by album
    final Map<String, List> albumGroups = {};
    for (final download in downloads) {
      final albumName = download.track.album ?? 'Unknown Album';
      if (!albumGroups.containsKey(albumName)) {
        albumGroups[albumName] = [];
      }
      albumGroups[albumName]!.add(download);
    }

    final sortedAlbums = albumGroups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedAlbums.length,
      itemBuilder: (context, index) {
        final albumName = sortedAlbums[index];
        final albumDownloads = albumGroups[albumName]!;
        final artistName = albumDownloads.first.track.displayArtist;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            leading: Icon(Icons.album, color: theme.colorScheme.primary),
            title: Text(albumName),
            subtitle: Text('$artistName • ${albumDownloads.length} tracks'),
            children: albumDownloads.map((download) {
              final track = download.track;
              return ListTile(
                dense: true,
                leading: Text(
                  '${track.indexNumber ?? 0}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                title: Text(
                  track.name,
                  style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
                ),
                trailing: track.duration != null
                    ? Text(
                        _formatDuration(track.duration!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                        ),
                      )
                    : null,
                onTap: () {
                  // Play from local file
                  final tracks = albumDownloads
                      .map((d) => d.track as JellyfinTrack)
                      .toList();
                  widget.appState.audioPlayerService.playTrack(
                    track,
                    queueContext: tracks,
                  );
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _buildByArtist(ThemeData theme, List downloads) {
    // Group by artist
    final Map<String, List> artistGroups = {};
    for (final download in downloads) {
      final artistName = download.track.displayArtist;
      if (!artistGroups.containsKey(artistName)) {
        artistGroups[artistName] = [];
      }
      artistGroups[artistName]!.add(download);
    }

    final sortedArtists = artistGroups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedArtists.length,
      itemBuilder: (context, index) {
        final artistName = sortedArtists[index];
        final artistDownloads = artistGroups[artistName]!;

        // Group artist's tracks by album
        final Map<String, List> albumsForArtist = {};
        for (final download in artistDownloads) {
          final albumName = download.track.album ?? 'Unknown Album';
          if (!albumsForArtist.containsKey(albumName)) {
            albumsForArtist[albumName] = [];
          }
          albumsForArtist[albumName]!.add(download);
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            leading: Icon(Icons.person, color: theme.colorScheme.primary),
            title: Text(artistName),
            subtitle: Text(
                '${albumsForArtist.length} albums • ${artistDownloads.length} tracks'),
            children: albumsForArtist.entries.map((entry) {
              final albumName = entry.key;
              final tracks = entry.value;
              return ExpansionTile(
                dense: true,
                title: Text(albumName),
                subtitle: Text('${tracks.length} tracks'),
                children: tracks.map((download) {
                  final track = download.track;
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.only(left: 72, right: 16),
                    leading: Text(
                      '${track.indexNumber ?? 0}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      track.name,
                      style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
                    ),
                    trailing: track.duration != null
                        ? Text(
                            _formatDuration(track.duration!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                            ),
                          )
                        : null,
                    onTap: () {
                      final allTracks = tracks
                          .map((d) => d.track as JellyfinTrack)
                          .toList();
                      widget.appState.audioPlayerService.playTrack(
                        track,
                        queueContext: allTracks,
                      );
                    },
                  );
                }).toList(),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildDownloadsTab(BuildContext context, ThemeData theme) {
    return ListenableBuilder(
      listenable: widget.appState.downloadService,
      builder: (context, _) {
        final downloads = widget.appState.downloadService.downloads;
        final completedCount = widget.appState.downloadService.completedCount;
        final activeCount = widget.appState.downloadService.activeCount;

        if (downloads.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.download_outlined,
                    size: 64, color: theme.colorScheme.secondary),
                const SizedBox(height: 16),
                Text('No Downloads', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Download albums and tracks for offline listening',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            if (activeCount > 0 || completedCount > 0)
              Container(
                padding: const EdgeInsets.all(16),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '$completedCount completed • $activeCount active',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (completedCount > 0)
                      TextButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Clear All Downloads'),
                              content: Text(
                                  'Delete all $completedCount downloaded tracks?'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('Delete All'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await widget.appState.downloadService
                                .clearAllDownloads();
                          }
                        },
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Clear All'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: downloads.length,
                itemBuilder: (context, index) {
                  final download = downloads[index];
                  final track = download.track;

                  return ListTile(
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: theme.colorScheme.primaryContainer,
                      ),
                      child: download.isCompleted
                          ? Icon(Icons.check_circle,
                              color: theme.colorScheme.primary)
                          : download.isDownloading
                              ? CircularProgressIndicator(
                                  value: download.progress,
                                  strokeWidth: 3,
                                )
                              : download.isFailed
                                  ? Icon(Icons.error,
                                      color: theme.colorScheme.error)
                                  : Icon(Icons.schedule,
                                      color: theme.colorScheme
                                          .onPrimaryContainer),
                    ),
                    title: Text(
                      track.name,
                      style: TextStyle(color: theme.colorScheme.tertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.displayArtist,
                          style: TextStyle(
                              color: theme.colorScheme.tertiary
                                  .withValues(alpha: 0.7)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (download.isDownloading)
                          Text(
                            '${(download.progress * 100).toStringAsFixed(0)}% • ${_formatFileSize(download.downloadedBytes ?? 0)} / ${_formatFileSize(download.totalBytes ?? 0)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          )
                        else if (download.isCompleted &&
                            download.totalBytes != null)
                          Text(
                            _formatFileSize(download.totalBytes!),
                            style: theme.textTheme.bodySmall,
                          )
                        else if (download.isFailed)
                          Text(
                            'Download failed',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          )
                        else
                          Text(
                            'Queued',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        widget.appState.downloadService.deleteDownload(track.id);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
