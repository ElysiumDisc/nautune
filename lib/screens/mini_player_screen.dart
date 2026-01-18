import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui show Image, ImageFilter;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/jellyfin_waveform.dart';

/// Top-level function for compute() - extracts vibrant colors from image pixels in isolate
Future<List<int>> _extractColorsInIsolate(Uint32List pixels) async {
  // Run the quantization to find the dominant color clusters
  final result = await QuantizerCelebi().quantize(pixels, 128);
  final colorToCount = result.colorToCount;

  // RAW VIBRANCY SCORING
  // Score = Population * (Chroma^2)
  final sortedEntries = colorToCount.entries.toList()
    ..sort((a, b) {
      final hctA = Hct.fromInt(a.key);
      final hctB = Hct.fromInt(b.key);
      final scoreA = a.value * (hctA.chroma * hctA.chroma);
      final scoreB = b.value * (hctB.chroma * hctB.chroma);
      return scoreB.compareTo(scoreA);
    });

  final selectedColors = <int>[];

  for (final entry in sortedEntries) {
    if (selectedColors.length >= 4) break;

    final colorInt = entry.key;
    final hct = Hct.fromInt(colorInt);

    // Skip absolute greys
    if (hct.chroma < 5) continue;

    // Distinctness check
    bool isDistinct = true;
    for (final existing in selectedColors) {
      final existingHct = Hct.fromInt(existing);
      final hueDiff = (hct.hue - existingHct.hue).abs();
      final normalizedHueDiff = hueDiff > 180 ? 360 - hueDiff : hueDiff;
      if (normalizedHueDiff < 15) {
        isDistinct = false;
        break;
      }
    }

    if (isDistinct) {
      // Add with full alpha
      selectedColors.add(colorInt | 0xFF000000);
    }
  }

  // Fallback if we found nothing (e.g. B&W image)
  if (selectedColors.isEmpty) {
    final populationSorted = colorToCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in populationSorted.take(4)) {
      selectedColors.add(entry.key | 0xFF000000);
    }
  }

  return selectedColors;
}

class MiniPlayerScreen extends StatefulWidget {
  const MiniPlayerScreen({super.key});

  @override
  State<MiniPlayerScreen> createState() => _MiniPlayerScreenState();
}

class _MiniPlayerScreenState extends State<MiniPlayerScreen> with WindowListener {
  // Static LRU cache for palette colors - avoids re-extracting for frequently played albums
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxCacheSize = 50;
  
