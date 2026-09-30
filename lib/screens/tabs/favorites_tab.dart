part of '../library_screen.dart';

class _FavoritesTab extends StatefulWidget {
  const _FavoritesTab({
    required this.recentTracks,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    required this.onTrackTap,
    required this.appState,
  });

  final List<JellyfinTrack>? recentTracks;
  final bool isLoading;
  final Object? error;
  final Future<void> Function() onRefresh;

  /// Plays the tapped track with the list as shown (sorted) as the queue.
  final void Function(JellyfinTrack track, List<JellyfinTrack> queue) onTrackTap;
  final NautuneAppState appState;

  @override
  State<_FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<_FavoritesTab> {
  // Sorted list, recomputed only when the list or the sort changes.
  List<JellyfinTrack>? _sortedSource;
  FavoritesSort? _sortedBy;
  List<JellyfinTrack> _sorted = const [];

  List<JellyfinTrack> _sortedFor(List<JellyfinTrack> tracks, FavoritesSort sort) {
    if (!identical(tracks, _sortedSource) || sort != _sortedBy) {
      _sortedSource = tracks;
      _sortedBy = sort;
      _sorted = sortFavorites(tracks, sort);
    }
    return _sorted;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recentTracks = widget.recentTracks;
    final error = widget.error;
    final isLoading = widget.isLoading;
    final onRefresh = widget.onRefresh;
    final appState = widget.appState;

    // A failed refresh keeps showing the favorites we have.
    if (error != null && (recentTracks == null || recentTracks.isEmpty)) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            const Text('Failed to load favorites'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (isLoading && (recentTracks == null || recentTracks.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (recentTracks == null || recentTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_outline, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'No favorite tracks',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Mark tracks as favorites to see them here',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final uiState = context.watch<UIStateProvider>();
    final tracks = _sortedFor(recentTracks, uiState.favoritesSort);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        scrollCacheExtent: ScrollCacheExtent.pixels(500), // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: tracks.length + 1,
        itemBuilder: (context, row) {
          if (row == 0) {
            return Align(
              alignment: Alignment.centerRight,
              child: _SortMenuButton<FavoritesSort>(
                current: uiState.favoritesSort,
                options: FavoritesSort.values,
                labelOf: (s) => s.label,
                onSelected: uiState.setFavoritesSort,
              ),
            );
          }
          final index = row - 1;
          final track = tracks[index];
          void showTrackMenu() => showTrackContextMenu(
                context: context,
                track: track,
                appState: appState,
              );
          return TrackSwipeActions(
            track: track,
            appState: appState,
            discriminator: index,
            child: RepaintBoundary(
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onLongPress: showTrackMenu,
                leading: SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: (track.albumId != null && track.albumPrimaryImageTag != null)
                      ? JellyfinImage(
                          itemId: track.albumId!,
                          imageTag: track.albumPrimaryImageTag,
                          trackId: track.id, // Enable offline artwork support
                          albumId: track.albumId,
                          maxWidth: JellyfinImage.listArtwork,
                          boxFit: BoxFit.cover,
                          placeholderBuilder: (context, url) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.album,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          errorBuilder: (context, url, error) => Image.asset(
                            'assets/no_album_art.png',
                            fit: BoxFit.cover,
                          ),
                        )
                      : Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
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
                  if (track.duration != null)
                    Text(
                      _formatDuration(track.duration!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: showTrackMenu,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              onTap: () => widget.onTrackTap(track, tracks),
            ),
          )),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }
}
