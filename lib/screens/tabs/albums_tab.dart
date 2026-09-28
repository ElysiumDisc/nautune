part of '../library_screen.dart';

class _SortControls extends StatelessWidget {
  const _SortControls({
    required this.appState,
    required this.isAlbums,
  });

  final NautuneAppState appState;
  final bool isAlbums;

  String _sortOptionLabel(SortOption option) {
    switch (option) {
      case SortOption.name:
        return 'Name';
      case SortOption.dateAdded:
        return 'Date Added';
      case SortOption.year:
        return 'Year';
      case SortOption.playCount:
        return 'Play Count';
    }
  }

  IconData _sortOptionIcon(SortOption option) {
    switch (option) {
      case SortOption.name:
        return Icons.sort_by_alpha;
      case SortOption.dateAdded:
        return Icons.calendar_today;
      case SortOption.year:
        return Icons.date_range;
      case SortOption.playCount:
        return Icons.play_circle_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentSort = isAlbums ? appState.albumSortBy : appState.artistSortBy;
    final currentOrder = isAlbums ? appState.albumSortOrder : appState.artistSortOrder;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Sort by dropdown - icon only
        PopupMenuButton<SortOption>(
          initialValue: currentSort,
          tooltip: 'Sort by ${_sortOptionLabel(currentSort)}',
          onSelected: (SortOption option) {
            if (isAlbums) {
              appState.setAlbumSort(option, currentOrder);
            } else {
              appState.setArtistSort(option, currentOrder);
            }
          },
          itemBuilder: (context) => [
            _buildMenuItem(SortOption.name, currentSort),
            // Offline data has no DateCreated / PlayCount; year only meaningful
            // for albums, and even then only when productionYear is populated.
            if (!appState.isOfflineMode)
              _buildMenuItem(SortOption.dateAdded, currentSort),
            if (isAlbums) _buildMenuItem(SortOption.year, currentSort),
            if (!appState.isOfflineMode)
              _buildMenuItem(SortOption.playCount, currentSort),
          ],
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              _sortOptionIcon(currentSort),
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Sort order toggle
        IconButton(
          icon: Icon(
            currentOrder == SortOrder.ascending
                ? Icons.arrow_upward
                : Icons.arrow_downward,
            size: 20,
          ),
          tooltip: currentOrder == SortOrder.ascending ? 'Ascending' : 'Descending',
          onPressed: () {
            final newOrder = currentOrder == SortOrder.ascending
                ? SortOrder.descending
                : SortOrder.ascending;
            if (isAlbums) {
              appState.setAlbumSort(currentSort, newOrder);
            } else {
              appState.setArtistSort(currentSort, newOrder);
            }
          },
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  PopupMenuItem<SortOption> _buildMenuItem(SortOption option, SortOption current) {
    return PopupMenuItem<SortOption>(
      value: option,
      child: Row(
        children: [
          if (option == current)
            const Icon(Icons.check, size: 18)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(_sortOptionLabel(option)),
        ],
      ),
    );
  }
}

class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({
    required this.albums,
    required this.isLoading,
    required this.isLoadingMore,
    required this.error,
    required this.scrollController,
    required this.onRefresh,
    required this.onAlbumTap,
    required this.appState,
    this.sortBy = SortOption.name,
    this.sortOrder = SortOrder.ascending,
    this.hasMore = false,
    this.onLoadAll,
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final Function(JellyfinAlbum) onAlbumTap;
  final NautuneAppState appState;
  final SortOption sortBy;
  final SortOrder sortOrder;
  final bool hasMore;
  final Future<void> Function()? onLoadAll;

  @override
  Widget build(BuildContext context) {
    if (error != null && (albums == null || albums!.isEmpty)) {
      return _LibraryMessage(
        icon: Icons.error_outline,
        title: 'Couldn\'t load albums',
        actionLabel: 'Retry',
        onAction: onRefresh,
      );
    }
    if (isLoading && (albums == null || albums!.isEmpty)) {
      return const _LibraryGridSkeleton();
    }
    if (albums == null || albums!.isEmpty) {
      return const _LibraryMessage(icon: Icons.album, title: 'No albums found');
    }
    final uiState = context.watch<UIStateProvider>();
    final metrics = LibraryTileMetrics.of(context);
    return IndexedCollectionView<JellyfinAlbum>(
      items: albums!,
      nameOf: (album) => album.groupingName,
      controller: scrollController,
      listMode: uiState.useListMode,
      columns: uiState.gridSize,
      indexed: sortBy == SortOption.name,
      ascending: sortOrder == SortOrder.ascending,
      listItemExtent: metrics.listRowExtent,
      gridItemExtent: metrics.gridExtent,
      isLoadingMore: isLoadingMore,
      hasMore: hasMore,
      onLoadAll: onLoadAll,
      onRefresh: onRefresh,
      listItemBuilder: (context, album) => _AlbumListTile(
        album: album,
        onTap: () => onAlbumTap(album),
        appState: appState,
      ),
      gridItemBuilder: (context, album) => _AlbumCard(
        album: album,
        onTap: () => onAlbumTap(album),
        appState: appState,
      ),
    );
  }
}

/// Centered icon + message (+ optional action) for empty and error states.
class _LibraryMessage extends StatelessWidget {
  const _LibraryMessage({
    required this.icon,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NautuneSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: NautuneSpacing.lg),
            Text(title, style: theme.textTheme.headline, textAlign: TextAlign.center),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: NautuneSpacing.md),
              FilledButton.tonal(
                onPressed: () => onAction!(),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Placeholder grid shown while the first page of a collection loads.
class _LibraryGridSkeleton extends StatelessWidget {
  const _LibraryGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final columns = context.watch<UIStateProvider>().gridSize;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(NautuneSpacing.lg),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: NautuneSpacing.lg,
        mainAxisSpacing: NautuneSpacing.lg,
        childAspectRatio: 0.8,
      ),
      itemCount: columns * 4,
      itemBuilder: (context, _) => LayoutBuilder(
        builder: (context, c) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonLoader(width: c.maxWidth, height: c.maxWidth, borderRadius: NautuneRadius.md),
            const SizedBox(height: 6),
            SkeletonLoader(width: c.maxWidth * 0.8, height: 12, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}

Widget _albumArtwork(JellyfinAlbum album, {int? maxWidth}) {
  if (album.primaryImageTag == null) {
    return Image.asset('assets/no_album_art.png', fit: BoxFit.cover);
  }
  return JellyfinImage(
    itemId: album.id,
    imageTag: album.primaryImageTag,
    albumId: album.id,
    maxWidth: maxWidth,
    boxFit: BoxFit.cover,
    errorBuilder: (context, url, error) =>
        Image.asset('assets/no_album_art.png', fit: BoxFit.cover),
  );
}

Future<void> _showAlbumActions(
  BuildContext context,
  NautuneAppState appState,
  JellyfinAlbum album,
) async {
  HapticService.mediumTap();
  final action = await showNautuneActionSheet<String>(
    context,
    title: album.name,
    message: album.displayArtist,
    actions: const [
      NautuneSheetAction(
        label: 'Add to Playlist',
        value: 'playlist',
        icon: Icons.playlist_add,
      ),
    ],
  );
  if (action == 'playlist' && context.mounted) {
    await showAddToPlaylistDialog(
      context: context,
      appState: appState,
      album: album,
    );
  }
}

class _AlbumListTile extends StatelessWidget {
  const _AlbumListTile({required this.album, required this.onTap, required this.appState});
  final JellyfinAlbum album;
  final VoidCallback onTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    return LibraryListRow(
      artwork: _albumArtwork(album),
      title: album.name,
      subtitle: album.artists.isNotEmpty ? album.displayArtist : null,
      onTap: onTap,
      onLongPress: () => _showAlbumActions(context, appState, album),
    );
  }
}

class _MiniAlbumCard extends StatelessWidget {
  const _MiniAlbumCard({
    required this.album,
    required this.appState,
    required this.onTap,
  });

  final JellyfinAlbum album;
  final NautuneAppState appState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 150,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: album.primaryImageTag != null
                      ? JellyfinImage(
                          itemId: album.id,
                          imageTag: album.primaryImageTag,
                          albumId: album.id,
                          maxWidth: 400,
                          boxFit: BoxFit.cover,
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
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      album.displayArtist,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap, required this.appState});
  final JellyfinAlbum album;
  final VoidCallback onTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    return ArtworkGridTile(
      artwork: _albumArtwork(album),
      title: album.name,
      subtitle: album.artists.isNotEmpty ? album.displayArtist : null,
      onTap: onTap,
      onLongPress: () => _showAlbumActions(context, appState, album),
    );
  }
}
