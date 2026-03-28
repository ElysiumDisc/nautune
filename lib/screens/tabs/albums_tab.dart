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
            _buildMenuItem(SortOption.dateAdded, currentSort),
            if (isAlbums) _buildMenuItem(SortOption.year, currentSort),
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
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController scrollController;
  final VoidCallback onRefresh;
  final Function(JellyfinAlbum) onAlbumTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            const Text('Failed to load albums'),
            const SizedBox(height: 8),
            ElevatedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }
    if (isLoading && (albums == null || albums!.isEmpty)) return const Center(child: CircularProgressIndicator());
    if (albums == null || albums!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text('No albums found'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;
          final useListMode = uiState.useListMode;

          // List mode rendering
          if (useListMode) {
            // Only show section headers when sorted by name
            final showHeaders = appState.albumSortBy == SortOption.name;
            final letterGroups = showHeaders
                ? AlphabetSectionBuilder.groupByLetter<JellyfinAlbum>(
                    albums!,
                    (album) => album.name,
                    appState.albumSortOrder,
                  )
                : <(String, List<JellyfinAlbum>)>[];

            return Stack(
              children: [
                CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: showHeaders
                          ? SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  // Calculate which group and item we're at
                                  int currentIndex = 0;
                                  for (final (letter, items) in letterGroups) {
                                    // Header
                                    if (index == currentIndex) {
                                      return _AlphabetSectionHeader(letter: letter);
                                    }
                                    currentIndex++;
                                    // Items in this group
                                    if (index < currentIndex + items.length) {
                                      final album = items[index - currentIndex];
                                      return _AlbumListTile(
                                        album: album,
                                        onTap: () => onAlbumTap(album),
                                        appState: appState,
                                      );
                                    }
                                    currentIndex += items.length;
                                  }
                                  // Loading indicator
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                },
                                childCount: letterGroups.fold(0, (sum, g) => sum + 1 + g.$2.length) + (isLoadingMore ? 1 : 0),
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= albums!.length) {
                                    return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                  }
                                  final album = albums![index];
                                  return _AlbumListTile(
                                    album: album,
                                    onTap: () => onAlbumTap(album),
                                    appState: appState,
                                  );
                                },
                                childCount: albums!.length + (isLoadingMore ? 1 : 0),
                              ),
                            ),
                    ),
                  ],
                ),
                AlphabetScrollbar(
                  items: albums!,
                  getItemName: (album) => (album as JellyfinAlbum).name,
                  scrollController: scrollController,
                  itemHeight: 72, // List tile height
                  crossAxisCount: 1,
                  sortOrder: appState.albumSortOrder,
                  sortBy: appState.albumSortBy,
                ),
              ],
            );
          }

          // Grid mode rendering
          final showGridHeaders = appState.albumSortBy == SortOption.name;
          final gridLetterGroups = showGridHeaders
              ? AlphabetSectionBuilder.groupByLetter<JellyfinAlbum>(
                  albums!,
                  (album) => album.name,
                  appState.albumSortOrder,
                )
              : <(String, List<JellyfinAlbum>)>[];
          final itemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 16) / crossAxisCount) / 0.7 + 16;

          return Stack(
            children: [
              CustomScrollView(
                controller: scrollController,
                slivers: showGridHeaders
                    ? [
                        // Build alternating headers and grids for each letter group
                        for (final (letter, items) in gridLetterGroups) ...[
                          SliverToBoxAdapter(
                            child: _AlphabetSectionHeader(letter: letter),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            sliver: SliverGrid(
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 0.7,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= items.length) return null;
                                  final album = items[index];
                                  return _AlbumCard(
                                    album: album,
                                    onTap: () => onAlbumTap(album),
                                    appState: appState,
                                  );
                                },
                                childCount: items.length,
                              ),
                            ),
                          ),
                        ],
                        if (isLoadingMore)
                          const SliverToBoxAdapter(
                            child: Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator())),
                          ),
                      ]
                    : [
                        // Original single grid without headers
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 0.7,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index >= albums!.length) {
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                }
                                final album = albums![index];
                                return _AlbumCard(
                                  album: album,
                                  onTap: () => onAlbumTap(album),
                                  appState: appState,
                                );
                              },
                              childCount: albums!.length + (isLoadingMore ? 2 : 0),
                            ),
                          ),
                        ),
                      ],
              ),
              AlphabetScrollbar(
                items: albums!,
                getItemName: (album) => (album as JellyfinAlbum).name,
                scrollController: scrollController,
                itemHeight: itemHeight,
                crossAxisCount: crossAxisCount,
                sortOrder: appState.albumSortOrder,
                sortBy: appState.albumSortBy,
              ),
            ],
          );
        },
      ),
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
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('Add to Playlist'),
                  onTap: () async {
                    Navigator.pop(context);
                    await showAddToPlaylistDialog(
                      context: context,
                      appState: appState,
                      album: album,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 56,
          height: 56,
          child: album.primaryImageTag != null
              ? JellyfinImage(
                  itemId: album.id,
                  imageTag: album.primaryImageTag,
                  albumId: album.id,
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
      title: Text(
        album.name,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.tertiary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: album.artists.isNotEmpty
          ? Text(
              album.displayArtist,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
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
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('Add to Playlist'),
                    onTap: () async {
                      Navigator.pop(context);
                      await showAddToPlaylistDialog(
                        context: context,
                        appState: appState,
                        album: album,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
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
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        album.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.tertiary,  // Ocean blue
                          height: 1.15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (album.artists.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        album.displayArtist,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue slightly transparent
                          height: 1.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
