part of '../library_screen.dart';

class _ArtistsTab extends StatelessWidget {
  const _ArtistsTab({
    required this.appState,
    this.artists,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
    this.scrollController,
    this.onRefresh,
  });

  final NautuneAppState appState;
  final List<JellyfinArtist>? artists;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController? scrollController;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Use passed values or fallback to appState (online mode)
    final effectiveArtists = artists ?? appState.artists;
    final effectiveIsLoading = artists != null ? isLoading : appState.isLoadingArtists;
    final effectiveIsLoadingMore = artists != null ? isLoadingMore : appState.isLoadingMoreArtists;
    final effectiveError = artists != null ? error : appState.artistsError;

    if (effectiveIsLoading && effectiveArtists == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (effectiveError != null && effectiveArtists == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Failed to load artists',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                effectiveError.toString(),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (onRefresh != null)
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
            ],
          ),
        ),
      );
    }

    if (effectiveArtists == null || effectiveArtists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text(
              'No Artists Found',
              style: theme.textTheme.titleLarge,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        if (onRefresh != null) {
          onRefresh!();
        } else {
          await appState.refreshArtists();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;
          final useListMode = uiState.useListMode;
          final controller = scrollController!;

          // List mode rendering
          final effectiveSortBy = artists != null ? SortOption.name : appState.artistSortBy;
          final effectiveSortOrder = artists != null ? SortOrder.ascending : appState.artistSortOrder;
          final showArtistHeaders = effectiveSortBy == SortOption.name;
          final artistLetterGroups = showArtistHeaders
              ? AlphabetSectionBuilder.groupByLetter<JellyfinArtist>(
                  effectiveArtists,
                  (artist) => artist.name,
                  effectiveSortOrder,
                )
              : <(String, List<JellyfinArtist>)>[];

          if (useListMode) {
            return Stack(
              children: [
                CustomScrollView(
                  controller: controller,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: showArtistHeaders
                          ? SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  int currentIndex = 0;
                                  for (final (letter, items) in artistLetterGroups) {
                                    if (index == currentIndex) {
                                      return _AlphabetSectionHeader(letter: letter);
                                    }
                                    currentIndex++;
                                    if (index < currentIndex + items.length) {
                                      final artist = items[index - currentIndex];
                                      return _ArtistListTile(artist: artist, appState: appState);
                                    }
                                    currentIndex += items.length;
                                  }
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                },
                                childCount: artistLetterGroups.fold(0, (sum, g) => sum + 1 + g.$2.length) + (effectiveIsLoadingMore ? 1 : 0),
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= effectiveArtists.length) {
                                    return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                  }
                                  final artist = effectiveArtists[index];
                                  return _ArtistListTile(artist: artist, appState: appState);
                                },
                                childCount: effectiveArtists.length + (effectiveIsLoadingMore ? 1 : 0),
                              ),
                            ),
                    ),
                  ],
                ),
                AlphabetScrollbar(
                  items: effectiveArtists,
                  getItemName: (artist) => (artist as JellyfinArtist).name,
                  scrollController: controller,
                  itemHeight: 72,
                  crossAxisCount: 1,
                  sortOrder: effectiveSortOrder,
                  sortBy: effectiveSortBy,
                ),
              ],
            );
          }

          // Grid mode rendering
          final artistItemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 12) / crossAxisCount) / 0.7 + 12;

          return Stack(
            children: [
              CustomScrollView(
                controller: controller,
                slivers: showArtistHeaders
                    ? [
                        for (final (letter, items) in artistLetterGroups) ...[
                          SliverToBoxAdapter(
                            child: _AlphabetSectionHeader(letter: letter),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            sliver: SliverGrid(
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 0.7,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= items.length) return null;
                                  final artist = items[index];
                                  return _ArtistCard(artist: artist, appState: appState);
                                },
                                childCount: items.length,
                              ),
                            ),
                          ),
                        ],
                        if (effectiveIsLoadingMore)
                          const SliverToBoxAdapter(
                            child: Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator())),
                          ),
                      ]
                    : [
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 0.7,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index >= effectiveArtists.length) {
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                }
                                final artist = effectiveArtists[index];
                                return _ArtistCard(artist: artist, appState: appState);
                              },
                              childCount: effectiveArtists.length + (effectiveIsLoadingMore ? 2 : 0),
                            ),
                          ),
                        ),
                      ],
              ),
              AlphabetScrollbar(
                items: effectiveArtists,
                getItemName: (artist) => (artist as JellyfinArtist).name,
                scrollController: controller,
                itemHeight: artistItemHeight,
                crossAxisCount: crossAxisCount,
                sortOrder: effectiveSortOrder,
                sortBy: effectiveSortBy,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ArtistListTile extends StatelessWidget {
  const _ArtistListTile({required this.artist, required this.appState});

  final JellyfinArtist artist;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = artist.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      artwork = ClipOval(
        child: JellyfinImage(
          itemId: artist.id,
          imageTag: tag,
          artistId: artist.id,
          maxWidth: 100,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => ClipOval(
            child: Image.asset(
              'assets/no_artist_art.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    } else {
      artwork = ClipOval(
        child: Image.asset(
          'assets/no_artist_art.png',
          fit: BoxFit.cover,
        ),
      );
    }

    return ListTile(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailScreen(
              artist: artist,
            ),
          ),
        );
      },
      leading: SizedBox(
        width: 56,
        height: 56,
        child: artwork,
      ),
      title: Text(
        artist.name,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist, required this.appState});

  final JellyfinArtist artist;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = artist.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      artwork = ClipOval(
        child: JellyfinImage(
          itemId: artist.id,
          imageTag: tag,
          artistId: artist.id, // Enable offline artist image support
          maxWidth: 400,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => ClipOval(
            child: Image.asset(
              'assets/no_artist_art.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    } else {
      artwork = ClipOval(
        child: Image.asset(
          'assets/no_artist_art.png',
          fit: BoxFit.cover,
        ),
      );
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailScreen(
              artist: artist,
            ),
          ),
        );
      },
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: AspectRatio(
              aspectRatio: 1,
              child: artwork,
            ),
          ),
          Expanded(
            flex: 1,
            child: ClipRect(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  artist.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.tertiary,  // Ocean blue
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
