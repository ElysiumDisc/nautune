import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key});

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  bool _showByAlbum = true;
  int _currentTab = 0; // 0 = Library, 1 = Downloads Management

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<NautuneAppState>(context, listen: false);

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
        ? _buildOfflineLibrary(context, theme, appState)
        : _buildDownloadsTab(context, theme, appState),
    );
  }

  Widget _buildOfflineLibrary(BuildContext context, ThemeData theme, NautuneAppState appState) {
    return ListenableBuilder(
      listenable: appState.downloadService,
      builder: (context, _) {
        final downloads = appState.downloadService.completedDownloads;

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
            // Storage stats header
            FutureBuilder<int>(
              future: appState.downloadService.getTotalDownloadSize(),
              builder: (context, snapshot) {
                final size = snapshot.data ?? 0;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                    border: Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outlineVariant,
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.storage, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        '${downloads.length} tracks',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '• ${_formatFileSize(size)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pushNamed(context, '/settings');
                        },
                        icon: Icon(Icons.settings, size: 16, color: theme.colorScheme.primary),
                        label: Text('Manage', style: TextStyle(color: theme.colorScheme.primary)),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // View toggle
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
                  ? _buildByAlbum(theme, downloads, appState)
                  : _buildByArtist(theme, downloads, appState),
            ),
          ],
        );
      },
    );
  }

  Widget _buildByAlbum(ThemeData theme, List downloads, NautuneAppState appState) {
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
                  appState.audioPlayerService.playTrack(
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

  Widget _buildByArtist(ThemeData theme, List downloads, NautuneAppState appState) {
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
                      appState.audioPlayerService.playTrack(
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
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildDownloadsTab(BuildContext context, ThemeData theme, NautuneAppState appState) {
    return ListenableBuilder(
      listenable: appState.downloadService,
      builder: (context, _) {
        final downloads = appState.downloadService.downloads;
        final completedCount = appState.downloadService.completedCount;
        final activeCount = appState.downloadService.activeCount;

        return Column(
          children: [
            _buildQuickActions(context, theme, appState),
            if (activeCount > 0 || completedCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                            await appState.downloadService
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
              child: downloads.isEmpty
                  ? Center(
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
                              'Use Quick Downloads above or browse your library to download music.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: downloads.length,
                      itemBuilder: (context, index) {
                        final download = downloads[index];
                        final track = download.track;

                        return ListTile(
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: theme.colorScheme.primaryContainer,
                            ),
                            child: Center(
                              child: download.isCompleted
                                  ? Icon(Icons.check_circle,
                                      color: theme.colorScheme.primary)
                                  : download.isDownloading
                                      ? SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: CircularProgressIndicator(
                                            value: download.progress,
                                            strokeWidth: 3,
                                            color: theme.colorScheme.primary,
                                          ),
                                        )
                                      : download.isFailed
                                          ? Icon(Icons.error,
                                              color: theme.colorScheme.error)
                                          : Icon(Icons.schedule,
                                              color: theme.colorScheme
                                                  .onPrimaryContainer),
                            ),
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
                              appState.downloadService.deleteDownloadReference(
                                  track.id, 'user_initiated_from_downloads_list');
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

  Widget _buildQuickActions(BuildContext context, ThemeData theme, NautuneAppState appState) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.surfaceContainerHighest),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick Downloads',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.favorite, size: 16),
                  label: const Text('Favorites'),
                  onPressed: () => _downloadFavorites(context, appState),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.trending_up, size: 16),
                  label: const Text('Top 20'),
                  onPressed: () => _downloadTopPlayed(context, appState),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: const Text('Recent 20'),
                  onPressed: () => _downloadRecent(context, appState),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadFavorites(BuildContext context, NautuneAppState appState) async {
    if (!appState.networkAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Online connection required')),
      );
      return;
    }

    try {
      final tracks = await appState.jellyfinService.getFavoriteTracks();
      if (!context.mounted) return;
      _queueDownloads(context, appState, tracks, 'favorites');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load favorites: $e')),
        );
      }
    }
  }

  Future<void> _downloadTopPlayed(BuildContext context, NautuneAppState appState) async {
    if (!appState.networkAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Online connection required')),
      );
      return;
    }

    final libraryId = appState.session?.selectedLibraryId;
    if (libraryId == null) return;

    try {
      final tracks = await appState.jellyfinService.getMostPlayedTracks(
        libraryId: libraryId,
        limit: 20,
      );
      if (!context.mounted) return;
      _queueDownloads(context, appState, tracks, 'most played tracks');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load top tracks: $e')),
        );
      }
    }
  }

  Future<void> _downloadRecent(BuildContext context, NautuneAppState appState) async {
    if (!appState.networkAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Online connection required')),
      );
      return;
    }

    final libraryId = appState.session?.selectedLibraryId;
    if (libraryId == null) return;

    try {
      final tracks = await appState.jellyfinService.loadRecentTracks(
        libraryId: libraryId,
        limit: 20,
        forceRefresh: true,
      );
      if (!context.mounted) return;
      _queueDownloads(context, appState, tracks, 'recent tracks');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load recent tracks: $e')),
        );
      }
    }
  }

  void _queueDownloads(
    BuildContext context,
    NautuneAppState appState,
    List<JellyfinTrack> tracks,
    String label,
  ) {
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No $label found')),
      );
      return;
    }

    int count = 0;
    for (final track in tracks) {
      if (!appState.downloadService.isDownloaded(track.id)) {
        appState.downloadService.downloadTrack(track);
        count++;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(count > 0 ? 'Queued $count new $label' : 'All $label already downloaded')),
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
