import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/library_tiles.dart';
import 'album_detail_screen.dart';

class GenreDetailScreen extends StatefulWidget {
  const GenreDetailScreen({
    super.key,
    required this.genre,
  });

  final JellyfinGenre genre;

  @override
  State<GenreDetailScreen> createState() => _GenreDetailScreenState();
}

class _GenreDetailScreenState extends State<GenreDetailScreen> {
  List<JellyfinAlbum>? _albums;
  bool _isLoading = true;
  Object? _error;
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitialized) {
      _appState = Provider.of<NautuneAppState>(context, listen: false);
      _previousOfflineMode = _appState!.isOfflineMode;
      _previousNetworkAvailable = _appState!.networkAvailable;
      _hasInitialized = true;
      _appState!.addListener(_onConnectivityChanged);
      unawaited(_loadAlbums());
    }
  }

  void _onConnectivityChanged() {
    if (!mounted || _appState == null) return;
    final offline = _appState!.isOfflineMode;
    final network = _appState!.networkAvailable;
    if (_previousOfflineMode != offline || _previousNetworkAvailable != network) {
      debugPrint('🔄 GenreDetail: Connectivity changed');
      _previousOfflineMode = offline;
      _previousNetworkAvailable = network;
      unawaited(_loadAlbums());
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    if (_appState == null) return;
    // Connectivity flips can overlap loads; only the latest one lands.
    final generation = ++_loadGeneration;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    List<JellyfinAlbum>? albums;
    Object? error;
    try {
      final libraryId = _appState!.selectedLibraryId;
      if (libraryId == null) {
        throw Exception('No library selected');
      }

      final session = _appState!.jellyfinService.session;
      if (session == null) {
        throw Exception('No session');
      }

      // Use repository instead of direct client call to support offline mode
      albums = await _appState!.repository.getGenreAlbums(widget.genre.id);
    } catch (e) {
      error = e;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _albums = albums ?? _albums;
      _error = error;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.genre.name),
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('Failed to load albums', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(_error.toString(), textAlign: TextAlign.center),
          ],
        ),
      );
    }

    if (_albums == null || _albums!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text('No Albums Found', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('No albums in this genre', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 800 ? 4 : 2;
        const padding = 16.0;
        const spacing = 16.0;
        final tileWidth = (constraints.maxWidth -
                2 * padding -
                (crossAxisCount - 1) * spacing) /
            crossAxisCount;

        return GridView.builder(
          padding: const EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            // Artwork plus title and artist lines, scaled with the text size.
            mainAxisExtent: LibraryTileMetrics.of(context).gridExtent(tileWidth),
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: _albums!.length,
          itemBuilder: (context, index) {
            final album = _albums![index];
            return _AlbumCard(
              album: album,
              appState: _appState!,
              artworkWidth: tileWidth,
            );
          },
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.appState,
    required this.artworkWidth,
  });

  final JellyfinAlbum album;
  final NautuneAppState appState;

  /// Logical width the artwork is drawn at (the tile width).
  final double artworkWidth;

  @override
  Widget build(BuildContext context) {
    final tag = album.primaryImageTag;
    final artwork = tag != null && tag.isNotEmpty
        ? JellyfinImage(
            itemId: album.id,
            imageTag: tag,
            albumId: album.id,
            // Not below the prewarmed grid size, so small tiles share
            // the library grid's cache entries.
            maxWidth: artworkWidth > JellyfinImage.gridArtwork
                ? artworkWidth.ceil()
                : JellyfinImage.gridArtwork,
            boxFit: BoxFit.cover,
            errorBuilder: (context, url, error) => Image.asset(
              'assets/no_album_art.png',
              fit: BoxFit.cover,
            ),
          )
        : Image.asset('assets/no_album_art.png', fit: BoxFit.cover);

    return ArtworkGridTile(
      artwork: artwork,
      title: album.name,
      subtitle: album.displayArtist,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => AlbumDetailScreen(album: album),
          ),
        );
      },
    );
  }
}