  List<Color>? _paletteColors;
  StreamSubscription? _trackSub;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    
    // Make window frameless for mini player
    _makeFrameless();
  }

  Future<void> _makeFrameless() async {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    if (_trackSub == null) {
      final appState = Provider.of<NautuneAppState>(context, listen: false);
      final audioService = appState.audioPlayerService;

      // Listen for track changes to update colors
      _trackSub = audioService.currentTrackStream.listen((track) {
        if (track != null) {
          _extractColors(track, appState);
        } else {
          if (mounted) {
            setState(() {
              _paletteColors = null;
            });
          }
        }
      });

      // Initial check
      final currentTrack = audioService.currentTrack;
      if (currentTrack != null) {
        _extractColors(currentTrack, appState);
      }
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _trackSub?.cancel();
    super.dispose();
  }

  Future<void> _restoreMainWindow() async {
    // Restore standard title bar
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);

    // Restore standard size
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setMinimumSize(const Size(400, 600));
    await windowManager.setAlignment(Alignment.center);

    // Wait for the window resize to complete before navigating
    // This prevents layout overflow errors in the full player
    await Future.delayed(const Duration(milliseconds: 100));

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _extractColors(JellyfinTrack track, NautuneAppState appState) async {
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
      if (mounted) {
        setState(() {
          _paletteColors = null;
        });
      }
      return;
    }

    // Check cache first - avoids expensive color extraction for repeat plays
    final cacheKey = '$itemId-$imageTag';
    final cached = _paletteCache[cacheKey];
    if (cached != null) {
      if (mounted) {
        setState(() {
          _paletteColors = cached;
        });
      }
      return;
    }

    // Clear old colors immediately to prevent showing stale gradient
    if (mounted) {
      setState(() {
        _paletteColors = null;
      });
    }

    try {
      // Try to load from downloaded artwork first (for offline support)
      ImageProvider imageProvider;
      final artworkFile = await appState.downloadService.getArtworkFile(track.id);

      if (artworkFile != null && await artworkFile.exists()) {
        // Use offline artwork
        imageProvider = FileImage(artworkFile);
      } else {
        // Fall back to network image
        final imageUrl = appState.jellyfinService.buildImageUrl(
          itemId: itemId,
          tag: imageTag,
          maxWidth: 100,
        );
        imageProvider = NetworkImage(
          imageUrl,
          headers: appState.jellyfinService.imageHeaders(),
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

      // Process colors in isolate to avoid UI jank
      final colorInts = await compute(_extractColorsInIsolate, pixels);

      // Convert int colors back to Color objects
      List<Color> selectedColors = colorInts.map((c) => Color(c)).toList();

      // Fallback if still empty
      if (selectedColors.isEmpty) {
        if (!mounted) return;
        final theme = Theme.of(context);
        selectedColors = [
          theme.colorScheme.primaryContainer,
          theme.colorScheme.surface,
        ];
      }

      // Cache the extracted colors for future use
      if (selectedColors.isNotEmpty) {
        // Evict oldest entries if cache is full (simple FIFO eviction)
        if (_paletteCache.length >= _maxCacheSize) {
          final oldestKey = _paletteCache.keys.first;
          _paletteCache.remove(oldestKey);
        }
        _paletteCache[cacheKey] = selectedColors;
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

  /// Build album art with proper fallback logic for itemId and imageTag
  Widget _buildAlbumArt(JellyfinTrack track) {
    // Use same fallback logic as _extractColors for consistency
    String? imageTag = track.primaryImageTag;
    String itemId = track.id;

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

    return JellyfinImage(
      itemId: itemId,
      imageTag: imageTag,
      trackId: track.id,
      boxFit: BoxFit.cover,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<NautuneAppState>(context);
    final audioService = appState.audioPlayerService;
    final theme = Theme.of(context);

    return StreamBuilder<PlayerSnapshot>(
      stream: audioService.playerSnapshotStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final track = state?.track;
        final isPlaying = state?.isPlaying ?? false;
        final position = state?.position ?? Duration.zero;
        final duration = state?.duration ?? Duration.zero;

        final backgroundColor = theme.colorScheme.surface;
        final onSurfaceColor = theme.colorScheme.onSurface;
        final primaryColor = theme.colorScheme.primary;

        return Scaffold(
          backgroundColor: backgroundColor,
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
                                _paletteColors![0],
                                _paletteColors![1],
                                _paletteColors![2],
                                _paletteColors![3],
                              ]
                            : _paletteColors!.length == 3
                                ? [
                                    _paletteColors![0],
                                    _paletteColors![1],
                                    _paletteColors![2],
                                  ]
                                : _paletteColors!.length == 2
                                    ? [
                                        _paletteColors![0],
                                        _paletteColors![1],
                                      ]
                                    : [
                                        _paletteColors![0],
                                        Colors.black,
                                      ],
                      ),
                    ),
                  ),
                ),
              // Blur layer for extra effect
              if (_paletteColors != null && _paletteColors!.isNotEmpty)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 100, sigmaY: 100),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3), // Elegant darkening
                    ),
                  ),
                ),

              // Drag area for window moving
              GestureDetector(
                onPanStart: (details) => windowManager.startDragging(),
                child: Container(color: Colors.transparent),
              ),
              
              if (track == null)
                const Center(child: Text('Not Playing'))
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Album art should be square and fit within the window height
                    final artSize = constraints.maxHeight.clamp(0.0, constraints.maxWidth * 0.4);
                    return Row(
                      children: [
                        // Album Art - constrained to prevent overflow
                        SizedBox(
                          width: artSize,
                          height: artSize,
                          child: _buildAlbumArt(track),
                        ),

                        // Info & Controls
                        Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title
                            Text(
                              track.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: onSurfaceColor,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(
                                    offset: const Offset(0, 1),
                                    blurRadius: 4,
                                    color: Colors.black.withValues(alpha: 0.5),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Artist
                            Text(
                              track.displayArtist,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: onSurfaceColor.withValues(alpha: 0.9),
                                shadows: [
                                  Shadow(
                                    offset: const Offset(0, 1),
                                    blurRadius: 2,
                                    color: Colors.black.withValues(alpha: 0.5),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            
                            const SizedBox(height: 8),
                            
                            // Controls
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  color: onSurfaceColor,
                                  onPressed: audioService.skipToPrevious,
                                  iconSize: 24,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                                Container(
                                  decoration: BoxDecoration(
                                    color: primaryColor,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  child: IconButton(
                                    icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                    color: theme.colorScheme.onPrimary,
                                    onPressed: () => isPlaying ? audioService.pause() : audioService.resume(),
                                    iconSize: 28,
                                    padding: const EdgeInsets.all(8),
                                    constraints: const BoxConstraints(),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.skip_next_rounded),
                                  color: onSurfaceColor,
                                  onPressed: audioService.skipToNext,
                                  iconSize: 24,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                ),
                              ],
                            ),
                            
                            const Spacer(),

                            // Progress Bar with Waveform
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final progress = duration.inMilliseconds > 0
                                    ? position.inMilliseconds / duration.inMilliseconds
                                    : 0.0;
                                return Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    // Waveform layer
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: -12,
                                      height: 30,
                                      child: TrackWaveform(
                                        trackId: track.id,
                                        progress: progress.clamp(0.0, 1.0),
                                        width: constraints.maxWidth,
                                        height: 30,
                                      ),
                                    ),
                                    // Progress bar on top
                                    ProgressBar(
                                      progress: position,
                                      total: duration,
                                      onSeek: audioService.seek,
                                      barHeight: 3,
                                      thumbRadius: 0,
                                      baseBarColor: onSurfaceColor.withValues(alpha: 0.3),
                                      progressBarColor: primaryColor,
                                      timeLabelLocation: TimeLabelLocation.none,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                      ],
                    );
                  },
                ),

              // Expand Button
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.open_in_full_rounded),
                  color: onSurfaceColor.withValues(alpha: 0.8),
                  tooltip: 'Expand',
                  iconSize: 18,
                  onPressed: _restoreMainWindow,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

