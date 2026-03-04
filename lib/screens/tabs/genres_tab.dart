part of '../library_screen.dart';

class _GenresTab extends StatefulWidget {
  const _GenresTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_GenresTab> createState() => _GenresTabState();
}

class _GenresTabState extends State<_GenresTab> {
  late ScrollController _genresScrollController;

  @override
  void initState() {
    super.initState();
    _genresScrollController = ScrollController();
  }

  @override
  void dispose() {
    _genresScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final genres = widget.appState.genres;
    final isLoading = widget.appState.isLoadingGenres;
    final error = widget.appState.genresError;

    if (isLoading && genres == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error != null && genres == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Failed to load genres', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(error.toString(), style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (genres == null || genres.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.category, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text('No Genres Found', style: theme.textTheme.titleLarge),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => widget.appState.refreshGenres(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;

          // Genres are always sorted by name
          final genreLetterGroups = AlphabetSectionBuilder.groupByLetter<JellyfinGenre>(
            genres,
            (genre) => genre.name,
            SortOrder.ascending,
          );
          final genreItemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 12) / crossAxisCount) / 1.5 + 12;

          return Stack(
            children: [
              CustomScrollView(
                controller: _genresScrollController,
                slivers: [
                  for (final (letter, items) in genreLetterGroups) ...[
                    SliverToBoxAdapter(
                      child: _AlphabetSectionHeader(letter: letter),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 1.5,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index >= items.length) return null;
                            final genre = items[index];
                            return _GenreCard(genre: genre, appState: widget.appState);
                          },
                          childCount: items.length,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              AlphabetScrollbar(
                items: genres,
                getItemName: (genre) => (genre as JellyfinGenre).name,
                scrollController: _genresScrollController,
                itemHeight: genreItemHeight,
                crossAxisCount: crossAxisCount,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GenreCard extends StatelessWidget {
  const _GenreCard({required this.genre, required this.appState});

  final JellyfinGenre genre;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => GenreDetailScreen(
                genre: genre,
              ),
            ),
          );
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.3),
                theme.colorScheme.secondary.withValues(alpha: 0.3),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  genre.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (genre.albumCount != null || genre.trackCount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (genre.albumCount != null) '${genre.albumCount} albums',
                      if (genre.trackCount != null) '${genre.trackCount} tracks',
                    ].join(' • '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
