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

    // Genre cards hold text, not artwork: keep them at least ~150pt wide
    // and tall enough for two title lines plus the counts at any text size.
    final gridSize = context.watch<UIStateProvider>().gridSize;
    final width = MediaQuery.sizeOf(context).width;
    final columns = gridSize.clamp(1, (width / 150).floor().clamp(1, 12));
    final extent = _GenreCard.extentFor(MediaQuery.textScalerOf(context));
    return IndexedCollectionView<JellyfinGenre>(
      items: genres,
      nameOf: (genre) => genre.name,
      controller: _genresScrollController,
      columns: columns,
      gridSpacing: NautuneSpacing.md,
      gridItemExtent: (w) => extent > w / 1.5 ? extent : w / 1.5,
      onRefresh: () => widget.appState.refreshGenres(),
      listItemBuilder: (context, genre) =>
          _GenreCard(genre: genre, appState: widget.appState),
      gridItemBuilder: (context, genre) =>
          _GenreCard(genre: genre, appState: widget.appState),
    );
  }
}

class _GenreCard extends StatelessWidget {
  const _GenreCard({required this.genre, required this.appState});

  final JellyfinGenre genre;
  final NautuneAppState appState;

  static const double _padding = 16;
  static const double _cardMargin = 4; // Card's default margin

  /// Height that fits two title lines and the counts line at [scaler].
  static double extentFor(TextScaler scaler) =>
      2 * _cardMargin +
      2 * _padding +
      2 * scaler.scale(16) * 1.5 + // titleMedium, two lines
      8 +
      scaler.scale(12) * 1.34 + // bodySmall counts line
      2;

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
            padding: const EdgeInsets.all(_padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
