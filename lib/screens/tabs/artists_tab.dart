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

  /// Offline list; null means the online library from [appState].
  final List<JellyfinArtist>? artists;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController? scrollController;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final online = artists == null;
    final effectiveArtists = artists ?? appState.artists;
    final effectiveIsLoading = online ? appState.isLoadingArtists : isLoading;
    final effectiveIsLoadingMore =
        online ? appState.isLoadingMoreArtists : isLoadingMore;
    final effectiveError = online ? appState.artistsError : error;
    final refresh = onRefresh ?? appState.refreshArtists;

    if (effectiveIsLoading && (effectiveArtists == null || effectiveArtists.isEmpty)) {
      return const _LibraryGridSkeleton();
    }
    if (effectiveError != null && (effectiveArtists == null || effectiveArtists.isEmpty)) {
      return _LibraryMessage(
        icon: Icons.error_outline,
        title: 'Couldn\'t load artists',
        actionLabel: 'Retry',
        onAction: refresh,
      );
    }
    if (effectiveArtists == null || effectiveArtists.isEmpty) {
      return const _LibraryMessage(icon: Icons.person, title: 'No artists found');
    }

    final uiState = context.watch<UIStateProvider>();
    final metrics = LibraryTileMetrics.of(context);
    final sortBy = online ? appState.artistSortBy : SortOption.name;
    final sortOrder = online ? appState.artistSortOrder : SortOrder.ascending;
    return IndexedCollectionView<JellyfinArtist>(
      items: effectiveArtists,
      nameOf: (artist) => artist.groupingName,
      controller: scrollController!,
      listMode: uiState.useListMode,
      columns: uiState.gridSize,
      indexed: sortBy == SortOption.name,
      ascending: sortOrder == SortOrder.ascending,
      listItemExtent: metrics.listRowExtent,
      gridItemExtent: (w) => metrics.gridExtent(w, subtitle: false),
      isLoadingMore: effectiveIsLoadingMore,
      hasMore: online && appState.hasMoreArtists,
      onLoadAll: online ? appState.loadAllArtists : null,
      onRefresh: refresh,
      listItemBuilder: (context, artist) => _ArtistListTile(artist: artist),
      gridItemBuilder: (context, artist) => _ArtistCard(artist: artist),
    );
  }
}

Widget _artistArtwork(JellyfinArtist artist, {int maxWidth = 400}) {
  final tag = artist.primaryImageTag;
  if (tag == null || tag.isEmpty) {
    return Image.asset('assets/no_artist_art.png', fit: BoxFit.cover);
  }
  return JellyfinImage(
    itemId: artist.id,
    imageTag: tag,
    artistId: artist.id, // Enable offline artist image support
    maxWidth: maxWidth,
    boxFit: BoxFit.cover,
    errorBuilder: (context, url, error) =>
        Image.asset('assets/no_artist_art.png', fit: BoxFit.cover),
  );
}

void _openArtist(BuildContext context, JellyfinArtist artist) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ArtistDetailScreen(artist: artist)),
  );
}

class _ArtistListTile extends StatelessWidget {
  const _ArtistListTile({required this.artist});

  final JellyfinArtist artist;

  @override
  Widget build(BuildContext context) {
    return LibraryListRow(
      artwork: _artistArtwork(artist, maxWidth: 100),
      circular: true,
      title: artist.name,
      onTap: () => _openArtist(context, artist),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist});

  final JellyfinArtist artist;

  @override
  Widget build(BuildContext context) {
    return ArtworkGridTile(
      artwork: _artistArtwork(artist),
      circular: true,
      title: artist.name,
      onTap: () => _openArtist(context, artist),
    );
  }
}
