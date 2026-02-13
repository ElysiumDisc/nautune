import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show Image, ImageFilter;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../providers/syncplay_provider.dart';
import '../services/lyrics_service.dart';
import '../models/now_playing_layout.dart';
import '../services/playback_state_store.dart' show StreamingQuality, VisualizerPosition;
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';
import '../services/haptic_service.dart';
import '../services/ios_fft_service.dart';
import '../services/saved_loops_service.dart';
import '../services/share_service.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/visualizers/visualizer_factory.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/jellyfin_waveform.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

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

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({
    super.key,
    this.sailorMode = false,
  });

  /// When true, shows collab playlist info without waveform/FFT (for Sailors)
  final bool sailorMode;

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with SingleTickerProviderStateMixin {
  // Static LRU cache for palette colors - avoids re-extracting for frequently played albums
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxCacheSize = 50;

  StreamSubscription? _trackSub;
  late TabController _tabController;
  List<_LyricLine>? _lyrics;
  bool _loadingLyrics = false;
  String? _lyricsSource; // Track where lyrics came from
  late AudioPlayerService _audioService;
  late NautuneAppState _appState;
  late LyricsService _lyricsService;
  List<Color>? _paletteColors;

  // Lyrics scrolling state
  final ScrollController _lyricsScrollController = ScrollController();
  int _currentLyricIndex = -1;
  bool _userIsScrolling = false;
  Timer? _userScrollTimer;

  // A-B loop controls state
  StreamSubscription? _loopSub;
  bool _showLoopControls = false;
  bool _showLoopButton = false; // Toggle visibility of A-B Loop button (off by default)

  // Cached player snapshot stream (avoid resubscription per build)
  Stream<PlayerSnapshot>? _playerSnapshotStream;

  // Visualizer in album art toggle state
  bool _showingVisualizerInArtwork = false;
  String? _lastTrackIdForVisualizerReset; // Track ID to detect track changes


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
    _lyricsService = LyricsService(jellyfinService: _appState.jellyfinService);
    _playerSnapshotStream ??= _audioService.playerSnapshotStream;

    // Set up stream listeners only once
    if (_trackSub == null) {
      _trackSub = _audioService.currentTrackStream.listen((track) {
        if (mounted) {
          setState(() {
            // Reset visualizer toggle on track change (show album art for new track)
            if (track?.id != _lastTrackIdForVisualizerReset) {
              _showingVisualizerInArtwork = false;
              _lastTrackIdForVisualizerReset = track?.id;
            }
          });
          if (track != null) {
            _fetchLyrics(track);
            _extractColors(track);
          }
        }
      });
      // Position and playing state are handled by StreamBuilder<PlayerSnapshot>
      // in build() — no setState needed here (avoids double-rebuilds).
      // Only loop state needs setState since it's not in PlayerSnapshot.
      _loopSub = _audioService.loopStateStream.listen((_) {
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
    setState(() {
      _paletteColors = null;
    });

    try {
      // Try to load from downloaded artwork first (for offline support)
      ImageProvider imageProvider;
      final artworkFile = await _appState.downloadService.getArtworkFile(
        track.id,
      );

      if (artworkFile != null && await artworkFile.exists()) {
        // Use offline artwork
        imageProvider = FileImage(artworkFile);
        debugPrint(
          'Using offline artwork for gradient extraction: ${track.name}',
        );
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

  Future<void> _switchToMiniPlayer() async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // 1. Resize window to compact size
      await windowManager.setMinimumSize(const Size(300, 120));
      await windowManager.setSize(const Size(400, 160));
      await windowManager.setAlignment(Alignment.bottomRight);

      if (mounted) {
        // 2. Navigate to mini player
        Navigator.of(context).pushNamed('/mini');
      }
    }
  }

  void _showSleepTimerSheet() {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: StreamBuilder<Duration>(
          stream: _audioService.sleepTimerStream,
          builder: (context, snapshot) {
            final remaining = snapshot.data ?? Duration.zero;
            final isActive = remaining != Duration.zero;
            final isTrackMode = remaining.isNegative;
            final tracksRemaining = isTrackMode ? -remaining.inSeconds : 0;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.nightlight_round,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Sleep Timer',
                        style: theme.textTheme.titleLarge,
                      ),
                      const Spacer(),
                      if (isActive)
                        TextButton(
                          onPressed: () {
                            _audioService.cancelSleepTimer();
                            Navigator.pop(sheetContext);
                          },
                          child: const Text('Cancel'),
                        ),
                    ],
                  ),
                ),
                if (isActive) ...[
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.timer,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isTrackMode
                              ? '$tracksRemaining track${tracksRemaining == 1 ? '' : 's'} remaining'
                              : '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')} remaining',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'Stop after time',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildTimerChip(sheetContext, '15 min', const Duration(minutes: 15)),
                      _buildTimerChip(sheetContext, '30 min', const Duration(minutes: 30)),
                      _buildTimerChip(sheetContext, '45 min', const Duration(minutes: 45)),
                      _buildTimerChip(sheetContext, '60 min', const Duration(minutes: 60)),
                      _buildTimerChip(sheetContext, '90 min', const Duration(minutes: 90)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'Stop after tracks',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildTrackChip(sheetContext, '1 track', 1),
                      _buildTrackChip(sheetContext, '3 tracks', 3),
                      _buildTrackChip(sheetContext, '5 tracks', 5),
                      _buildTrackChip(sheetContext, '10 tracks', 10),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTimerChip(BuildContext sheetContext, String label, Duration duration) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        _audioService.startSleepTimer(duration);
        Navigator.pop(sheetContext);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sleep timer set for $label'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }

  Widget _buildTrackChip(BuildContext sheetContext, String label, int tracks) {
    return ActionChip(
      label: Text(label),
      onPressed: () {
        _audioService.startSleepTimerByTracks(tracks);
        Navigator.pop(sheetContext);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sleep timer set for $label'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }

  Future<void> _fetchLyrics(JellyfinTrack track) async {
    setState(() {
      _loadingLyrics = true;
      _lyrics = null;
      _lyricsSource = null;
      _currentLyricIndex = -1;
    });

    try {
      final result = await _lyricsService.getLyrics(track);

      List<_LyricLine>? parsedLyrics;
      String? source;

      if (result != null && result.isNotEmpty) {
        parsedLyrics = result.lines
            .map((line) => _LyricLine(
                  text: line.text,
                  startTicks: line.startTicks,
                ))
            .toList();
        source = result.source;
      }

      if (mounted) {
        setState(() {
          _lyrics = parsedLyrics;
          _lyricsSource = source;
          _loadingLyrics = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to fetch lyrics: $e');
      if (mounted) {
        setState(() {
          _loadingLyrics = false;
        });
      }
    }
  }

  Future<void> _refreshLyrics(JellyfinTrack track) async {
    setState(() {
      _loadingLyrics = true;
    });

    try {
      final result = await _lyricsService.refreshLyrics(track);

      List<_LyricLine>? parsedLyrics;
      String? source;

      if (result != null && result.isNotEmpty) {
        parsedLyrics = result.lines
            .map((line) => _LyricLine(
                  text: line.text,
                  startTicks: line.startTicks,
                ))
            .toList();
        source = result.source;
      }

      if (mounted) {
        setState(() {
          _lyrics = parsedLyrics;
          _lyricsSource = source;
          _loadingLyrics = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to refresh lyrics: $e');
      if (mounted) {
        setState(() {
          _loadingLyrics = false;
        });
      }
    }
  }

  String _getLyricsSourceLabel(String source) {
    switch (source) {
      case 'jellyfin':
        return 'Server';
      case 'lrclib':
        return 'LRCLIB';
      case 'lyricsovh':
        return 'lyrics.ovh';
      default:
        return source;
    }
  }

  String _getStreamingModeLabel(StreamingQuality quality) {
    switch (quality) {
      case StreamingQuality.original:
        return 'Direct';
      case StreamingQuality.high:
        return '320k';
      case StreamingQuality.normal:
        return '192k';
      case StreamingQuality.low:
        return '128k';
      case StreamingQuality.auto:
        return 'Auto';
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _trackSub?.cancel();
    _loopSub?.cancel();
    _lyricsScrollController.dispose();
    _userScrollTimer?.cancel();
    super.dispose();
  }

  void _toggleLoopControls() {
    if (!_audioService.isLoopAvailable) return;
    HapticService.mediumTap(); // Haptic feedback on iOS
    setState(() {
      _showLoopControls = !_showLoopControls;
    });
  }

  void _showLoopOptionsSheet(BuildContext context, JellyfinTrack track) {
    HapticService.mediumTap();
    final theme = Theme.of(context);
    final loopState = _audioService.loopState;
    final savedLoopsService = SavedLoopsService();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Current loop info header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.repeat_one, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current Loop',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${loopState.formattedStart} - ${loopState.formattedEnd}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // Save loop option
              ListTile(
                leading: const Icon(Icons.bookmark_add),
                title: const Text('Save Loop'),
                subtitle: Text(
                  'Save as ${track.name} (${loopState.formattedStart} - ${loopState.formattedEnd})',
                  style: theme.textTheme.bodySmall,
                ),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(sheetContext);
                  await savedLoopsService.saveLoop(
                    trackId: track.id,
                    trackName: track.name,
                    start: loopState.start!,
                    end: loopState.end!,
                  );
                  if (mounted) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Loop saved'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),

              // Edit loop option
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit Loop'),
                subtitle: const Text('Adjust A-B markers'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleLoopControls();
                },
              ),

              // Clear loop option
              ListTile(
                leading: Icon(Icons.clear, color: theme.colorScheme.error),
                title: Text(
                  'Clear Loop',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                subtitle: const Text('Stop repeating this section'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _audioService.clearLoop();
                  setState(() {
                    _showLoopControls = false;
                  });
                },
              ),

              // Show saved loops for this track if any
              FutureBuilder(
                future: savedLoopsService.initialize().then((_) => savedLoopsService.getLoopsForTrack(track.id)),
                builder: (context, snapshot) {
                  final savedLoops = snapshot.data ?? [];
                  if (savedLoops.isEmpty) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text(
                          'Saved Loops for This Track',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                      ...savedLoops.map((loop) => ListTile(
                            leading: const Icon(Icons.bookmark),
                            title: Text(loop.displayName),
                            subtitle: Text(
                              'Saved ${_formatDate(loop.createdAt)}',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _audioService.setLoopMarkers(loop.startDuration, loop.endDuration);
                              },
                            ),
                            onLongPress: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              Navigator.pop(sheetContext);
                              await savedLoopsService.deleteLoop(track.id, loop.id);
                              if (mounted) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Loop deleted'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                          )),
                    ],
                  );
                },
              ),

              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  /// Toggle visualizer display in album art area
  void _toggleVisualizerInArtwork() {
    HapticService.mediumTap();
    setState(() {
      _showingVisualizerInArtwork = !_showingVisualizerInArtwork;
    });

    // BATTERY FIX: Control iOS FFT capture based on visualizer visibility
    // Stop FFT when visualizer is hidden to prevent battery drain
    if (Platform.isIOS) {
      if (_showingVisualizerInArtwork && _audioService.isPlaying) {
        // Visualizer now visible - start FFT capture
        IOSFFTService.instance.startCapture();
      } else {
        // Visualizer hidden - stop FFT capture to save battery
        IOSFFTService.instance.stopCapture();
      }
    }
  }

  /// Build artwork with layout-specific styling
  Widget _buildLayoutStyledArtwork({
    required Widget artwork,
    required bool isDesktop,
    required Size size,
    required ThemeData theme,
  }) {
    final layout = _appState.nowPlayingLayout;

    // Size constraints based on layout
    double maxWidthFactor;
    double maxHeightFactor;

    switch (layout) {
      case NowPlayingLayout.compact:
        maxWidthFactor = isDesktop ? 0.4 : 0.65;
        maxHeightFactor = isDesktop ? 0.4 : 0.45;
        break;
      case NowPlayingLayout.fullArt:
        maxWidthFactor = 1.0;
        maxHeightFactor = 0.85;
        break;
      case NowPlayingLayout.card:
        maxWidthFactor = isDesktop ? 0.5 : 0.85;
        maxHeightFactor = isDesktop ? 0.6 : 0.55;
        break;
      default:
        maxWidthFactor = isDesktop ? 0.6 : 0.98;
        maxHeightFactor = isDesktop ? 0.7 : 0.7;
    }

    Widget styledArtwork = FittedBox(
      fit: BoxFit.contain,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isDesktop ? 1000 * maxWidthFactor : size.width * maxWidthFactor,
          maxHeight: isDesktop ? 1000 * maxHeightFactor : size.height * maxHeightFactor,
        ),
        child: AspectRatio(
          aspectRatio: 1,
          child: artwork,
        ),
      ),
    );

    // Apply layout-specific decorations
    switch (layout) {
      case NowPlayingLayout.card:
        // Card: Elevated with shadow
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 30,
                spreadRadius: 5,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: styledArtwork,
          ),
        );

      case NowPlayingLayout.blur:
        // Blur: Floating with subtle shadow
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: styledArtwork,
          ),
        );

      case NowPlayingLayout.fullArt:
        // Full Art: No rounded corners, fills more space
        return styledArtwork;

      default:
        // Classic, Gradient, Compact: Default styling
        return styledArtwork;
    }
  }

  /// Build background layers based on selected Now Playing layout
  List<Widget> _buildBackgroundLayers(ThemeData theme) {
    final layout = _appState.nowPlayingLayout;
    final hasColors = _paletteColors != null && _paletteColors!.isNotEmpty;

    switch (layout) {
      case NowPlayingLayout.classic:
      case NowPlayingLayout.gradient:
        // Classic/Gradient: Full gradient with medium blur
        return [
          if (hasColors)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: _paletteColors!.length >= 4
                        ? [_paletteColors![0], _paletteColors![1], _paletteColors![2], _paletteColors![3]]
                        : _paletteColors!.length == 3
                            ? [_paletteColors![0], _paletteColors![1], _paletteColors![2]]
                            : _paletteColors!.length == 2
                                ? [_paletteColors![0], _paletteColors![1]]
                                : [_paletteColors![0], Colors.black],
                  ),
                ),
              ),
            ),
          if (hasColors)
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 100, sigmaY: 100),
                child: Container(color: Colors.black.withValues(alpha: 0.3)),
              ),
            ),
        ];

      case NowPlayingLayout.blur:
        // Blur: Heavy frosted glass effect
        return [
          if (hasColors)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_paletteColors![0], _paletteColors!.length > 1 ? _paletteColors![1] : _paletteColors![0]],
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 150, sigmaY: 150),
              child: Container(color: Colors.black.withValues(alpha: 0.5)),
            ),
          ),
        ];

      case NowPlayingLayout.card:
        // Card: Dark/muted background, emphasis on card
        return [
          Positioned.fill(
            child: Container(
              color: theme.scaffoldBackgroundColor,
            ),
          ),
          if (hasColors)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _paletteColors![0].withValues(alpha: 0.15),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
        ];

      case NowPlayingLayout.compact:
        // Compact: Subtle gradient, less visual noise
        return [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: hasColors
                      ? [_paletteColors![0].withValues(alpha: 0.4), theme.scaffoldBackgroundColor]
                      : [theme.scaffoldBackgroundColor, theme.scaffoldBackgroundColor],
                ),
              ),
            ),
          ),
        ];

      case NowPlayingLayout.fullArt:
        // Full Art: No special background (album art fills screen)
        return [
          Positioned.fill(
            child: Container(color: Colors.black),
          ),
        ];
    }
  }

  /// Compute adaptive text color based on palette luminance.
  /// Light albums (luminance > 0.5) get dark text, dark albums get light text.
  /// Only applies to Gradient and Blur layouts.
  Color _getAdaptiveTextColor(ThemeData theme, {double alpha = 1.0}) {
    final layout = _appState.nowPlayingLayout;
    // Only apply adaptive colors for Gradient and Blur layouts
    if (layout != NowPlayingLayout.gradient && layout != NowPlayingLayout.blur) {
      return theme.colorScheme.onSurface.withValues(alpha: alpha);
    }

    // Compute average luminance from palette colors
    if (_paletteColors == null || _paletteColors!.isEmpty) {
      return theme.colorScheme.onSurface.withValues(alpha: alpha);
    }

    // Calculate average luminance of the first 2 colors (most prominent)
    double totalLuminance = 0;
    final colorsToCheck = _paletteColors!.take(2).toList();
    for (final color in colorsToCheck) {
      totalLuminance += color.computeLuminance();
    }
    final avgLuminance = totalLuminance / colorsToCheck.length;

    // WCAG recommendation: use dark text on light backgrounds, light text on dark backgrounds
    // Threshold of 0.5 is standard for luminance-based contrast decisions
    if (avgLuminance > 0.5) {
      // Light background - use dark text
      return Colors.black.withValues(alpha: alpha * 0.87);
    } else {
      // Dark background - use light text
      return Colors.white.withValues(alpha: alpha);
    }
  }

  /// Get secondary adaptive color (for subtitles, icons) with reduced opacity
  Color _getAdaptiveSecondaryColor(ThemeData theme) {
    return _getAdaptiveTextColor(theme, alpha: 0.7);
  }

  /// Build artwork container with optional visualizer toggle (when position is albumArt)
  Widget _buildArtworkVisualizerContainer({
    required Widget artwork,
    required bool isDesktop,
    required ThemeData theme,
  }) {
    final visualizerEnabled = _appState.visualizerEnabled;
    final visualizerPosition = _appState.visualizerPosition;
    final isAlbumArtPosition = visualizerPosition == VisualizerPosition.albumArt;

    // If visualizer is disabled or position is controlsBar, just return the artwork
    if (!visualizerEnabled || !isAlbumArtPosition || widget.sailorMode) {
      return artwork;
    }

    final layout = _appState.nowPlayingLayout;
    final isFullArt = layout == NowPlayingLayout.fullArt;
    final borderRadius = isFullArt ? BorderRadius.zero : BorderRadius.circular(isDesktop ? 24 : 16);

    return GestureDetector(
      onTap: _toggleVisualizerInArtwork,
      onHorizontalDragEnd: (details) {
        // Toggle on swipe if velocity is sufficient
        if (details.primaryVelocity != null && details.primaryVelocity!.abs() > 200) {
          _toggleVisualizerInArtwork();
        }
      },
      child: Stack(
        children: [
          // Album artwork layer with fade
          AnimatedOpacity(
            opacity: _showingVisualizerInArtwork ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: artwork,
          ),
          // BATTERY FIX: Only render visualizer when visible (not just hidden with opacity 0)
          // This prevents FFT processing and GPU rendering when visualizer is hidden
          if (_showingVisualizerInArtwork)
            ClipRRect(
              borderRadius: borderRadius,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  color: theme.colorScheme.surface,
                ),
                child: RepaintBoundary(
                  child: VisualizerFactory(
                    type: _appState.visualizerType,
                    audioService: _audioService,
                    opacity: 0.9, // Higher opacity for album art position
                  ),
                ),
              ),
            ),
          // Mode indicator icon (bottom-right corner)
          Positioned(
            right: 8,
            bottom: 8,
            child: AnimatedOpacity(
              opacity: 0.7,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _showingVisualizerInArtwork ? Icons.album : Icons.equalizer,
                  color: Colors.white,
                  size: isDesktop ? 24 : 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
          content: Text(
            newFavoriteStatus ? 'Added to favorites' : 'Removed from favorites',
          ),
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

  /// Build a simplified player view for Sailors (no audio output, no waveform/FFT)
  Widget _buildSailorPlayer(BuildContext context, ThemeData theme, Size size, bool isDesktop) {
    return Consumer<SyncPlayProvider>(
      builder: (context, syncPlay, _) {
        final currentTrack = syncPlay.currentTrack;
        if (currentTrack == null) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Fleet Mode'),
            ),
            body: const Center(
              child: Text('No track playing in collab session'),
            ),
          );
        }

        final track = currentTrack.track;
        final isPlaying = !syncPlay.isPaused;
        final position = syncPlay.position;
        final duration = track.duration ?? Duration.zero;

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              // Collab indicator
              Container(
                margin: const EdgeInsets.only(right: 16),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.group, size: 16, color: theme.colorScheme.onPrimaryContainer),
                    const SizedBox(width: 6),
                    Text(
                      '${syncPlay.participants.length} listening',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.3),
                  theme.colorScheme.surface,
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 40),
                  // Album art
                  Expanded(
                    flex: 3,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Container(
                          margin: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: track.albumPrimaryImageTag != null
                                ? JellyfinImage(
                                    itemId: track.albumId ?? track.id,
                                    imageTag: track.albumPrimaryImageTag!,
                                    boxFit: BoxFit.cover,
                                  )
                                : Container(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: Icon(
                                      Icons.music_note,
                                      size: 80,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Track info
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        Text(
                          track.name,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          track.displayArtist,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Added by @${currentTrack.addedByUsername}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Progress bar (simple, no waveform)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                            activeTrackColor: theme.colorScheme.primary,
                            inactiveTrackColor: theme.colorScheme.surfaceContainerHighest,
                            thumbColor: theme.colorScheme.primary,
                          ),
                          child: Slider(
                            value: duration.inMilliseconds > 0
                                ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                                : 0.0,
                            onChanged: (value) {
                              final newPosition = Duration(
                                milliseconds: (value * duration.inMilliseconds).round(),
                              );
                              syncPlay.seek(newPosition);
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _formatDuration(position),
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                _formatDuration(duration),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Playback controls
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () => syncPlay.previousTrack(),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary,
                        ),
                        child: IconButton(
                          iconSize: 48,
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: theme.colorScheme.onPrimary,
                          ),
                          onPressed: () => syncPlay.togglePlayPause(),
                        ),
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        iconSize: 36,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () => syncPlay.nextTrack(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 600;

    // Sailor mode: Use SyncPlayProvider data instead of AudioService
    if (widget.sailorMode) {
      return _buildSailorPlayer(context, theme, size, isDesktop);
    }

    // Single combined stream instead of 4 nested StreamBuilders
    // Reduces widget rebuilds by ~75% during playback
    return StreamBuilder<PlayerSnapshot>(
      stream: _playerSnapshotStream,
      initialData: PlayerSnapshot(
        track: _audioService.currentTrack,
        isPlaying: _audioService.isPlaying,
        position: _audioService.currentPosition,
        duration: _audioService.currentTrack?.duration ?? Duration.zero,
      ),
      builder: (context, snapshot) {
        final playerState = snapshot.data ?? const PlayerSnapshot();
        final track = playerState.track;
        final isPlaying = playerState.isPlaying;
        final position = playerState.position;
        final duration = playerState.duration;

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
                  Icon(
                    Icons.music_note,
                    size: 64,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(height: 16),
                  Text('No track playing', style: theme.textTheme.titleLarge),
                ],
              ),
            ),
          );
        }

        final baseArtwork = _buildArtwork(
          track: track,
          isDesktop: isDesktop,
          theme: theme,
        );

        // Wrap artwork with visualizer container if position is albumArt
        final artwork = _buildArtworkVisualizerContainer(
          artwork: baseArtwork,
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
                // Background layer - varies by layout
                ..._buildBackgroundLayers(theme),
                // Content layer
                SafeArea(
                  child: Column(
                    children: [
                      // Header with TabBar
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
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
                            if (isDesktop)
                              IconButton(
                                icon: const Icon(
                                  Icons.picture_in_picture_alt_rounded,
                                ),
                                tooltip: 'Mini Player',
                                onPressed: _switchToMiniPlayer,
                              ),
                            // Sleep Timer Button
                            StreamBuilder<Duration>(
                              stream: _audioService.sleepTimerStream,
                              builder: (context, snapshot) {
                                final remaining = snapshot.data ?? Duration.zero;
                                final isActive = remaining != Duration.zero;
                                return Stack(
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.nightlight_round,
                                        color: isActive
                                            ? theme.colorScheme.primary
                                            : null,
                                      ),
                                      tooltip: 'Sleep Timer',
                                      onPressed: _showSleepTimerSheet,
                                    ),
                                    if (isActive)
                                      Positioned(
                                        right: 4,
                                        top: 4,
                                        child: Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.primary,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert),
                              onPressed: () {
                                final parentContext = context;
                                showModalBottomSheet(
                                  context: parentContext,
                                  isScrollControlled: true,
                                  builder: (sheetContext) => SafeArea(
                                    child: SingleChildScrollView(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                        ListTile(
                                          leading: const Icon(Icons.play_arrow),
                                          title: const Text('Play Next'),
                                          onTap: () {
                                            Navigator.pop(sheetContext);
                                            _appState.audioPlayerService
                                                .playNext([track]);
                                            ScaffoldMessenger.of(
                                              parentContext,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${track.name} will play next',
                                                ),
                                                duration: const Duration(
                                                  seconds: 2,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.queue_music,
                                          ),
                                          title: const Text('Add to Queue'),
                                          onTap: () {
                                            Navigator.pop(sheetContext);
                                            _appState.audioPlayerService
                                                .addToQueue([track]);
                                            ScaffoldMessenger.of(
                                              parentContext,
                                            ).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${track.name} added to queue',
                                                ),
                                                duration: const Duration(
                                                  seconds: 2,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.playlist_add,
                                          ),
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
                                          leading: const Icon(
                                            Icons.auto_awesome,
                                          ),
                                          title: const Text('Instant Mix'),
                                          onTap: () async {
                                            Navigator.pop(sheetContext);
                                            try {
                                              ScaffoldMessenger.of(
                                                parentContext,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Creating instant mix...',
                                                  ),
                                                  duration: Duration(
                                                    seconds: 1,
                                                  ),
                                                ),
                                              );
                                              final mixTracks = await _appState
                                                  .jellyfinService
                                                  .getInstantMix(
                                                    itemId: track.id,
                                                    limit: 50,
                                                  );
                                              if (!parentContext.mounted) {
                                                return;
                                              }
                                              if (mixTracks.isEmpty) {
                                                ScaffoldMessenger.of(
                                                  parentContext,
                                                ).showSnackBar(
                                                  const SnackBar(
                                                    content: Text(
                                                      'No similar tracks found',
                                                    ),
                                                    duration: Duration(
                                                      seconds: 2,
                                                    ),
                                                  ),
                                                );
                                                return;
                                              }
                                              await _appState.audioPlayerService
                                                  .playTrack(
                                                    mixTracks.first,
                                                    queueContext: mixTracks,
                                                  );

                                              if (!parentContext.mounted) {
                                                return;
                                              }

                                              // Simple notification without persistent action button
                                              ScaffoldMessenger.of(
                                                parentContext,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Playing instant mix (${mixTracks.length} tracks)',
                                                  ),
                                                  duration: const Duration(
                                                    seconds: 2,
                                                  ),
                                                  behavior:
                                                      SnackBarBehavior.floating,
                                                ),
                                              );
                                            } catch (e) {
                                              if (!parentContext.mounted) {
                                                return;
                                              }
                                              ScaffoldMessenger.of(
                                                parentContext,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Failed to create mix: $e',
                                                  ),
                                                  backgroundColor: Theme.of(
                                                    parentContext,
                                                  ).colorScheme.error,
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
                                            final messenger =
                                                ScaffoldMessenger.of(
                                                  parentContext,
                                                );
                                            final theme = Theme.of(
                                              parentContext,
                                            );
                                            final downloadService =
                                                _appState.downloadService;
                                            try {
                                              final existing = downloadService
                                                  .getDownload(track.id);
                                              if (existing != null) {
                                                if (existing.isCompleted) {
                                                  messenger.showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        '"${track.name}" is already downloaded',
                                                      ),
                                                      duration: const Duration(
                                                        seconds: 2,
                                                      ),
                                                    ),
                                                  );
                                                  return;
                                                }
                                                if (existing.isFailed) {
                                                  await downloadService
                                                      .retryDownload(track.id);
                                                  messenger.showSnackBar(
                                                    SnackBar(
                                                      content: Text(
                                                        'Retrying download for ${track.name}',
                                                      ),
                                                      duration: const Duration(
                                                        seconds: 2,
                                                      ),
                                                    ),
                                                  );
                                                  return;
                                                }
                                                messenger.showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      '"${track.name}" is already in the download queue',
                                                    ),
                                                    duration: const Duration(
                                                      seconds: 2,
                                                    ),
                                                  ),
                                                );
                                                return;
                                              }
                                              await downloadService
                                                  .downloadTrack(track);
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Downloading ${track.name}',
                                                  ),
                                                  duration: const Duration(
                                                    seconds: 2,
                                                  ),
                                                ),
                                              );
                                            } catch (e) {
                                              messenger.showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Failed to download ${track.name}: $e',
                                                  ),
                                                  backgroundColor:
                                                      theme.colorScheme.error,
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.share),
                                          title: const Text('Share'),
                                          onTap: () async {
                                            Navigator.pop(sheetContext);
                                            final messenger = ScaffoldMessenger.of(parentContext);
                                            final theme = Theme.of(parentContext);
                                            final downloadService = _appState.downloadService;
                                            final shareService = ShareService.instance;

                                            if (!shareService.isAvailable) {
                                              messenger.showSnackBar(
                                                const SnackBar(
                                                  content: Text('Sharing not available on this platform'),
                                                  duration: Duration(seconds: 2),
                                                ),
                                              );
                                              return;
                                            }

                                            final result = await shareService.shareTrack(
                                              track: track,
                                              downloadService: downloadService,
                                            );

                                            if (!parentContext.mounted) return;

                                            switch (result) {
                                              case ShareResult.success:
                                                messenger.showSnackBar(
                                                  SnackBar(
                                                    content: Text('Shared "${track.name}"'),
                                                    duration: const Duration(seconds: 2),
                                                  ),
                                                );
                                                break;
                                              case ShareResult.cancelled:
                                                break;
                                              case ShareResult.notDownloaded:
                                                final shouldDownload = await showDialog<bool>(
                                                  context: parentContext,
                                                  builder: (dialogContext) => AlertDialog(
                                                    title: const Text('Track Not Downloaded'),
                                                    content: Text(
                                                      'To share "${track.name}", it needs to be downloaded first. '
                                                      'Would you like to download it now?'
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () => Navigator.pop(dialogContext, false),
                                                        child: const Text('Cancel'),
                                                      ),
                                                      FilledButton(
                                                        onPressed: () => Navigator.pop(dialogContext, true),
                                                        child: const Text('Download'),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                                if (shouldDownload == true && parentContext.mounted) {
                                                  await downloadService.downloadTrack(track);
                                                  messenger.showSnackBar(
                                                    SnackBar(
                                                      content: Text('Downloading "${track.name}"...'),
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                }
                                                break;
                                              case ShareResult.fileNotFound:
                                                messenger.showSnackBar(
                                                  SnackBar(
                                                    content: Text('File for "${track.name}" not found'),
                                                    backgroundColor: theme.colorScheme.error,
                                                    duration: const Duration(seconds: 3),
                                                  ),
                                                );
                                                break;
                                              case ShareResult.error:
                                                messenger.showSnackBar(
                                                  SnackBar(
                                                    content: Text('Failed to share "${track.name}"'),
                                                    backgroundColor: theme.colorScheme.error,
                                                    duration: const Duration(seconds: 3),
                                                  ),
                                                );
                                                break;
                                            }
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.lyrics),
                                          title: const Text('Refresh Lyrics'),
                                          subtitle: Text(
                                            _lyricsSource != null
                                                ? 'Source: ${_getLyricsSourceLabel(_lyricsSource!)}'
                                                : 'Fetch new lyrics',
                                          ),
                                          onTap: () {
                                            Navigator.pop(sheetContext);
                                            _refreshLyrics(track);
                                            ScaffoldMessenger.of(parentContext).showSnackBar(
                                              const SnackBar(
                                                content: Text('Refreshing lyrics...'),
                                                duration: Duration(seconds: 1),
                                              ),
                                            );
                                          },
                                        ),
                                        StatefulBuilder(
                                          builder: (context, setMenuState) {
                                            return SwitchListTile(
                                              secondary: const Icon(Icons.all_inclusive),
                                              title: const Text('Infinite Radio'),
                                              subtitle: Text(
                                                _appState.infiniteRadioEnabled
                                                    ? 'Auto-adds similar tracks when queue is low'
                                                    : 'Endless playback based on current track',
                                              ),
                                              value: _appState.infiniteRadioEnabled,
                                              onChanged: (value) {
                                                _appState.toggleInfiniteRadio(value);
                                                setMenuState(() {});
                                              },
                                            );
                                          },
                                        ),
                                        if (_audioService.isLoopAvailable)
                                          StatefulBuilder(
                                            builder: (context, setMenuState) {
                                              return SwitchListTile(
                                                secondary: const Icon(Icons.repeat),
                                                title: const Text('Show A-B Loop'),
                                                subtitle: const Text('Repeat section controls'),
                                                value: _showLoopButton,
                                                onChanged: (value) {
                                                  setMenuState(() {
                                                    _showLoopButton = value;
                                                  });
                                                  setState(() {});
                                                },
                                              );
                                            },
                                          ),
                                      ],
                                    ),
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Guard against too-small constraints (e.g., during window resize)
              if (constraints.maxHeight < 200) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  // Top section: Artwork and Track Info
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Artwork - Styled based on layout
                        Flexible(
                          child: _buildLayoutStyledArtwork(
                            artwork: artwork,
                            isDesktop: isDesktop,
                            size: size,
                            theme: theme,
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Track Info - Compact with adaptive colors
                        Text(
                          track.name,
                          style:
                              (isDesktop
                                      ? theme.textTheme.headlineMedium
                                      : theme.textTheme.titleLarge)
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: _getAdaptiveTextColor(theme),
                                  ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),

                        // Radio indicator
                        if (_appState.audioPlayerService.infiniteRadioEnabled) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.radio, size: 14, color: theme.colorScheme.onPrimaryContainer),
                                const SizedBox(width: 4),
                                Text(
                                  'RADIO',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 8),

                        // Artist - clickable to navigate to artist detail
                        GestureDetector(
                          onTap: () async {
                            // Get the artist name from the track
                            final artistName = track.artists.isNotEmpty
                                ? track.artists.first
                                : track.displayArtist;

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
                              artist = artists
                                  .where(
                                    (a) =>
                                        a.name.toLowerCase() ==
                                        artistName.toLowerCase(),
                                  )
                                  .firstOrNull;

                              // If not found, keep loading more pages until we find it or run out
                              if (artist == null && _appState.hasMoreArtists) {
                                for (int i = 0; i < 10; i++) {
                                  // Max 10 pages = 500 artists
                                  await _appState.loadMoreArtists();
                                  artists = _appState.artists ?? [];

                                  artist = artists
                                      .where(
                                        (a) =>
                                            a.name.toLowerCase() ==
                                            artistName.toLowerCase(),
                                      )
                                      .firstOrNull;

                                  if (artist != null ||
                                      !_appState.hasMoreArtists) {
                                    break;
                                  }
                                }
                              }

                              // If still not found, try downloads for offline mode
                              if (artist == null) {
                                final downloads = _appState
                                    .downloadService
                                    .completedDownloads;
                                final artistTracks = downloads
                                    .where(
                                      (d) => d.track.artists.any(
                                        (a) =>
                                            a.toLowerCase() ==
                                            artistName.toLowerCase(),
                                      ),
                                    )
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
                                  builder: (context) =>
                                      ArtistDetailScreen(artist: artist!),
                                ),
                              );
                            } else {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Could not find artist "$artistName"',
                                  ),
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
                                color: _getAdaptiveSecondaryColor(theme),
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  track.displayArtist,
                                  style:
                                      (isDesktop
                                              ? theme.textTheme.headlineSmall
                                              : theme.textTheme.titleMedium)
                                          ?.copyWith(
                                            color: _getAdaptiveSecondaryColor(theme),
                                            decoration:
                                                TextDecoration.underline,
                                            decorationColor: _getAdaptiveSecondaryColor(theme).withValues(alpha: 0.5),
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
                              var album = albums
                                  .where((a) => a.id == track.albumId)
                                  .firstOrNull;

                              // If not found in cache and we're online, fetch from server
                              if (album == null && !_appState.isOfflineMode) {
                                try {
                                  album = await _appState.jellyfinService
                                      .getAlbum(track.albumId!);
                                } catch (_) {
                                  // Fall through to downloads fallback
                                }
                              }

                              // If still not found, try to create from downloads
                              if (album == null) {
                                final downloads = _appState
                                    .downloadService
                                    .completedDownloads;
                                final albumTracks = downloads
                                    .where(
                                      (d) => d.track.albumId == track.albumId,
                                    )
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

                              if (!context.mounted) return;
                              if (album != null) {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        AlbumDetailScreen(album: album!),
                                  ),
                                );
                              } else {
                                // Album not available
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Album "${track.album}" not available',
                                    ),
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
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    track.album!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      decoration: TextDecoration.underline,
                                      decorationColor: theme
                                          .colorScheme
                                          .onSurfaceVariant
                                          .withValues(alpha: 0.3),
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

                        // Audio quality info with streaming mode (stacked vertically)
                        if (track.audioQualityInfo != null) ...[
                          const SizedBox(height: 8),
                          // File quality badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: theme.colorScheme.outline.withValues(
                                  alpha: 0.2,
                                ),
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
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Streaming mode badge (below file quality)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  _appState.streamingQuality ==
                                      StreamingQuality.original
                                  ? theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.5)
                                  : theme.colorScheme.secondaryContainer
                                        .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color:
                                    _appState.streamingQuality ==
                                        StreamingQuality.original
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.3,
                                      )
                                    : theme.colorScheme.secondary.withValues(
                                        alpha: 0.3,
                                      ),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _appState.streamingQuality ==
                                          StreamingQuality.original
                                      ? Icons.high_quality
                                      : Icons.compress,
                                  size: 14,
                                  color:
                                      _appState.streamingQuality ==
                                          StreamingQuality.original
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.secondary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _getStreamingModeLabel(
                                    _appState.streamingQuality,
                                  ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color:
                                        _appState.streamingQuality ==
                                            StreamingQuality.original
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.secondary,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Spacer for waveform (waveform extends 16px above progress bar)
                  const SizedBox(height: 24),

                  // Bottom section: Controls with bioluminescent visualizer
                  Stack(
                    children: [
                      // Visualizer behind controls (disabled for Sailors - no audio)
                      // Only shown when visualizerPosition is controlsBar
                      // Wrapped in RepaintBoundary to isolate repaints from parent layout
                      if (_appState.visualizerEnabled &&
                          !widget.sailorMode &&
                          _appState.visualizerPosition == VisualizerPosition.controlsBar)
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: VisualizerFactory(
                              type: _appState.visualizerType,
                              audioService: _audioService,
                              opacity: 0.4,
                            ),
                          ),
                        ),
                      // Controls on top
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Progress Slider with A-B Loop support
                          StreamBuilder<PositionData>(
                        stream: _audioService.positionDataStream,
                        builder: (context, snapshot) {
                          final positionData =
                              snapshot.data ??
                              const PositionData(
                                Duration.zero,
                                Duration.zero,
                                Duration.zero,
                              );
                          final track = _audioService.currentTrack;
                          final progress = positionData.duration.inMilliseconds > 0
                              ? positionData.position.inMilliseconds / positionData.duration.inMilliseconds
                              : 0.0;
                          final loopState = _audioService.loopState;
                          final isLoopAvailable = _audioService.isLoopAvailable;

                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24.0,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // A-B Loop controls overlay
                                if (_showLoopControls && isLoopAvailable)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        // Set A button
                                        _LoopMarkerButton(
                                          label: 'A',
                                          isSet: loopState.start != null,
                                          time: loopState.formattedStart,
                                          onTap: () => _audioService.setLoopStart(),
                                          color: theme.colorScheme.primary,
                                        ),
                                        const SizedBox(width: 12),
                                        // Set B button
                                        _LoopMarkerButton(
                                          label: 'B',
                                          isSet: loopState.end != null,
                                          time: loopState.formattedEnd,
                                          onTap: loopState.start != null
                                              ? () => _audioService.setLoopEnd()
                                              : null,
                                          color: theme.colorScheme.primary,
                                        ),
                                        const SizedBox(width: 12),
                                        // Toggle loop active
                                        if (loopState.hasValidLoop)
                                          IconButton(
                                            icon: Icon(
                                              loopState.isActive
                                                  ? Icons.repeat_one
                                                  : Icons.repeat_one_outlined,
                                              color: loopState.isActive
                                                  ? theme.colorScheme.primary
                                                  : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                            ),
                                            onPressed: () => _audioService.toggleLoop(),
                                            tooltip: loopState.isActive ? 'Disable loop' : 'Enable loop',
                                          ),
                                        const SizedBox(width: 4),
                                        // Clear loop
                                        if (loopState.hasMarkers)
                                          IconButton(
                                            icon: Icon(
                                              Icons.clear,
                                              color: theme.colorScheme.error,
                                            ),
                                            onPressed: () => _audioService.clearLoop(),
                                            tooltip: 'Clear loop markers',
                                          ),
                                        const Spacer(),
                                        // Done button
                                        TextButton(
                                          onPressed: _toggleLoopControls,
                                          child: Text(
                                            'Done',
                                            style: TextStyle(
                                              color: theme.colorScheme.primary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                // Progress bar with loop visualization
                                // Long-press (touch) or right-click (mouse) to show A-B loop controls
                                GestureDetector(
                                  onLongPress: isLoopAvailable ? _toggleLoopControls : null,
                                  onSecondaryTap: isLoopAvailable ? _toggleLoopControls : null,
                                  behavior: HitTestBehavior.translucent,
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          // Loop region overlay
                                          if (loopState.hasValidLoop && positionData.duration.inMilliseconds > 0)
                                            Positioned(
                                              left: (loopState.start!.inMilliseconds / positionData.duration.inMilliseconds) * constraints.maxWidth,
                                              top: -2,
                                              width: ((loopState.end!.inMilliseconds - loopState.start!.inMilliseconds) / positionData.duration.inMilliseconds) * constraints.maxWidth,
                                              height: 8,
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: loopState.isActive
                                                      ? theme.colorScheme.primary.withValues(alpha: 0.3)
                                                      : theme.colorScheme.onSurface.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                  border: Border.all(
                                                    color: loopState.isActive
                                                        ? theme.colorScheme.primary
                                                        : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                                                    width: 1,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // Waveform layer (disabled for Sailors - no cached audio file)
                                          if (track != null && !widget.sailorMode)
                                            Positioned(
                                              left: 0,
                                              right: 0,
                                              top: -16,
                                              height: 40,
                                              child: TrackWaveform(
                                                trackId: track.id,
                                                progress: progress.clamp(0.0, 1.0),
                                                width: constraints.maxWidth,
                                                height: 40,
                                              ),
                                            ),
                                          // Progress bar on top
                                          ProgressBar(
                                            progress: positionData.position,
                                            buffered: positionData.bufferedPosition,
                                            total: positionData.duration,
                                            onSeek: _audioService.seek,
                                            barHeight: 4.0,
                                            thumbRadius: 8.0,
                                            thumbGlowRadius: 20.0,
                                            progressBarColor: theme.colorScheme.secondary,
                                            baseBarColor: theme.colorScheme.secondary
                                                .withValues(alpha: 0.2),
                                            bufferedBarColor: theme.colorScheme.secondary
                                                .withValues(alpha: 0.1),
                                            thumbColor: theme.colorScheme.secondary,
                                            timeLabelLocation: TimeLabelLocation.below,
                                            timeLabelPadding: 8.0,
                                            timeLabelTextStyle: theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 8),

                      // Volume Slider (optional - can be hidden in settings)
                      if (_appState.showVolumeBar)
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
                                        activeTrackColor:
                                            theme.colorScheme.tertiary,
                                        inactiveTrackColor: theme
                                            .colorScheme
                                            .tertiary
                                            .withValues(alpha: 0.2),
                                        thumbColor: theme.colorScheme.tertiary,
                                        overlayColor: theme.colorScheme.tertiary
                                            .withValues(alpha: 0.1),
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

                      // A-B Loop button (when enabled in menu and loop available but not active)
                      if (_showLoopButton && _audioService.isLoopAvailable && !_audioService.loopState.isActive)
                        TextButton.icon(
                          onPressed: _toggleLoopControls,
                          icon: Icon(
                            Icons.repeat,
                            size: 14,
                            color: _showLoopControls
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                          label: Text(
                            'A-B Loop',
                            style: TextStyle(
                              fontSize: 11,
                              color: _showLoopControls
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),

                      // Loop indicator when active (clickable to show options)
                      if (_audioService.loopState.isActive)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: GestureDetector(
                            onTap: () => _showLoopOptionsSheet(context, track),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.repeat_one,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${_audioService.loopState.formattedStart} - ${_audioService.loopState.formattedEnd}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.bookmark_add_outlined,
                                    size: 14,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      const SizedBox(height: 16),

                      // Playback Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: Icon(
                              track.isFavorite
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: isDesktop ? 32 : 26,
                            ),
                            onPressed: () async {
                              try {
                                final currentFavoriteStatus = track.isFavorite;
                                final newFavoriteStatus =
                                    !currentFavoriteStatus;

                                debugPrint(
                                  '🎯 Favorite button clicked: current=$currentFavoriteStatus, new=$newFavoriteStatus',
                                );

                                // Update Jellyfin server (with offline queue support)
                                await _appState.markFavorite(
                                  track.id,
                                  newFavoriteStatus,
                                );

                                // Update track object with new favorite status
                                final updatedTrack = track.copyWith(
                                  isFavorite: newFavoriteStatus,
                                );
                                debugPrint(
                                  '🔄 Updating track: old isFavorite=${track.isFavorite}, new isFavorite=${updatedTrack.isFavorite}',
                                );
                                _audioService.updateCurrentTrack(updatedTrack);

                                // Force UI rebuild
                                if (mounted) setState(() {});

                                // Refresh favorites list in app state
                                await _appState.refreshFavorites();

                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      newFavoriteStatus
                                          ? 'Added to favorites'
                                          : 'Removed from favorites',
                                    ),
                                    duration: const Duration(seconds: 2),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              } catch (e) {
                                debugPrint('❌ Error toggling favorite: $e');
                                if (!context.mounted) return;
                                final isOfflineError =
                                    e.toString().contains('Offline') ||
                                    e.toString().contains('queued');

                                // Update track optimistically even when offline
                                if (isOfflineError) {
                                  final currentFavoriteStatus =
                                      track.isFavorite;
                                  final newFavoriteStatus =
                                      !currentFavoriteStatus;
                                  final updatedTrack = track.copyWith(
                                    isFavorite: newFavoriteStatus,
                                  );
                                  _audioService.updateCurrentTrack(
                                    updatedTrack,
                                  );
                                  if (mounted) setState(() {});
                                }

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      isOfflineError
                                          ? 'Offline: Favorite will sync when online'
                                          : 'Failed to update favorite: $e',
                                    ),
                                    backgroundColor: isOfflineError
                                        ? Colors.orange
                                        : theme.colorScheme.error,
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
                            icon: Icon(Icons.stop, size: isDesktop ? 40 : 32),
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
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.4,
                                  ),
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
                              final repeatMode =
                                  snapshot.data ?? RepeatMode.off;
                              final IconData icon;
                              final Color? color;

                              switch (repeatMode) {
                                case RepeatMode.off:
                                  icon = Icons.repeat;
                                  color = null;
                                case RepeatMode.all:
                                  icon = Icons.repeat;
                                  color = theme.colorScheme.primary;
                                case RepeatMode.one:
                                  icon = Icons.repeat_one;
                                  color = theme.colorScheme.primary;
                              }

                              return IconButton(
                                icon: Icon(
                                  icon,
                                  size: isDesktop ? 32 : 26,
                                  color: color,
                                ),
                                onPressed: () =>
                                    _audioService.toggleRepeatMode(),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                    ],
                  ),
                ],
              );
            },
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

    if (_lyrics == null || _lyrics!.isEmpty) {
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
            Text('No lyrics available', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              'Lyrics not found for this track',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => _refreshLyrics(track),
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      );
    }

    // Find current lyric based on position
    final currentTicks = position.inMicroseconds * 10;
    int activeIndex = 0;
    for (int i = 0; i < _lyrics!.length; i++) {
      final lineTicks = _lyrics![i].startTicks;
      if (lineTicks != null && lineTicks <= currentTicks) {
        activeIndex = i;
      }
    }

    // Trigger auto-scroll if index changed and user is not scrolling
    // We check if the index actually advanced or changed to avoid redundant scrolling calls
    if (activeIndex != _currentLyricIndex) {
      _currentLyricIndex = activeIndex;
      if (!_userIsScrolling) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Ensure the key exists and context is available before scrolling
          if (activeIndex >= 0 && activeIndex < _lyrics!.length) {
            final key = _lyrics![activeIndex].key;
            if (key.currentContext != null) {
              Scrollable.ensureVisible(
                key.currentContext!,
                alignment: 0.5, // Center the item
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          }
        });
      }
    }

    return Stack(
      children: [
        NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            if (notification.direction != ScrollDirection.idle) {
              _userIsScrolling = true;
              _userScrollTimer?.cancel();
              _userScrollTimer = Timer(const Duration(seconds: 2), () {
                if (mounted) {
                  // Reset scrolling state after timeout
                  setState(() {
                    _userIsScrolling = false;
                  });
                }
              });
            }
            return false;
          },
          child: SingleChildScrollView(
            controller: _lyricsScrollController,
            // Add large padding to allow scrolling top/bottom items to center
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(_lyrics!.length, (index) {
                final line = _lyrics![index];
                final isCurrent = index == activeIndex;
                final isPast = index < activeIndex;

                return GestureDetector(
                  key: line.key, // Assign the GlobalKey here
                  onTap: () {
                    if (line.startTicks != null) {
                      // Jellyfin ticks are 100ns units
                      final microseconds = line.startTicks! ~/ 10;
                      _audioService.seek(Duration(microseconds: microseconds));
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: theme.textTheme.titleLarge!.copyWith(
                        color: isCurrent
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: isPast ? 0.3 : 0.6,
                              ),
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        fontSize: isCurrent ? 28 : 20,
                        height: 1.4,
                        shadows: isCurrent
                            ? [
                                Shadow(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.4,
                                  ),
                                  blurRadius: 12,
                                  offset: const Offset(0, 2),
                                ),
                              ]
                            : [],
                      ),
                      textAlign: TextAlign.center,
                      child: Text(line.text.isEmpty ? '♫' : line.text),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        // Source indicator removed - now in three-dot menu
      ],
    );
  }

  Widget _buildArtwork({
    required JellyfinTrack track,
    required bool isDesktop,
    required ThemeData theme,
  }) {
    final layout = _appState.nowPlayingLayout;
    final isFullArt = layout == NowPlayingLayout.fullArt;

    // Full Art layout: no rounded corners; others: rounded
    final borderRadius = isFullArt
        ? BorderRadius.zero
        : BorderRadius.circular(isDesktop ? 24 : 16);
    final maxWidth = isDesktop ? 1024 : 800;
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer,
      child: Icon(
        Icons.album,
        size: isDesktop ? 160 : 100,
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

    // Full Art: no shadow, no container decoration
    if (isFullArt) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: AspectRatio(
          aspectRatio: 1,
          child: (imageTag != null && imageTag.isNotEmpty)
              ? JellyfinImage(
                  key: ValueKey('$itemId-$imageTag-fullart'),
                  itemId: itemId,
                  imageTag: imageTag,
                  trackId: track.id,
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
      );
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
  _LyricLine({required this.text, this.startTicks});

  final String text;
  final int? startTicks; // Jellyfin uses ticks (100 nanoseconds)
  final GlobalKey key = GlobalKey();
}

/// A-B loop marker button widget
class _LoopMarkerButton extends StatelessWidget {
  const _LoopMarkerButton({
    required this.label,
    required this.isSet,
    required this.time,
    required this.onTap,
    required this.color,
  });

  final String label;
  final bool isSet;
  final String time;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSet
              ? color.withValues(alpha: 0.2)
              : theme.colorScheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSet
                ? color
                : isEnabled
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.15),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isSet
                    ? color
                    : isEnabled
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              time,
              style: TextStyle(
                fontSize: 12,
                color: isSet
                    ? color
                    : isEnabled
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.7)
                        : theme.colorScheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
