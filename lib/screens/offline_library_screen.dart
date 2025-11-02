import 'package:flutter/material.dart';
import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';

class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key, required this.appState});

  final NautuneAppState appState;

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  bool _showByAlbum = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.offline_bolt, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Offline Library'),
          ],
        ),
      ),
      body: ListenableBuilder(
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
                    color: theme.colorScheme.secondary.withOpacity(0.5),
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
      ),
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
                title: Text(track.name),
                trailing: track.duration != null
                    ? Text(
                        _formatDuration(track.duration!),
                        style: theme.textTheme.bodySmall,
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
                    title: Text(track.name),
                    trailing: track.duration != null
                        ? Text(
                            _formatDuration(track.duration!),
                            style: theme.textTheme.bodySmall,
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
}
