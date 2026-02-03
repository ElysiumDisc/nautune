import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui show FontFeature, Image;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/listenbrainz_service.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';

/// Top-level function for compute() - extracts colors from image bytes in isolate
List<int> _extractColorsFromBytes(Uint8List pixels) {
  final colors = <int>[];

  // Sample colors from the image (RGBA format)
  for (int i = 0; i < pixels.length; i += 400) {
    if (i + 2 < pixels.length) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      // Store as ARGB int
      colors.add(0xFF000000 | (r << 16) | (g << 8) | b);
    }
  }

  // Sort by luminance to get darker colors first
  colors.sort((a, b) {
    final rA = (a >> 16) & 0xFF;
    final gA = (a >> 8) & 0xFF;
    final bA = a & 0xFF;
    final rB = (b >> 16) & 0xFF;
    final gB = (b >> 8) & 0xFF;
    final bB = b & 0xFF;
    final lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA;
    final lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB;
    return lumA.compareTo(lumB);
  });

  return colors;
}

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
  // Static LRU cache for palette colors
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxCacheSize = 50;

  bool _isLoading = false;
  Object? _error;
  List<JellyfinAlbum>? _albums;
  late NautuneAppState _appState;
  bool _hasInitialized = false;
  List<Color>? _paletteColors;
  bool _bioExpanded = false;

  // Top tracks from ListenBrainz
  List<JellyfinTrack>? _topTracks;
  bool _isLoadingTopTracks = false;

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
      _loadTopTracks();
      _extractColors();
    }
  }

  Future<void> _extractColors() async {
    final tag = widget.artist.primaryImageTag;
    if (tag == null || tag.isEmpty) return;

    // Check cache first
    final cacheKey = '${widget.artist.id}-$tag';
    final cached = _paletteCache[cacheKey];
    if (cached != null) {
      if (mounted) {
        setState(() {
          _paletteColors = cached;
        });
      }
      return;
    }

    try {
      final imageUrl = _appState.jellyfinService.buildImageUrl(
        itemId: widget.artist.id,
        tag: tag,
        maxWidth: 100,
      );

      final imageProvider = NetworkImage(
        imageUrl,
        headers: _appState.jellyfinService.imageHeaders(),
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();

      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        completer.complete(info.image);
        imageStream.removeListener(listener);
      });

      imageStream.addListener(listener);
      final image = await completer.future;

      final ByteData? byteData = await image.toByteData();
      if (byteData == null) return;

      final pixels = byteData.buffer.asUint8List();

      // Process colors in isolate to avoid UI jank
      final colorInts = await compute(_extractColorsFromBytes, pixels);

      // Convert int colors back to Color objects
      final colors = colorInts.map((c) => Color(c)).toList();

      // Cache the extracted colors
      if (colors.isNotEmpty) {
        if (_paletteCache.length >= _maxCacheSize) {
          final oldestKey = _paletteCache.keys.first;
          _paletteCache.remove(oldestKey);
        }
        _paletteCache[cacheKey] = colors;
      }

      if (mounted && colors.isNotEmpty) {
        setState(() {
          _paletteColors = colors;
        });
      }
    } catch (e) {
      debugPrint('Failed to extract colors: $e');
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

  Future<void> _loadTopTracks() async {
    // Get artist's MusicBrainz ID from providerIds
    final artistMbid = widget.artist.providerIds?['MusicBrainzArtist'];
    if (artistMbid == null || artistMbid.isEmpty) {
      debugPrint('ArtistDetailScreen: No MusicBrainz ID for ${widget.artist.name}');
      return;
    }

    // Skip if offline or no network
    if (_appState.isOfflineMode || !_appState.networkAvailable) {
      return;
    }

    setState(() {
      _isLoadingTopTracks = true;
    });

    try {
      final listenbrainz = ListenBrainzService();

      // Get popular tracks from ListenBrainz
      final popularTracks = await listenbrainz.getArtistTopTracks(
        artistMbid: artistMbid,
        limit: 10, // Fetch more to increase chance of library matches
      );

      if (popularTracks.isEmpty) {
        debugPrint('ArtistDetailScreen: No popular tracks found for ${widget.artist.name}');
        if (mounted) {
          setState(() {
            _isLoadingTopTracks = false;
          });
        }
        return;
      }

      // Match popular tracks to library
      final libraryId = _appState.selectedLibraryId;
      if (libraryId == null) {
        if (mounted) {
          setState(() {
            _isLoadingTopTracks = false;
          });
        }
        return;
      }

      final matched = await listenbrainz.matchPopularTracksToLibrary(
        popularTracks: popularTracks,
        jellyfin: _appState.jellyfinService,
        libraryId: libraryId,
        maxResults: 5,
      );

      if (mounted) {
        setState(() {
          _topTracks = matched;
          _isLoadingTopTracks = false;
        });
      }
    } catch (e) {
      debugPrint('ArtistDetailScreen: Error loading top tracks: $e');
      if (mounted) {
        setState(() {
          _isLoadingTopTracks = false;
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
      artwork = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: (_paletteColors?.isNotEmpty ?? false)
                  ? _paletteColors!.first.withValues(alpha: 0.4)
                  : Colors.black26,
              blurRadius: 24,
              spreadRadius: 4,
            ),
          ],
        ),
        child: ClipOval(
          child: JellyfinImage(
            itemId: artist.id,
            imageTag: tag,
            artistId: artist.id,
            maxWidth: 800,
            boxFit: BoxFit.cover,
            errorBuilder: (context, url, error) => _DefaultArtistArtwork(),
          ),
        ),
      );
    } else {
      artwork = _DefaultArtistArtwork();
    }

    // Build gradient colors from palette or use fallback
    final gradientColors = _paletteColors != null && _paletteColors!.isNotEmpty
        ? [
            _paletteColors!.first.withValues(alpha: 0.6),
            theme.scaffoldBackgroundColor,
          ]
        : [
            theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
            theme.scaffoldBackgroundColor,
          ];

    return Scaffold(
      body: CustomScrollView(
        cacheExtent: 500,
        slivers: [
          SliverAppBar(
            expandedHeight: isDesktop ? 380 : 340,
            pinned: true,
            stretch: true,
            backgroundColor: gradientColors.first.withValues(alpha: 1.0),
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back, size: 20),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              // Instant Mix button
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.7),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.auto_awesome, size: 20),
                  ),
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

                      final mixTracks = await _appState.jellyfinService.getArtistMix(
                        artistId: widget.artist.id,
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
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Gradient background
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: gradientColors,
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.9],
                      ),
                    ),
                  ),
                  // Artist image centered
                  Positioned(
                    top: 80,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: SizedBox(
                        width: isDesktop ? 220 : 180,
                        height: isDesktop ? 220 : 180,
                        child: artwork,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Artist info section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Artist name - centered and prominent
                  Text(
                    artist.name,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  // Stats row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (artist.albumCount != null && artist.albumCount! > 0)
                        _StatChip(
                          icon: Icons.album_outlined,
                          label: '${artist.albumCount} albums',
                          color: theme.colorScheme.primary,
                        ),
                      if (artist.albumCount != null && artist.songCount != null)
                        const SizedBox(width: 16),
                      if (artist.songCount != null && artist.songCount! > 0)
                        _StatChip(
                          icon: Icons.music_note_outlined,
                          label: '${artist.songCount} songs',
                          color: theme.colorScheme.secondary,
                        ),
                    ],
                  ),
                  // Genres
                  if (artist.genres != null && artist.genres!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: artist.genres!.take(5).map((genre) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: theme.colorScheme.outline.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Text(
                            genre,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Bio section
          if (artist.overview != null && artist.overview!.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: _BioCard(
                  bio: artist.overview!,
                  expanded: _bioExpanded,
                  onToggle: () => setState(() => _bioExpanded = !_bioExpanded),
                  paletteColor: _paletteColors?.isNotEmpty == true
                      ? _paletteColors!.first
                      : null,
                ),
              ),
            ),
          // Top Tracks section
          if (_topTracks != null && _topTracks!.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.trending_up_rounded,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Popular',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...List.generate(_topTracks!.length, (index) {
                      final track = _topTracks![index];
                      return _TopTrackTile(
                        track: track,
                        rank: index + 1,
                        appState: _appState,
                        accentColor: _paletteColors?.isNotEmpty == true
                            ? _paletteColors!.first
                            : theme.colorScheme.primary,
                        onTap: () async {
                          try {
                            await _appState.audioPlayerService.playTrack(
                              track,
                              queueContext: _topTracks,
                              albumId: track.albumId,
                              albumName: track.album,
                            );
                          } catch (error) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Could not start playback: $error'),
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          }
                        },
                      );
                    }),
                  ],
                ),
              ),
            )
          else if (_isLoadingTopTracks)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.trending_up_rounded,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Popular',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Albums section header
          if (_albums != null && _albums!.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
                child: Row(
                  children: [
                    Icon(
                      Icons.album_outlined,
                      size: 22,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Discography',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Content area
          if (_isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverPadding(
              padding: const EdgeInsets.all(20),
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
              padding: const EdgeInsets.all(20),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: Text(
                    'No albums found',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isDesktop ? 5 : 3,
                  childAspectRatio: 0.78,
                  crossAxisSpacing: 12,
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

/// Stat chip widget for album/song count
class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Bio card with expandable text
class _BioCard extends StatelessWidget {
  const _BioCard({
    required this.bio,
    required this.expanded,
    required this.onToggle,
    this.paletteColor,
  });

  final String bio;
  final bool expanded;
  final VoidCallback onToggle;
  final Color? paletteColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = paletteColor ?? theme.colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.15),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: accentColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'About',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: accentColor,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                AnimatedCrossFade(
                  firstChild: Text(
                    bio,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  secondChild: Text(
                    bio,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  crossFadeState: expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 200),
                ),
              ],
            ),
          ),
        ),
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
        maxWidth: 200,
        boxFit: BoxFit.cover,
        errorBuilder: (context, url, error) => Container(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            Icons.album,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      artwork = Container(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.album,
          size: 32,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AlbumDetailScreen(
                album: album,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.shadow.withValues(alpha: 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: artwork,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.name,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (album.productionYear != null)
              Text(
                '${album.productionYear}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TopTrackTile extends StatelessWidget {
  const _TopTrackTile({
    required this.track,
    required this.rank,
    required this.appState,
    required this.onTap,
    this.accentColor,
  });

  final JellyfinTrack track;
  final int rank;
  final NautuneAppState appState;
  final VoidCallback onTap;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = track.duration;
    final durationText = duration != null ? _formatDuration(duration) : '--:--';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                // Rank number with accent styling for top 3
                SizedBox(
                  width: 28,
                  child: Text(
                    '$rank',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: rank <= 3 ? FontWeight.bold : FontWeight.normal,
                      color: rank <= 3
                          ? (accentColor ?? theme.colorScheme.primary)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 12),
                // Album artwork with shadow
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.shadow.withValues(alpha: 0.1),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 50,
                      height: 50,
                      child: (track.albumPrimaryImageTag != null || track.primaryImageTag != null)
                          ? JellyfinImage(
                              itemId: track.albumId ?? track.id,
                              imageTag: track.albumPrimaryImageTag ?? track.primaryImageTag ?? '',
                              trackId: track.id,
                              boxFit: BoxFit.cover,
                              errorBuilder: (context, url, error) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Icon(
                                  Icons.music_note,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Icons.music_note,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Track info (expanded)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      if (track.album != null)
                        Text(
                          track.album!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                // Duration
                Text(
                  durationText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
