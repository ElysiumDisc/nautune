import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_album.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';

class ArtistDetailScreen extends StatefulWidget {
  const ArtistDetailScreen({
    super.key,
    required this.artist,
    required this.appState,
  });

  final JellyfinArtist artist;
  final NautuneAppState appState;

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  bool _isLoading = false;
  Object? _error;
  List<JellyfinAlbum>? _albums;

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
      final libraryId = widget.appState.session?.selectedLibraryId;
      if (libraryId == null) return;
      
      // Get all albums and filter by artist
      final allAlbums = await widget.appState.jellyfinService.loadAlbums(
        libraryId: libraryId,
      );
      
      final artistAlbums = allAlbums.where((album) {
        return album.artists.contains(widget.artist.name);
      }).toList();
      
      if (mounted) {
        setState(() {
          _albums = artistAlbums;
          _isLoading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artist = widget.artist;
    final isDesktop = MediaQuery.of(context).size.width > 600;

    Widget artwork;
    final tag = artist.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      final imageUrl = widget.appState.jellyfinService.buildImageUrl(
        itemId: artist.id,
        tag: tag,
        maxWidth: 800,
      );
      artwork = ClipOval(
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          headers: widget.appState.jellyfinService.imageHeaders(),
          errorBuilder: (_, __, ___) => _DefaultArtistArtwork(),
        ),
      );
    } else {
      artwork = _DefaultArtistArtwork();
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: isDesktop ? 350 : 300,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: 'Back to Artists',
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: theme.colorScheme.primaryContainer,
                    child: Center(
                      child: SizedBox(
                        width: 200,
                        height: 200,
                        child: artwork,
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          theme.scaffoldBackgroundColor,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.6, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artist.name,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_albums != null && _albums!.isNotEmpty)
                    Text(
                      '${_albums!.length} ${_albums!.length == 1 ? 'Album' : 'Albums'}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          if (_isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
                      const SizedBox(height: 16),
                      Text(
                        'Could not load albums',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error.toString(),
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_albums == null || _albums!.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'No albums found',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final album = _albums![index];
                    return _AlbumCard(
                      album: album,
                      appState: widget.appState,
                    );
                  },
                  childCount: _albums!.length,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NowPlayingBar(
        audioService: widget.appState.audioPlayerService,
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.appState});

  final JellyfinAlbum album;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = album.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      final imageUrl = appState.jellyfinService.buildImageUrl(
        itemId: album.id,
        tag: tag,
        maxWidth: 400,
      );
      artwork = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        headers: appState.jellyfinService.imageHeaders(),
        errorBuilder: (_, __, ___) => Container(
          color: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.album,
            size: 48,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      );
    } else {
      artwork = Container(
        color: theme.colorScheme.primaryContainer,
        child: Icon(
          Icons.album,
          size: 48,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      );
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AlbumDetailScreen(
              album: album,
              appState: appState,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: artwork,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            album.name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (album.productionYear != null)
            Text(
              '${album.productionYear}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _DefaultArtistArtwork extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primaryContainer,
      ),
      child: Icon(
        Icons.person,
        size: 80,
        color: theme.colorScheme.onPrimaryContainer,
      ),
    );
  }
}
