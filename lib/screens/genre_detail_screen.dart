import 'package:flutter/material.dart';
import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_genre.dart';
import 'album_detail_screen.dart';

class GenreDetailScreen extends StatefulWidget {
  const GenreDetailScreen({
    super.key,
    required this.genre,
    required this.appState,
  });

  final JellyfinGenre genre;
  final NautuneAppState appState;

  @override
  State<GenreDetailScreen> createState() => _GenreDetailScreenState();
}

class _GenreDetailScreenState extends State<GenreDetailScreen> {
  List<JellyfinAlbum>? _albums;
  bool _isLoading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final libraryId = widget.appState.selectedLibraryId;
      if (libraryId == null) {
        throw Exception('No library selected');
      }

      final session = widget.appState.jellyfinService.session;
      if (session == null) {
        throw Exception('No session');
      }

      final client = widget.appState.jellyfinService.jellyfinClient;
      if (client == null) {
        throw Exception('No client available');
      }

      // Fetch albums directly from Jellyfin API filtered by this genre
      _albums = await client.fetchAlbums(
        credentials: session.credentials,
        libraryId: libraryId,
        genreIds: widget.genre.id,
      );
    } catch (e) {
      _error = e;
    } finally {
      setState(() => _isLoading = false);
    }
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
        
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.75,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: _albums!.length,
          itemBuilder: (context, index) {
            final album = _albums![index];
            return _AlbumCard(
              album: album,
              appState: widget.appState,
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
  });

  final JellyfinAlbum album;
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
              builder: (context) => AlbumDetailScreen(
                album: album,
                appState: appState,
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: album.primaryImageTag != null
                  ? Image.network(
                      appState.buildImageUrl(
                        itemId: album.id,
                        tag: album.primaryImageTag,
                        maxWidth: 400,
                      ),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Image.asset(
                        'assets/no_album_art.png',
                        fit: BoxFit.cover,
                      ),
                    )
                  : Image.asset(
                      'assets/no_album_art.png',
                      fit: BoxFit.cover,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    album.displayArtist,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
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
    );
  }
}
