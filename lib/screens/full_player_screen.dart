import 'dart:async';
import 'dart:ui' as ui show Image, ImageFilter;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/jellyfin_image.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> with SingleTickerProviderStateMixin {
  StreamSubscription? _trackSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _playingSub;
  late TabController _tabController;
  Map<String, dynamic>? _lyricsData;
  bool _loadingLyrics = false;
  late AudioPlayerService _audioService;
  late NautuneAppState _appState;
  List<Color>? _paletteColors;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get services from Provider
    _appState = Provider.of<NautuneAppState>(context, listen: false);
    _audioService = _appState.audioService;

    // Set up stream listeners only once
    if (_trackSub == null) {
      _trackSub = _audioService.currentTrackStream.listen((track) {
        if (mounted) {
          setState(() {});
          if (track != null) {
            _fetchLyrics(track);
            _extractColors(track);
          }
        }
      });
      _positionSub = _audioService.positionStream.listen((_) {
        if (mounted) setState(() {});
      });
      _playingSub = _audioService.playingStream.listen((_) {
        if (mounted) setState(() {});
      });

      // Fetch lyrics for initial track
      final currentTrack = _audioService.currentTrack;
      if (currentTrack != null) {
        _fetchLyrics(currentTrack);
        _extractColors(currentTrack);
      }
    }
  }

  Future<void> _extractColors(JellyfinTrack track) async {
    // Use same fallback logic as _buildArtwork to ensure consistency
    String? imageTag = track.primaryImageTag;
    String? itemId = track.id;

    // Fallback to album art if track doesn't have its own image
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.albumPrimaryImageTag;
      itemId = track.albumId ?? track.id;
    }

    // Further fallback to parent thumb
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.parentThumbImageTag;
      itemId = track.albumId ?? track.id;
    }

    if (imageTag == null || imageTag.isEmpty) {
      setState(() {
        _paletteColors = null;
      });
      return;
    }

    // Clear old colors immediately to prevent showing stale gradient
    setState(() {
      _paletteColors = null;
    });

    try {
      // Try to load from downloaded artwork first (for offline support)
      ImageProvider imageProvider;
      final artworkFile = await _appState.downloadService.getArtworkFile(track.id);

      if (artworkFile != null && await artworkFile.exists()) {
        // Use offline artwork
        imageProvider = FileImage(artworkFile);
        debugPrint('Using offline artwork for gradient extraction: ${track.name}');
      } else {
        // Fall back to network image
        final imageUrl = _appState.jellyfinService.buildImageUrl(
          itemId: itemId,
          tag: imageTag,
          maxWidth: 100,
        );
        imageProvider = NetworkImage(
          imageUrl,
          headers: _appState.jellyfinService.imageHeaders(),
        );
      }

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();

      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) {
            completer.complete(info.image);
          }
        },
        onError: (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        },
      );

      imageStream.addListener(listener);
      ui.Image image;
      try {
        image = await completer.future.timeout(const Duration(seconds: 10));
      } finally {
        imageStream.removeListener(listener);
      }
      
      final ByteData? byteData = await image.toByteData();
      if (byteData == null) return;
      
      final pixels = byteData.buffer.asUint32List();
      
      // Run the quantization to find the dominant color clusters
      final result = await QuantizerCelebi().quantize(pixels, 128);
      final colorToCount = result.colorToCount;
      
      // RAW VIBRANCY SCORING
      // We ignore Material "suitability" and just want the colors that define the image.
      // Score = Population * (Chroma^2). 
      // This heavily favors saturated colors even if they are less frequent than dull backgrounds.
      final sortedEntries = colorToCount.entries.toList()
        ..sort((a, b) {
          final hctA = Hct.fromInt(a.key);
          final hctB = Hct.fromInt(b.key);
          
          // Chroma is 0..~120. Population is int.
          // Squaring chroma gives massive weight to vibrancy.
          final scoreA = a.value * (hctA.chroma * hctA.chroma);
          final scoreB = b.value * (hctB.chroma * hctB.chroma);
          
          return scoreB.compareTo(scoreA);
        });
      
      final selectedColors = <Color>[];
      
      for (final entry in sortedEntries) {
        if (selectedColors.length >= 4) break;
        
        final colorInt = entry.key;
        final hct = Hct.fromInt(colorInt);
        
        // Only filter pure grime/noise
        // Keep dark colors if they are vibrant (deep purple/blue)
        // Keep light colors if they are vibrant (neon yellow/cyan)
        if (hct.chroma < 5) continue; // Skip absolute greys (unless image is B&W, handled by fallback)

        // Distinctness check
        bool isDistinct = true;
        for (final existing in selectedColors) {
          // ignore: deprecated_member_use
          final existingHct = Hct.fromInt(existing.value);
          final hueDiff = (hct.hue - existingHct.hue).abs();
          final normalizedHueDiff = hueDiff > 180 ? 360 - hueDiff : hueDiff;
          
          // If hues are very close, skip (unless one is much brighter/darker?)
          // Let's just enforce hue diversity.
          if (normalizedHueDiff < 15) {
            isDistinct = false;
            break;
          }
        }
        
        if (isDistinct) {
          selectedColors.add(Color(colorInt).withValues(alpha: 1.0));
        }
      }
      
      // If we found nothing (e.g. B&W image), fall back to just population sort
      if (selectedColors.isEmpty) {
        final populationSorted = colorToCount.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        for (final entry in populationSorted.take(4)) {
           selectedColors.add(Color(entry.key).withValues(alpha: 1.0));
        }
      }
      
      // Fallback
      if (selectedColors.isEmpty) {
        if (!mounted) return;
        final theme = Theme.of(context);
        selectedColors.add(theme.colorScheme.primaryContainer);
        selectedColors.add(theme.colorScheme.surface);
      }

      if (mounted) {
        setState(() {
          _paletteColors = selectedColors;
        });
      }
    } catch (e) {
      debugPrint('Failed to extract colors: $e');
    }
  }

  Future<void> _fetchLyrics(JellyfinTrack track) async {
    setState(() {
      _loadingLyrics = true;
      _lyricsData = null;
    });

    try {
      final jellyfinService = _appState.jellyfinService;
      final lyrics = await jellyfinService.getLyrics(track.id);
      if (mounted) {
        setState(() {
          _lyricsData = lyrics;
          _loadingLyrics = false;
        });
      }
    } catch (e) {
      debugPrint('⚠️ Failed to fetch lyrics: $e');
      if (mounted) {
        setState(() {
          _loadingLyrics = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _trackSub?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final track = _audioService.currentTrack;
    final position = _audioService.currentPosition;
    final duration = track?.duration ?? Duration.zero;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _audioService.playPause();
        break;
      case LogicalKeyboardKey.arrowLeft:
        // Seek backward 10 seconds
        final newPos = position - const Duration(seconds: 10);
        _audioService.seek(newPos < Duration.zero ? Duration.zero : newPos);
        break;
      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds
        final newPos = position + const Duration(seconds: 10);
        _audioService.seek(newPos > duration ? duration : newPos);
        break;
      case LogicalKeyboardKey.arrowUp:
        // Volume up 5%
        final newVolume = (_audioService.volume + 0.05).clamp(0.0, 1.0);
        _audioService.setVolume(newVolume);
        break;
      case LogicalKeyboardKey.arrowDown:
        // Volume down 5%
        final newVolume = (_audioService.volume - 0.05).clamp(0.0, 1.0);
        _audioService.setVolume(newVolume);
        break;
      case LogicalKeyboardKey.keyN:
        // Next track
        _audioService.next();
        break;
      case LogicalKeyboardKey.keyP:
        // Previous track
        _audioService.previous();
        break;
      case LogicalKeyboardKey.keyR:
        // Toggle repeat mode
        _audioService.toggleRepeatMode();
        break;
      case LogicalKeyboardKey.keyL:
        // Toggle favorite
        if (track != null) {
          _toggleFavorite(track);
        }
        break;
    }
  }

  Future<void> _toggleFavorite(JellyfinTrack track) async {
    try {
      final currentFavoriteStatus = track.isFavorite;
      final newFavoriteStatus = !currentFavoriteStatus;

      await _appState.markFavorite(track.id, newFavoriteStatus);
      final updatedTrack = track.copyWith(isFavorite: newFavoriteStatus);
      _audioService.updateCurrentTrack(updatedTrack);

      if (mounted) setState(() {});
      await _appState.refreshFavorites();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newFavoriteStatus ? 'Added to favorites' : 'Removed from favorites'),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update favorite: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 600;

    return StreamBuilder<JellyfinTrack?>(
      stream: _audioService.currentTrackStream,
      initialData: _audioService.currentTrack,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data;

        return StreamBuilder<bool>(
          stream: _audioService.playingStream,
          initialData: _audioService.isPlaying,
          builder: (context, playingSnapshot) {
            final isPlaying = playingSnapshot.data ?? false;

            return StreamBuilder<Duration>(
              stream: _audioService.positionStream,
              initialData: _audioService.currentPosition,
              builder: (context, positionSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;

                return StreamBuilder<Duration?>(
                  stream: _audioService.durationStream,
                  initialData: track?.duration,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? track?.duration ?? Duration.zero;

                    if (track == null) {
                      return Scaffold(
                        appBar: AppBar(
                          title: const Text('Now Playing'),
                          leading: IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                        body: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.music_note, size: 64, color: theme.colorScheme.secondary),
                              const SizedBox(height: 16),
                              Text(
                                'No track playing',
                                style: theme.textTheme.titleLarge,
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    final artwork = _buildArtwork(
                      track: track,
                      isDesktop: isDesktop,
                      theme: theme,
                    );

                    return Focus(
                      autofocus: true,
                      onKeyEvent: (node, event) {
                        _handleKeyEvent(event);
                        return KeyEventResult.handled;
                      },
                      child: Scaffold(
                      body: Stack(
                        children: [
                          // Gradient background layer
                          if (_paletteColors != null && _paletteColors!.isNotEmpty)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: _paletteColors!.length >= 4
                                        ? [
                                            _paletteColors![0].withValues(alpha: 0.9),
                                            _paletteColors![1].withValues(alpha: 0.8),
                                            _paletteColors![2].withValues(alpha: 0.7),
                                            _paletteColors![3].withValues(alpha: 0.6),
                                          ]
                                        : _paletteColors!.length == 3
                                            ? [
                                                _paletteColors![0].withValues(alpha: 0.9),
                                                _paletteColors![1].withValues(alpha: 0.75),
                                                _paletteColors![2].withValues(alpha: 0.6),
                                              ]
                                            : _paletteColors!.length == 2
                                                ? [
                                                    _paletteColors![0].withValues(alpha: 0.9),
                                                    _paletteColors![1].withValues(alpha: 0.7),
                                                  ]
                                                : [
                                                    _paletteColors![0].withValues(alpha: 0.9),
                                                    Colors.black.withValues(alpha: 0.8),
                                                  ],
                                  ),
                                ),
                              ),
                            ),
                          // Blur layer for extra effect
                          if (_paletteColors != null && _paletteColors!.isNotEmpty)
                            Positioned.fill(
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(sigmaX: 120, sigmaY: 120),
                                child: Container(
                                  color: Colors.black.withValues(alpha: 0.25), // Elegant darkening
                                ),
                              ),
                            ),
                          // Content layer
                          SafeArea(
                        child: Column(
                          children: [
                            // Header with TabBar
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.expand_more),
                                    onPressed: () => Navigator.of(context).pop(),
                                  ),
                                  const Spacer(),
                                  TabBar(
                                    controller: _tabController,
                                    isScrollable: true,
                                    tabAlignment: TabAlignment.center,
                                    labelStyle: theme.textTheme.titleSmall,
                                    tabs: const [
                                      Tab(text: 'Now Playing'),
                                      Tab(text: 'Lyrics'),
                                    ],
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert),
                                    onPressed: () {
                                      final parentContext = context;
                                      showModalBottomSheet(
                                        context: parentContext,
                                        builder: (sheetContext) => SafeArea(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ListTile(
                                                leading: const Icon(Icons.play_arrow),
                                                title: const Text('Play Next'),
                                                onTap: () {
                                                  Navigator.pop(sheetContext);
                                                  _appState.audioPlayerService.playNext([track]);
                                                  ScaffoldMessenger.of(parentContext).showSnackBar(
                                                    SnackBar(
                                                      content: Text('${track.name} will play next'),
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(Icons.queue_music),
                                                title: const Text('Add to Queue'),
                                                onTap: () {
                                                  Navigator.pop(sheetContext);
                                                  _appState.audioPlayerService.addToQueue([track]);
                                                  ScaffoldMessenger.of(parentContext).showSnackBar(
                                                    SnackBar(
                                                      content: Text('${track.name} added to queue'),
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(Icons.playlist_add),
                                                title: const Text('Add to Playlist'),
                                                onTap: () async {
                                                  Navigator.pop(sheetContext);
                                                  await showAddToPlaylistDialog(
                                                    context: parentContext,
                                                    appState: _appState,
                                                    tracks: [track],
                                                  );
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(Icons.auto_awesome),
                                                title: const Text('Instant Mix'),
                                                onTap: () async {
                                                  Navigator.pop(sheetContext);
                                                  try {
                                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                                      const SnackBar(
                                                        content: Text('Creating instant mix...'),
                                                        duration: Duration(seconds: 1),
                                                      ),
                                                    );
                                                    final mixTracks = await _appState.jellyfinService.getInstantMix(
                                                      itemId: track.id,
                                                      limit: 50,
                                                    );
                                                    if (!parentContext.mounted) return;
                                                    if (mixTracks.isEmpty) {
                                                      ScaffoldMessenger.of(parentContext).showSnackBar(
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
                                                    
                                                    if (!parentContext.mounted) return;

                                                    // Simple notification without persistent action button
                                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                                      SnackBar(
                                                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                                                        duration: const Duration(seconds: 2),
                                                        behavior: SnackBarBehavior.floating,
                                                      ),
                                                    );
                                                  } catch (e) {
                                                    if (!parentContext.mounted) return;
                                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                                      SnackBar(
                                                        content: Text('Failed to create mix: $e'),
                                                        backgroundColor: Theme.of(parentContext).colorScheme.error,
                                                      ),
                                                    );
                                                  }
                                                },
                                              ),
                                              ListTile(
                                                leading: const Icon(Icons.download),
                                                title: const Text('Download Track'),
                                                onTap: () async {
                                                  Navigator.pop(sheetContext);
                                                  final messenger = ScaffoldMessenger.of(parentContext);
                                                  final theme = Theme.of(parentContext);
                                                  final downloadService = _appState.downloadService;
                                                  try {
                                                    final existing = downloadService.getDownload(track.id);
                                                    if (existing != null) {
                                                      if (existing.isCompleted) {
                                                        messenger.showSnackBar(
                                                          SnackBar(
                                                            content: Text('"${track.name}" is already downloaded'),
                                                            duration: const Duration(seconds: 2),
                                                          ),
                                                        );
                                                        return;
                                                      }
                                                      if (existing.isFailed) {
                                                        await downloadService.retryDownload(track.id);
                                                        messenger.showSnackBar(
                                                          SnackBar(
                                                            content: Text('Retrying download for ${track.name}'),
                                                            duration: const Duration(seconds: 2),
                                                          ),
                                                        );
                                                        return;
                                                      }
                                                      messenger.showSnackBar(
                                                        SnackBar(
                                                          content: Text('"${track.name}" is already in the download queue'),
                                                          duration: const Duration(seconds: 2),
                                                        ),
                                                      );
                                                      return;
                                                    }
                                                    await downloadService.downloadTrack(track);
                                                    messenger.showSnackBar(
                                                      SnackBar(
                                                        content: Text('Downloading ${track.name}'),
                                                        duration: const Duration(seconds: 2),
                                                      ),
                                                    );
                                                  } catch (e) {
                                                    messenger.showSnackBar(
                                                      SnackBar(
                                                        content: Text('Failed to download ${track.name}: $e'),
                                                        backgroundColor: theme.colorScheme.error,
                                                      ),
                                                    );
                                                  }
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),

                            Expanded(
                              child: TabBarView(
                                controller: _tabController,
                                children: [
                                  // Tab 1: Now Playing (existing content)
                                  _buildNowPlayingTab(
                                    track: track,
                                    isPlaying: isPlaying,
                                    position: position,
                                    duration: duration,
                                    isDesktop: isDesktop,
                                    theme: theme,
                                    artwork: artwork,
                                  ),

                                  // Tab 2: Lyrics
                                  _buildLyricsTab(
                                    track: track,
                                    position: position,
                                    theme: theme,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      );
    },
  );
}

  Widget _buildNowPlayingTab({
    required JellyfinTrack track,
    required bool isPlaying,
    required Duration position,
    required Duration duration,
    required bool isDesktop,
    required ThemeData theme,
    required Widget artwork,
  }) {
    return Builder(
      builder: (context) {
        final size = MediaQuery.of(context).size;
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isDesktop ? size.width * 0.15 : 24,
            vertical: 16,
          ),
          child: Column(
            children: [
              // Top section: Artwork and Track Info
              Expanded(
                flex: 3,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Artwork - Much larger now
                    Flexible(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isDesktop ? 500 : size.width * 0.85,
                          maxHeight: isDesktop ? 500 : size.height * 0.5,
                        ),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: artwork,
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Track Info - Compact
                    Text(
                      track.name,
                      style: (isDesktop
                              ? theme.textTheme.headlineMedium
                              : theme.textTheme.titleLarge)
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),

                    const SizedBox(height: 8),

                    // Artist - clickable to navigate to artist detail
                    GestureDetector(
                      onTap: () async {
                        // Get the artist name from the track
                        final artistName = track.artists.isNotEmpty ? track.artists.first : track.displayArtist;

                        // Show loading indicator
                        if (!mounted) return;
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (context) => const Center(
                            child: CircularProgressIndicator(),
                          ),
                        );

                        JellyfinArtist? artist;

                        try {
                          // First, search in already loaded artists
                          var artists = _appState.artists ?? [];
                          artist = artists.where((a) =>
                            a.name.toLowerCase() == artistName.toLowerCase()
                          ).firstOrNull;

                          // If not found, keep loading more pages until we find it or run out
                          if (artist == null && _appState.hasMoreArtists) {
                            for (int i = 0; i < 10; i++) { // Max 10 pages = 500 artists
                              await _appState.loadMoreArtists();
                              artists = _appState.artists ?? [];

                              artist = artists.where((a) =>
                                a.name.toLowerCase() == artistName.toLowerCase()
                              ).firstOrNull;

                              if (artist != null || !_appState.hasMoreArtists) {
                                break;
                              }
                            }
                          }

                          // If still not found, try downloads for offline mode
                          if (artist == null) {
                            final downloads = _appState.downloadService.completedDownloads;
                            final artistTracks = downloads
                                .where((d) => d.track.artists.any((a) =>
                                  a.toLowerCase() == artistName.toLowerCase()
                                ))
                                .map((d) => d.track)
                                .toList();

                            if (artistTracks.isNotEmpty) {
                              // Create synthetic artist for offline mode
                              artist = JellyfinArtist(
                                id: 'offline_$artistName',
                                name: artistName,
                              );
                            }
                          }
                        } finally {
                          // Close loading dialog
                          if (context.mounted) Navigator.of(context).pop();
                        }

                        if (artist != null) {
                          if (!context.mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => ArtistDetailScreen(
                                artist: artist!,
                              ),
                            ),
                          );
                        } else {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Could not find artist "$artistName"'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.person,
                            size: 16,
                            color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              track.displayArtist,
                              style: (isDesktop
                                      ? theme.textTheme.titleMedium
                                      : theme.textTheme.bodyLarge)
                                  ?.copyWith(
                                color: theme.colorScheme.tertiary,
                                decoration: TextDecoration.underline,
                                decorationColor: theme.colorScheme.tertiary.withValues(alpha: 0.5),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Album - clickable to navigate to album detail
                    if (track.album != null && track.albumId != null) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: () async {
                          // First try to find in online cache
                          final albums = _appState.albums ?? [];
                          var album = albums.where((a) => a.id == track.albumId).firstOrNull;

                          // If not found and we have downloads, create a synthetic album from downloads
                          if (album == null) {
                            final downloads = _appState.downloadService.completedDownloads;
                            final albumTracks = downloads
                                .where((d) => d.track.albumId == track.albumId)
                                .map((d) => d.track)
                                .toList();

                            if (albumTracks.isNotEmpty) {
                              // Create a synthetic JellyfinAlbum for offline mode
                              album = JellyfinAlbum(
                                id: track.albumId!,
                                name: track.album!,
                                artists: track.artists,
                                primaryImageTag: track.albumPrimaryImageTag,
                                genres: const [],
                              );
                            }
                          }

                          if (album != null) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => AlbumDetailScreen(
                                  album: album!,
                                ),
                              ),
                            );
                          } else {
                            // Album not available
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Album "${track.album}" not available offline'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.album,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                track.album!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  decoration: TextDecoration.underline,
                                  decorationColor: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Audio quality info
                    if (track.audioQualityInfo != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.outline.withValues(alpha: 0.2),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          track.audioQualityInfo!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.tertiary,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Bottom section: Controls (pinned to bottom)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress Slider
                  StreamBuilder<PositionData>(
                    stream: _audioService.positionDataStream,
                    builder: (context, snapshot) {
                      final positionData = snapshot.data ??
                          const PositionData(Duration.zero, Duration.zero, Duration.zero);
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24.0),
                        child: ProgressBar(
                          progress: positionData.position,
                          buffered: positionData.bufferedPosition,
                          total: positionData.duration,
                          onSeek: _audioService.seek,
                          barHeight: 4.0,
                          thumbRadius: 8.0,
                          thumbGlowRadius: 20.0,
                          progressBarColor: theme.colorScheme.secondary,
                          baseBarColor: theme.colorScheme.secondary.withValues(alpha: 0.2),
                          bufferedBarColor: theme.colorScheme.secondary.withValues(alpha: 0.1),
                          thumbColor: theme.colorScheme.secondary,
                          timeLabelLocation: TimeLabelLocation.below,
                          timeLabelPadding: 8.0,
                          timeLabelTextStyle: theme.textTheme.bodySmall,
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 8),

                  // Volume Slider
                  StreamBuilder<double>(
                    stream: _audioService.volumeStream,
                    initialData: _audioService.volume,
                    builder: (context, volumeSnapshot) {
                      final double volume =
                          volumeSnapshot.data ?? _audioService.volume;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Icon(Icons.volume_mute, size: 20),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: theme.colorScheme.tertiary,
                                  inactiveTrackColor: theme.colorScheme.tertiary.withValues(alpha: 0.2),
                                  thumbColor: theme.colorScheme.tertiary,
                                  overlayColor: theme.colorScheme.tertiary.withValues(alpha: 0.1),
                                ),
                                child: Slider(
                                  value: volume,
                                  min: 0,
                                  max: 1,
                                  onChanged: (value) {
                                    _audioService.setVolume(value);
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${(volume * 100).round()}%',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.volume_up, size: 20),
                          ],
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 16),

                  // Playback Controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(
                          track.isFavorite ? Icons.favorite : Icons.favorite_border,
                          size: isDesktop ? 32 : 26,
                        ),
                        onPressed: () async {
                          try {
                            final currentFavoriteStatus = track.isFavorite;
                            final newFavoriteStatus = !currentFavoriteStatus;

                            debugPrint('🎯 Favorite button clicked: current=$currentFavoriteStatus, new=$newFavoriteStatus');

                            // Update Jellyfin server (with offline queue support)
                            await _appState.markFavorite(track.id, newFavoriteStatus);

                            // Update track object with new favorite status
                            final updatedTrack = track.copyWith(isFavorite: newFavoriteStatus);
                            debugPrint('🔄 Updating track: old isFavorite=${track.isFavorite}, new isFavorite=${updatedTrack.isFavorite}');
                            _audioService.updateCurrentTrack(updatedTrack);

                            // Force UI rebuild
                            if (mounted) setState(() {});

                            // Refresh favorites list in app state
                            await _appState.refreshFavorites();

                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(newFavoriteStatus ? 'Added to favorites' : 'Removed from favorites'),
                                duration: const Duration(seconds: 2),
                                backgroundColor: Colors.green,
                              ),
                            );
                          } catch (e) {
                            debugPrint('❌ Error toggling favorite: $e');
                            if (!context.mounted) return;
                            final isOfflineError = e.toString().contains('Offline') ||
                                e.toString().contains('queued');

                            // Update track optimistically even when offline
                            if (isOfflineError) {
                              final currentFavoriteStatus = track.isFavorite;
                              final newFavoriteStatus = !currentFavoriteStatus;
                              final updatedTrack = track.copyWith(isFavorite: newFavoriteStatus);
                              _audioService.updateCurrentTrack(updatedTrack);
                              if (mounted) setState(() {});
                            }

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    isOfflineError
                                        ? 'Offline: Favorite will sync when online'
                                        : 'Failed to update favorite: $e'),
                                backgroundColor: isOfflineError ? Colors.orange : theme.colorScheme.error,
                              ),
                            );
                          }
                        },
                        color: track.isFavorite ? Colors.red : null,
                      ),

                      SizedBox(width: isDesktop ? 16 : 4),

                      IconButton(
                        icon: Icon(
                          Icons.skip_previous,
                          size: isDesktop ? 48 : 40,
                        ),
                        onPressed: () => _audioService.previous(),
                      ),

                      SizedBox(width: isDesktop ? 24 : 8),

                      IconButton(
                        icon: Icon(
                          Icons.stop,
                          size: isDesktop ? 40 : 32,
                        ),
                        onPressed: () => _audioService.stop(),
                        color: theme.colorScheme.error,
                      ),

                      SizedBox(width: isDesktop ? 24 : 8),

                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary,
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(alpha: 0.4),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            size: isDesktop ? 56 : 48,
                          ),
                          onPressed: () => _audioService.playPause(),
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),

                      SizedBox(width: isDesktop ? 24 : 8),

                      IconButton(
                        icon: Icon(
                          Icons.skip_next,
                          size: isDesktop ? 48 : 40,
                        ),
                        onPressed: () => _audioService.next(),
                      ),

                      SizedBox(width: isDesktop ? 16 : 4),

                      // Repeat button
                      StreamBuilder<RepeatMode>(
                        stream: _audioService.repeatModeStream,
                        initialData: _audioService.repeatMode,
                        builder: (context, snapshot) {
                          final repeatMode = snapshot.data ?? RepeatMode.off;
                          IconData icon;
                          Color? color;

                          switch (repeatMode) {
                            case RepeatMode.off:
                              icon = Icons.repeat;
                              color = null;
                              break;
                            case RepeatMode.all:
                              icon = Icons.repeat;
                              color = theme.colorScheme.primary;
                              break;
                            case RepeatMode.one:
                              icon = Icons.repeat_one;
                              color = theme.colorScheme.primary;
                              break;
                          }

                          return IconButton(
                            icon: Icon(
                              icon,
                              size: isDesktop ? 32 : 26,
                              color: color,
                            ),
                            onPressed: () => _audioService.toggleRepeatMode(),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLyricsTab({
    required JellyfinTrack track,
    required Duration position,
    required ThemeData theme,
  }) {
    if (_loadingLyrics) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Loading lyrics...', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    if (_lyricsData == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_note,
              size: 80,
              color: theme.colorScheme.secondary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'No lyrics available',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Lyrics not found for this track',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    // Parse lyrics data
    final lyrics = _lyricsData!['Lyrics'] as List<dynamic>?;
    if (lyrics == null || lyrics.isEmpty) {
      return Center(
        child: Text(
          'Lyrics format not supported',
          style: theme.textTheme.titleMedium,
        ),
      );
    }

    // Convert lyrics to structured format
    final lyricLines = lyrics.map((line) {
      final start = line['Start'] as int?; // ticks
      final text = line['Text'] as String? ?? '';
      return _LyricLine(
        text: text,
        startTicks: start,
      );
    }).toList();

    // Find current lyric based on position
    final currentTicks = position.inMicroseconds * 10; // convert to ticks
    int currentIndex = 0;
    for (int i = 0; i < lyricLines.length; i++) {
      final lineTicks = lyricLines[i].startTicks;
      if (lineTicks != null && lineTicks <= currentTicks) {
        currentIndex = i;
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      itemCount: lyricLines.length,
      itemBuilder: (context, index) {
        final line = lyricLines[index];
        final isCurrent = index == currentIndex;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            line.text,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              color: isCurrent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontSize: isCurrent ? 24 : 18,
              height: 1.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildArtwork({
    required JellyfinTrack track,
    required bool isDesktop,
    required ThemeData theme,
  }) {
    final borderRadius = BorderRadius.circular(isDesktop ? 24 : 16);
    final maxWidth = isDesktop ? 800 : 500;
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer,
      child: Icon(
        Icons.album,
        size: isDesktop ? 120 : 80,
        color: theme.colorScheme.onPrimaryContainer,
      ),
    );

    // Determine the best image tag and item ID to use
    String? imageTag = track.primaryImageTag;
    String? itemId = track.id;

    // Fallback to album art if track doesn't have its own image
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.albumPrimaryImageTag;
      itemId = track.albumId ?? track.id;
    }

    // Further fallback to parent thumb
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.parentThumbImageTag;
      itemId = track.albumId ?? track.id;
    }

    return Container(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
        color: theme.colorScheme.primaryContainer,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: AspectRatio(
          aspectRatio: 1,
          child: (imageTag != null && imageTag.isNotEmpty)
              ? JellyfinImage(
                  key: ValueKey('$itemId-$imageTag'),
                  itemId: itemId,
                  imageTag: imageTag,
                  trackId: track.id, // Enable offline artwork support
                  maxWidth: maxWidth,
                  boxFit: BoxFit.cover,
                  placeholderBuilder: (context, url) => Container(
                    color: theme.colorScheme.primaryContainer,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                  errorBuilder: (context, url, error) => placeholder,
                )
              : placeholder,
        ),
      ),
    );
  }
}

class _LyricLine {
  _LyricLine({
    required this.text,
    this.startTicks,
  });

  final String text;
  final int? startTicks; // Jellyfin uses ticks (100 nanoseconds)
}
