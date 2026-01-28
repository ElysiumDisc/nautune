import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../jellyfin/jellyfin_album.dart';
import '../../jellyfin/jellyfin_artist.dart';
import '../../jellyfin/jellyfin_track.dart';
import '../tui_theme.dart';
import '../widgets/tui_box.dart';
import '../widgets/tui_list.dart';
import 'tui_sidebar.dart';

/// The main content pane showing albums, artists, tracks, or queue.
class TuiContentPane extends StatelessWidget {
  const TuiContentPane({
    super.key,
    required this.section,
    required this.focused,
    required this.albumListState,
    required this.artistListState,
    required this.trackListState,
    required this.queueListState,
    required this.onAlbumSelected,
    required this.onArtistSelected,
    required this.onTrackSelected,
    required this.onQueueTrackSelected,
    required this.selectedAlbum,
    required this.selectedArtist,
    this.searchQuery = '',
  });

  final TuiSidebarItem section;
  final bool focused;
  final TuiListState<JellyfinAlbum> albumListState;
  final TuiListState<JellyfinArtist> artistListState;
  final TuiListState<JellyfinTrack> trackListState;
  final TuiListState<JellyfinTrack> queueListState;
  final ValueChanged<JellyfinAlbum> onAlbumSelected;
  final ValueChanged<JellyfinArtist> onArtistSelected;
  final ValueChanged<JellyfinTrack> onTrackSelected;
  final ValueChanged<JellyfinTrack> onQueueTrackSelected;
  final JellyfinAlbum? selectedAlbum;
  final JellyfinArtist? selectedArtist;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<NautuneAppState>();
    final audioService = appState.audioPlayerService;

    return StreamBuilder<JellyfinTrack?>(
      stream: audioService.currentTrackStream,
      builder: (context, currentTrackSnapshot) {
        final currentTrack = currentTrackSnapshot.data;

        return TuiBox(
          title: _getTitle(),
          focused: focused,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: _buildContent(context, currentTrack),
          ),
        );
      },
    );
  }

  String _getTitle() {
    switch (section) {
      case TuiSidebarItem.albums:
        if (selectedAlbum != null) {
          return 'Tracks: ${selectedAlbum!.name}';
        }
        return 'Albums';
      case TuiSidebarItem.artists:
        if (selectedArtist != null) {
          return 'Albums: ${selectedArtist!.name}';
        }
        return 'Artists';
      case TuiSidebarItem.queue:
        return 'Queue';
      case TuiSidebarItem.search:
        return searchQuery.isEmpty ? 'Search' : 'Search: $searchQuery';
    }
  }

  Widget _buildContent(BuildContext context, JellyfinTrack? currentTrack) {
    switch (section) {
      case TuiSidebarItem.albums:
        if (selectedAlbum != null) {
          return _buildTrackList(context, currentTrack);
        }
        return _buildAlbumList(context);

      case TuiSidebarItem.artists:
        if (selectedArtist != null) {
          return _buildAlbumList(context);
        }
        return _buildArtistList(context);

      case TuiSidebarItem.queue:
        return _buildQueueList(context, currentTrack);

      case TuiSidebarItem.search:
        return _buildSearchContent(context, currentTrack);
    }
  }

  Widget _buildAlbumList(BuildContext context) {
    return TuiList<JellyfinAlbum>(
      state: albumListState,
      emptyMessage: 'No albums found',
      itemBuilder: (context, album, index, isSelected, isPlaying) {
        return TuiListItem(
          text: album.name,
          isSelected: isSelected,
          suffix: album.productionYear?.toString(),
          onTap: () => onAlbumSelected(album),
        );
      },
    );
  }

  Widget _buildArtistList(BuildContext context) {
    return TuiList<JellyfinArtist>(
      state: artistListState,
      emptyMessage: 'No artists found',
      itemBuilder: (context, artist, index, isSelected, isPlaying) {
        return TuiListItem(
          text: artist.name,
          isSelected: isSelected,
          suffix: artist.albumCount != null ? '${artist.albumCount} albums' : null,
          onTap: () => onArtistSelected(artist),
        );
      },
    );
  }

  Widget _buildTrackList(BuildContext context, JellyfinTrack? currentTrack) {
    int? playingIndex;
    if (currentTrack != null) {
      final tracks = trackListState.items;
      for (int i = 0; i < tracks.length; i++) {
        if (tracks[i].id == currentTrack.id) {
          playingIndex = i;
          break;
        }
      }
    }

    return TuiList<JellyfinTrack>(
      state: trackListState,
      emptyMessage: 'No tracks',
      playingIndex: playingIndex,
      itemBuilder: (context, track, index, isSelected, isPlaying) {
        final trackNum = track.indexNumber?.toString().padLeft(2, ' ') ?? '  ';
        final duration = _formatDuration(track.duration);

        return TuiListItem(
          text: '$trackNum. ${track.name}',
          isSelected: isSelected,
          isPlaying: isPlaying,
          suffix: duration,
          onTap: () => onTrackSelected(track),
        );
      },
    );
  }

  Widget _buildQueueList(BuildContext context, JellyfinTrack? currentTrack) {
    int? playingIndex;
    if (currentTrack != null) {
      final queue = queueListState.items;
      for (int i = 0; i < queue.length; i++) {
        if (queue[i].id == currentTrack.id) {
          playingIndex = i;
          break;
        }
      }
    }

    return TuiList<JellyfinTrack>(
      state: queueListState,
      emptyMessage: 'Queue is empty',
      playingIndex: playingIndex,
      itemBuilder: (context, track, index, isSelected, isPlaying) {
        final duration = _formatDuration(track.duration);

        return TuiListItem(
          text: track.name,
          isSelected: isSelected,
          isPlaying: isPlaying,
          suffix: '${track.displayArtist} $duration',
          onTap: () => onQueueTrackSelected(track),
        );
      },
    );
  }

  Widget _buildSearchContent(BuildContext context, JellyfinTrack? currentTrack) {
    if (searchQuery.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Press / to search', style: TuiTextStyles.dim),
            const SizedBox(height: 8),
            Text('Type your query and press Enter', style: TuiTextStyles.dim),
          ],
        ),
      );
    }

    // For search, we show tracks from trackListState
    int? playingIndex;
    if (currentTrack != null) {
      final tracks = trackListState.items;
      for (int i = 0; i < tracks.length; i++) {
        if (tracks[i].id == currentTrack.id) {
          playingIndex = i;
          break;
        }
      }
    }

    return TuiList<JellyfinTrack>(
      state: trackListState,
      emptyMessage: 'No results for "$searchQuery"',
      playingIndex: playingIndex,
      itemBuilder: (context, track, index, isSelected, isPlaying) {
        final duration = _formatDuration(track.duration);

        return TuiListItem(
          text: track.name,
          isSelected: isSelected,
          isPlaying: isPlaying,
          suffix: '${track.displayArtist} $duration',
          onTap: () => onTrackSelected(track),
        );
      },
    );
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60);
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }
}
