import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_album.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';

class ArtistDetailScreen extends StatefulWidget {
  const ArtistDetailScreen({
    super.key,
    required this.artist,
  });

  final JellyfinArtist artist;

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  bool _isLoading = false;
  Object? _error;
  List<JellyfinAlbum>? _albums;
  late NautuneAppState _appState;
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState = Provider.of<NautuneAppState>(context, listen: false);

    // Only load albums once after _appState is initialized
    if (!_hasInitialized) {
      _hasInitialized = true;
      _loadAlbums();
    }
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Use efficient API to get albums directly by artist ID
      final artistAlbums = await _appState.jellyfinService.loadAlbumsByArtist(
        artistId: widget.artist.id,
      );
      
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
      artwork = ClipOval(
        child: JellyfinImage(
          itemId: artist.id,
          imageTag: tag,
          artistId: artist.id, // Enable offline artist image support
          maxWidth: 800,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => _DefaultArtistArtwork(),
        ),
      );
    } else {
      artwork = _DefaultArtistArtwork();
    }

    return Scaffold(
      body: CustomScrollView(
        cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
        slivers: [
          SliverAppBar(
            expandedHeight: isDesktop ? 350 : 300,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              // Instant Mix button
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Instant Mix',
                onPressed: () async {
                  try {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Creating instant mix...'),
                        duration: Duration(seconds: 1),
                      ),
                    );

                    final mixTracks = await _appState.jellyfinService.getInstantMix(
                      itemId: widget.artist.id,
                      limit: 50,
                    );

                    if (mixTracks.isEmpty) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No similar tracks found'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }

                    await _appState.audioPlayerService.playTrack(
                      mixTracks.first,
                      queueContext: mixTracks,
                    );

                    if (!context.mounted) return;
                    
                    // Simple notification without persistent action button
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to create mix: $e'),
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                    );
                  }
                },
              ),
            ],
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
                  // Show genres
                  if (artist.genres != null && artist.genres!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        children: artist.genres!.take(5).map((genre) {
                          return Chip(
                            label: Text(
                              genre,
                              style: theme.textTheme.bodySmall,
                            ),
                            visualDensity: VisualDensity.compact,
                          );
                        }).toList(),
                      ),
                    ),
                  // Show counts
                  Row(
                    children: [
                      if (artist.albumCount != null && artist.albumCount! > 0) ...[
                        Icon(Icons.album, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          '${artist.albumCount} albums',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 16),
                      ],
                      if (artist.songCount != null && artist.songCount! > 0) ...[
                        Icon(Icons.music_note, size: 16, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          '${artist.songCount} songs',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  // Show overview/bio if available
                  if (artist.overview != null && artist.overview!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'About',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      artist.overview!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF9CC7F2),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_albums != null && _albums!.isNotEmpty)
                    Text(
                      'Albums',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isDesktop ? 4 : 2,
                  childAspectRatio: 0.8,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final album = _albums![index];
                    return _AlbumCard(
                      album: album,
                      appState: _appState,
                    );
                  },
                  childCount: _albums!.length,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NowPlayingBar(
        audioService: _appState.audioPlayerService,
        appState: _appState,
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
      artwork = JellyfinImage(
        itemId: album.id,
        imageTag: tag,
        maxWidth: 300,
        boxFit: BoxFit.cover,
        errorBuilder: (context, url, error) => Container(
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
    return ClipOval(
      child: Image.asset(
        'assets/no_artist_art.png',
        fit: BoxFit.cover,
      ),
    );
  }
}
