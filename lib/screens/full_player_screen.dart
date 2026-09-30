import 'dart:async';
import 'dart:math' as math;

import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../providers/now_playing_colors_provider.dart';
import '../services/lyrics_service.dart';
import '../models/now_playing_layout.dart';
import '../services/playback_state_store.dart' show StreamingQuality, VisualizerPosition;
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';
import '../services/haptic_service.dart';
import '../services/saved_loops_service.dart';
import '../widgets/ios/action_sheet.dart';
import '../widgets/ios/now_playing_route.dart';
import '../widgets/track_context_menu.dart';
import '../widgets/visualizers/visualizer_factory.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/jellyfin_waveform.dart';
import '../widgets/position_data_builder.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with SingleTickerProviderStateMixin {
  StreamSubscription? _trackSub;
  late TabController _tabController;
  List<_LyricLine>? _lyrics;
  bool _loadingLyrics = false;
  String? _lyricsSource; // Track where lyrics came from
  late AudioPlayerService _audioService;
  late NautuneAppState _appState;
  LyricsService? _lyricsService;
  // Artwork colours come from the app-wide NowPlayingColorsProvider.
  NowPlayingColorsProvider? _colorsProvider;
  List<Color>? get _paletteColors => _colorsProvider?.colors;
  double? get _cachedAvgLuminance => _colorsProvider?.avgLuminance;

  // Track the shown lyrics belong to, and the latest lyrics request: an
  // older request that finishes late (the user skipped) must not overwrite
  // the newer track's lyrics.
  String? _lyricsTrackId;
  int _lyricsRequest = 0;

  // A-B loop controls state
  StreamSubscription? _loopSub;
  bool _showLoopControls = false;
  bool _showLoopButton = false; // Toggle visibility of A-B Loop button (off by default)

  // Cached (avoids resubscription per build): the page itself only rebuilds
  // on track / playing changes. Its StreamBuilder is the root of build() and
  // never remounts. Position drives just the progress bar and the lyrics
  // list, each of which subscribes itself when it mounts (PositionDataBuilder,
  // _SyncedLyricsView), so switching tabs can't re-listen a used stream.
  Stream<TrackPlayingState>? _trackPlayingStream;

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
    if (_colorsProvider == null) {
      _colorsProvider = context.read<NowPlayingColorsProvider>();
      _colorsProvider!.addListener(_onColorsChanged);
    }
    _audioService = _appState.audioService;
    _lyricsService ??= LyricsService(
      jellyfinService: _appState.jellyfinService,
      isOffline: () => _appState.isOfflineMode,
    );
    _trackPlayingStream ??= _audioService.trackPlayingStream;

    // Set up stream listeners only once
    if (_trackSub == null) {
      _trackSub = _audioService.currentTrackStream.listen((track) {
        if (!mounted) return;
        // Reset visualizer toggle on track change (show album art for new
        // track). The track itself reaches the page through its
        // StreamBuilder; no rebuild needed for a same-track update.
        if (track?.id != _lastTrackIdForVisualizerReset) {
          setState(() {
            _showingVisualizerInArtwork = false;
            _lastTrackIdForVisualizerReset = track?.id;
          });
        }
        if (track != null) {
          _fetchLyrics(track);
        }
      });
      // Playing state is handled by StreamBuilder<TrackPlayingState> in
      // build(), position by the progress bar / lyrics builders — no
      // setState needed here (avoids double-rebuilds).
      // Only loop state needs setState since it's not in TrackPlayingState.
      _loopSub = _audioService.loopStateStream.listen((_) {
        if (mounted) setState(() {});
      });

      // Fetch lyrics for initial track
      final currentTrack = _audioService.currentTrack;
      if (currentTrack != null) {
        _fetchLyrics(currentTrack);
      }
    }
  }

  void _showTrackMenu(BuildContext ctx, JellyfinTrack track) {
    final parentContext = ctx;
    showTrackContextMenu(
      context: parentContext,
      track: track,
      appState: _appState,
      showGoToArtist: false,
      showGoToAlbum: false,
      showTrackInfo: false,
      // Player-specific controls follow the shared track actions.
      extraActionsBuilder: (sheetContext) => [
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Playback Speed'),
          trailing: Text('${_appState.playbackSpeed}×'),
          onTap: () async {
            Navigator.pop(sheetContext);
            final speed = await showNautuneActionSheet<double>(
              parentContext,
              title: 'Playback Speed',
              actions: [
                for (final s in const [0.75, 1.0, 1.25, 1.5, 2.0])
                  NautuneSheetAction(
                    label: s == 1.0 ? 'Normal (1×)' : '$s×',
                    value: s,
                    isDefault: s == _appState.playbackSpeed,
                  ),
              ],
            );
            if (speed != null) _appState.setPlaybackSpeed(speed);
          },
        ),
        ListTile(
          leading: Icon(Icons.stop_circle_outlined, color: Theme.of(sheetContext).colorScheme.error),
          title: const Text('Stop Playback'),
          onTap: () {
            Navigator.pop(sheetContext);
            _audioService.stop();
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
    );
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
                      _buildTrackChip(sheetContext, 'End of this track', 1),
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

  /// Loads lyrics for [track] unless they're already shown or loading: the
  /// current track stream re-emits the same track (on open, after a
  /// favourite toggle), which used to refetch and reset the lyrics.
  Future<void> _fetchLyrics(JellyfinTrack track) {
    if (track.id == _lyricsTrackId) return Future.value();
    return _loadLyrics(track, refresh: false);
  }

  Future<void> _refreshLyrics(JellyfinTrack track) =>
      _loadLyrics(track, refresh: true);

  Future<void> _loadLyrics(JellyfinTrack track, {required bool refresh}) async {
    final request = ++_lyricsRequest;
    _lyricsTrackId = track.id;
    setState(() {
      _loadingLyrics = true;
      if (!refresh) {
        _lyrics = null;
        _lyricsSource = null;
      }
    });

    try {
      final result = refresh
          ? await _lyricsService?.refreshLyrics(track)
          : await _lyricsService?.getLyrics(track);

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

      // A newer request (the track changed, or a refresh) owns the state.
      if (!mounted || request != _lyricsRequest) return;
      setState(() {
        _lyrics = parsedLyrics;
        _lyricsSource = source;
        _loadingLyrics = false;
      });
    } catch (e) {
      debugPrint('Failed to ${refresh ? 'refresh' : 'fetch'} lyrics: $e');
      if (!mounted || request != _lyricsRequest) return;
      setState(() {
        _loadingLyrics = false;
      });
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

  static String _fmtPosition(Duration d) {
    final m = d.inMinutes;
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  void _onColorsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _colorsProvider?.removeListener(_onColorsChanged);
    _tabController.dispose();
    _trackSub?.cancel();
    _loopSub?.cancel();
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
    final savedLoopsFuture = savedLoopsService.initialize().then((_) => savedLoopsService.getLoopsForTrack(track.id));

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
                future: savedLoopsFuture,
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
    // The visualizer widget is only mounted while shown; it retains the iOS
    // FFT capture while mounted and on screen (TickerMode enabled) and
    // releases it otherwise (BaseVisualizer).
    setState(() {
      _showingVisualizerInArtwork = !_showingVisualizerInArtwork;
    });
  }

  /// Build artwork with layout-specific styling
  Widget _buildLayoutStyledArtwork({
    required Widget artwork,
    required bool isWide,
    required Size size,
    required ThemeData theme,
  }) {
    final layout = _appState.nowPlayingLayout;

    // Size constraints based on layout
    double maxWidthFactor;
    double maxHeightFactor;

    switch (layout) {
      case NowPlayingLayout.compact:
        maxWidthFactor = isWide ? 0.4 : 0.65;
        maxHeightFactor = isWide ? 0.4 : 0.45;
        break;
      case NowPlayingLayout.fullArt:
        maxWidthFactor = 1.0;
        maxHeightFactor = 0.85;
        break;
      case NowPlayingLayout.card:
        maxWidthFactor = isWide ? 0.5 : 0.85;
        maxHeightFactor = isWide ? 0.6 : 0.55;
        break;
      default:
        maxWidthFactor = isWide ? 0.6 : 0.98;
        maxHeightFactor = isWide ? 0.7 : 0.7;
    }

    Widget styledArtwork = FittedBox(
      fit: BoxFit.contain,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isWide ? 1000 * maxWidthFactor : size.width * maxWidthFactor,
          maxHeight: isWide ? 1000 * maxHeightFactor : size.height * maxHeightFactor,
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
          // Dim the gradient. (A full-screen sigma-100 BackdropFilter used to
          // sit here: blurring a smooth gradient changes nothing visible, but
          // it re-ran every frame while a visualizer animated.)
          if (hasColors)
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
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
          // Dim only: a BackdropFilter here blurred nothing but the gradient
          // and the scaffold colour (see the classic layout).
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
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

    final avgLuminance = _cachedAvgLuminance;
    if (avgLuminance == null) {
      return theme.colorScheme.onSurface.withValues(alpha: alpha);
    }

    if (avgLuminance > 0.5) {
      return Colors.black.withValues(alpha: alpha * 0.87);
    } else {
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
    required bool isWide,
    required ThemeData theme,
  }) {
    final visualizerEnabled = _appState.visualizerEnabled;
    final visualizerPosition = _appState.visualizerPosition;
    final isAlbumArtPosition = visualizerPosition == VisualizerPosition.albumArt;

    // If visualizer is disabled or position is controlsBar, just return the artwork
    if (!visualizerEnabled || !isAlbumArtPosition) {
      return artwork;
    }

    final layout = _appState.nowPlayingLayout;
    final isFullArt = layout == NowPlayingLayout.fullArt;
    final borderRadius = isFullArt ? BorderRadius.zero : BorderRadius.circular(isWide ? 24 : 16);

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
                  size: isWide ? 24 : 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static final Set<LogicalKeyboardKey> _seekVolumeKeys = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };

  static final Set<LogicalKeyboardKey> _shortcutKeys = {
    ..._seekVolumeKeys,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyP,
    LogicalKeyboardKey.keyR,
    LogicalKeyboardKey.keyL,
  };

  /// Hardware keyboard shortcuts. Returns whether [event] was used, so other
  /// keys (Escape, system shortcuts) keep working.
  ///
  /// Key-ups and repeats of the shortcut keys are consumed too: otherwise
  /// they reach the app's default shortcuts, where a held arrow moves focus
  /// between the player's buttons and a held Space (or Enter) then presses
  /// the focused one. Held arrows keep seeking / changing the volume.
  bool _handleKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (!_shortcutKeys.contains(key)) return false;
    if (event is KeyUpEvent) return true;
    if (event is KeyRepeatEvent && !_seekVolumeKeys.contains(key)) return true;

    final track = _audioService.currentTrack;
    final position = _audioService.currentPosition;
    final duration = track?.duration;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _audioService.playPause();
      case LogicalKeyboardKey.arrowLeft:
        // Seek backward 10 seconds
        final newPos = position - const Duration(seconds: 10);
        _audioService.seek(newPos < Duration.zero ? Duration.zero : newPos);
      case LogicalKeyboardKey.arrowRight:
        // Seek forward 10 seconds. Clamp only to a known duration: with
        // none (no RunTimeTicks) this used to clamp to zero, i.e. restart.
        final newPos = position + const Duration(seconds: 10);
        _audioService.seek(
          duration != null && duration > Duration.zero && newPos > duration
              ? duration
              : newPos,
        );
      case LogicalKeyboardKey.arrowUp:
        // Volume up 5%
        final newVolume = (_audioService.volume + 0.05).clamp(0.0, 1.0);
        _audioService.setVolume(newVolume);
      case LogicalKeyboardKey.arrowDown:
        // Volume down 5%
        final newVolume = (_audioService.volume - 0.05).clamp(0.0, 1.0);
        _audioService.setVolume(newVolume);
      case LogicalKeyboardKey.keyN:
        // Next track
        _audioService.next();
      case LogicalKeyboardKey.keyP:
        // Previous track
        _audioService.previous();
      case LogicalKeyboardKey.keyR:
        // Toggle repeat mode
        _audioService.toggleRepeatMode();
      case LogicalKeyboardKey.keyL:
        // Toggle favorite
        if (track == null) return false;
        _toggleFavorite(track);
      default:
        return false;
    }
    return true;
  }

  /// Sets the current track's favourite flag, but only while [trackId] is
  /// still the current track: after an await the user may have skipped, and
  /// writing the old track back would replace the new one in the player and
  /// the queue.
  void _setCurrentFavorite(String trackId, bool isFavorite) {
    final current = _audioService.currentTrack;
    if (current == null || current.id != trackId) return;
    if (current.isFavorite == isFavorite) return;
    _audioService.updateCurrentTrack(current.copyWith(isFavorite: isFavorite));
  }

  /// Favourite / unfavourite [track]: the heart flips at once (optimistic),
  /// then the server is updated. A real failure flips it back; an offline
  /// failure keeps it (the change is queued and syncs later).
  Future<void> _toggleFavorite(JellyfinTrack track) async {
    final newFavoriteStatus = !track.isFavorite;
    _setCurrentFavorite(track.id, newFavoriteStatus);
    try {
      await _appState.markFavorite(track.id, newFavoriteStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newFavoriteStatus ? 'Added to favorites' : 'Removed from favorites',
            ),
            duration: const Duration(seconds: 2),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      // Refresh the favourites list; its failure isn't a failure to favourite.
      try {
        await _appState.refreshFavorites();
      } catch (e) {
        debugPrint('Refreshing favorites failed: $e');
      }
    } catch (e) {
      debugPrint('Error toggling favorite: $e');
      final isOfflineError =
          e.toString().contains('Offline') || e.toString().contains('queued');
      if (!isOfflineError) _setCurrentFavorite(track.id, !newFavoriteStatus);
      if (!mounted) return;
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isOfflineError
                ? 'Offline: Favorite will sync when online'
                : 'Failed to update favorite: $e',
          ),
          backgroundColor:
              isOfflineError ? Colors.orange : theme.colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The app state is read without listening; rebuild when one of the
    // settings the player shows changes (e.g. Infinite Radio from the menu).
    context.select<NautuneAppState, Object>((s) => (
          s.nowPlayingLayout,
          s.visualizerEnabled,
          s.visualizerPosition,
          s.visualizerType,
          s.showVolumeBar,
          s.streamingQuality,
          s.infiniteRadioEnabled,
        ));
    // Tablet layout by the short side: a landscape iPhone is wide but short.
    final isWide = MediaQuery.sizeOf(context).shortestSide >= 600;

    // Track + playing state only: position ticks (5/s) must not rebuild the
    // artwork, background, controls and menus.
    return StreamBuilder<TrackPlayingState>(
      stream: _trackPlayingStream,
      initialData: (
        track: _audioService.currentTrack,
        isPlaying: _audioService.isPlaying,
      ),
      builder: (context, snapshot) {
        final playerState = snapshot.data ??
            (track: _audioService.currentTrack, isPlaying: false);
        final track = playerState.track;
        final isPlaying = playerState.isPlaying;

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

        final baseArtwork = Hero(
          tag: kNowPlayingArtworkHeroTag,
          transitionOnUserGestures: true,
          child: _buildArtwork(
            track: track,
            isWide: isWide,
            theme: theme,
          ),
        );

        // Wrap artwork with visualizer container if position is albumArt
        final artwork = _buildArtworkVisualizerContainer(
          artwork: baseArtwork,
          isWide: isWide,
          theme: theme,
        );

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) => _handleKeyEvent(event)
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
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
                              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
                              tooltip: 'Close player',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            // Takes the room between the buttons (and scrolls
                            // at large text sizes) instead of overflowing.
                            Expanded(
                              child: Center(
                                child: TabBar(
                                  controller: _tabController,
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.center,
                                  labelStyle: theme.textTheme.titleSmall,
                                  tabs: const [
                                    Tab(text: 'Now Playing'),
                                    Tab(text: 'Lyrics'),
                                  ],
                                ),
                              ),
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
                              onPressed: () => _showTrackMenu(context, track),
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
                              isWide: isWide,
                              theme: theme,
                              artwork: artwork,
                            ),

                            // Tab 2: Lyrics
                            _buildLyricsTab(
                              track: track,
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
    required bool isWide,
    required ThemeData theme,
    required Widget artwork,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Guard against too-small constraints (e.g., during window resize)
        if (constraints.maxHeight < 150) {
          return const SizedBox.shrink();
        }
        final size = MediaQuery.sizeOf(context);
        final info = _buildTrackInfo(
          context: context,
          track: track,
          isWide: isWide,
          theme: theme,
        );
        final controls = _buildControlsSection(
          context: context,
          track: track,
          isPlaying: isPlaying,
          isWide: isWide,
          theme: theme,
        );
        final styledArtwork = _buildLayoutStyledArtwork(
          artwork: artwork,
          isWide: isWide,
          size: size,
          theme: theme,
        );

        // Landscape iPhone: too short to stack artwork, info and controls.
        // Artwork on the left, the rest (scrollable) on the right.
        if (constraints.maxWidth > constraints.maxHeight &&
            constraints.maxHeight < 500) {
          final artSide = math.max(
            0.0,
            math.min(constraints.maxHeight - 32, constraints.maxWidth * 0.42),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(
              children: [
                SizedBox.square(dimension: artSide, child: styledArtwork),
                const SizedBox(width: 24),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          info,
                          const SizedBox(height: 24),
                          controls,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isWide ? size.width * 0.15 : 24,
            vertical: 16,
          ),
          child: Column(
            children: [
              // Top section: artwork above the track info. The info keeps its
              // natural height (and scrolls when even that doesn't fit: small
              // phones at large text sizes); the artwork takes what's left.
              Expanded(
                child: CustomMultiChildLayout(
                  delegate: _ArtworkAndInfoLayout(gap: 24),
                  children: [
                    LayoutId(id: _TopSlot.artwork, child: styledArtwork),
                    LayoutId(
                      id: _TopSlot.info,
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: info,
                      ),
                    ),
                  ],
                ),
              ),

              // Spacer for waveform (waveform extends 16px above progress bar)
              const SizedBox(height: 24),

              // Bottom section: Controls with bioluminescent visualizer
              controls,
            ],
          ),
        );
      },
    );
  }

  /// Title, radio badge, artist, album and quality badges.
  Widget _buildTrackInfo({
    required BuildContext context,
    required JellyfinTrack track,
    required bool isWide,
    required ThemeData theme,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Track Info - Compact with adaptive colors
        GestureDetector(
          onLongPress: () => _showTrackMenu(context, track),
          child: Text(
            track.name,
            style:
                (isWide
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
        ),

        // Radio indicator
        if (_appState.infiniteRadioEnabled) ...[
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
              // First, try direct ID-based lookup from track metadata
              final artistId = track.artistIds.isNotEmpty
                  ? track.artistIds.first
                  : null;
              final artists = _appState.artists ?? [];

              if (artistId != null) {
                artist = artists
                    .where((a) => a.id == artistId)
                    .firstOrNull;
              }

              // Fall back to name-based search
              artist ??= artists
                  .where(
                    (a) =>
                        a.name.toLowerCase() ==
                        artistName.toLowerCase(),
                  )
                  .firstOrNull;

              // Not in the local cache — ask the server directly for the
              // artist by ID. One round-trip beats paging through up to
              // 500 artists hunting for a single match.
              if (artist == null && artistId != null) {
                try {
                  artist = await _appState.jellyfinService
                      .getArtist(artistId);
                } catch (e) {
                  debugPrint('Direct artist fetch failed: $e');
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
                      (isWide
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
    );
  }

  /// Progress bar, volume, A-B loop and transport controls, over the
  /// controls-bar visualizer.
  Widget _buildControlsSection({
    required BuildContext context,
    required JellyfinTrack track,
    required bool isPlaying,
    required bool isWide,
    required ThemeData theme,
  }) {
    return Stack(
      children: [
        // Visualizer behind controls
        // Only shown when visualizerPosition is controlsBar
        // Wrapped in RepaintBoundary to isolate repaints from parent layout
        if (_appState.visualizerEnabled &&
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
            // Repaints 5x a second on its own layer instead of
            // repainting the whole page (artwork shadow, glows).
            RepaintBoundary(
              child: PositionDataBuilder(
          audioService: _audioService,
          builder: (context, positionData) {
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
                            // Waveform layer
                            if (track != null)
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
                            // Progress bar on top; VoiceOver
                            // adjusts it in 10 s steps.
                            Semantics(
                              slider: true,
                              label: 'Playback position',
                              value: '${_fmtPosition(positionData.position)} of ${_fmtPosition(positionData.duration)}',
                              onIncrease: () => _audioService.seek(positionData.position + const Duration(seconds: 10)),
                              onDecrease: () => _audioService.seek(positionData.position - const Duration(seconds: 10) < Duration.zero ? Duration.zero : positionData.position - const Duration(seconds: 10)),
                              child: ExcludeSemantics(
                                child: ProgressBar(
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
                              ),
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

        // Playback Controls. Scales down instead of overflowing
        // where the row is wider than the space (375 pt iPhones,
        // which need 348 pt for it at the padded 48 pt targets).
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: Icon(
                track.isFavorite
                    ? Icons.favorite
                    : Icons.favorite_border,
                size: isWide ? 32 : 26,
              ),
              tooltip: track.isFavorite ? 'Remove from favorites' : 'Add to favorites',
              onPressed: () {
                HapticService.lightTap();
                _toggleFavorite(track);
              },
              color: track.isFavorite ? Colors.red : null,
            ),

            SizedBox(width: isWide ? 16 : 4),

            StreamBuilder<bool>(
              stream: _audioService.shuffleStream,
              initialData: _audioService.shuffleEnabled,
              builder: (context, snapshot) {
                final shuffled = snapshot.data ?? false;
                return IconButton(
                  icon: Icon(
                    Icons.shuffle_rounded,
                    size: isWide ? 32 : 26,
                    color: shuffled ? theme.colorScheme.primary : null,
                  ),
                  tooltip: shuffled ? 'Shuffle on' : 'Shuffle off',
                  isSelected: shuffled,
                  onPressed: () {
                    HapticService.selectionClick();
                    _audioService.toggleShuffle();
                  },
                );
              },
            ),

            SizedBox(width: isWide ? 16 : 4),

            IconButton(
              icon: Icon(
                Icons.skip_previous,
                size: isWide ? 48 : 40,
              ),
              tooltip: 'Previous',
              onPressed: () => _audioService.previous(),
            ),

            SizedBox(width: isWide ? 24 : 8),

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
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(isPlaying),
                    size: isWide ? 56 : 48,
                  ),
                ),
                tooltip: isPlaying ? 'Pause' : 'Play',
                onPressed: () {
                  HapticService.lightTap();
                  _audioService.playPause();
                },
                color: theme.colorScheme.onPrimary,
              ),
            ),

            SizedBox(width: isWide ? 24 : 8),

            IconButton(
              icon: Icon(
                Icons.skip_next,
                size: isWide ? 48 : 40,
              ),
              tooltip: 'Next',
              onPressed: () => _audioService.next(),
            ),

            SizedBox(width: isWide ? 16 : 4),

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
                    size: isWide ? 32 : 26,
                    color: color,
                  ),
                  tooltip: switch (repeatMode) {
                    RepeatMode.off => 'Repeat off',
                    RepeatMode.all => 'Repeat all',
                    RepeatMode.one => 'Repeat one',
                  },
                  onPressed: () {
                    HapticService.selectionClick();
                    _audioService.toggleRepeatMode();
                  },
                );
              },
            ),
          ],
        ),
        ),
      ],
    ),
      ],
    );
  }

  Widget _buildLyricsTab({
    required JellyfinTrack track,
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

    return _SyncedLyricsView(lyrics: _lyrics!, audioService: _audioService);
  }

  Widget _buildArtwork({
    required JellyfinTrack track,
    required bool isWide,
    required ThemeData theme,
  }) {
    final layout = _appState.nowPlayingLayout;
    final isFullArt = layout == NowPlayingLayout.fullArt;

    // Full Art layout: no rounded corners; others: rounded
    final borderRadius = isFullArt
        ? BorderRadius.zero
        : BorderRadius.circular(isWide ? 24 : 16);
    // Logical points (JellyfinImage scales by the pixel ratio): about the
    // largest the artwork is drawn at. 800 decoded ~2400 px on @3x phones.
    final maxWidth = isWide ? 640 : 420;
    final placeholder = Container(
      color: theme.colorScheme.primaryContainer,
      child: Icon(
        Icons.album,
        size: isWide ? 160 : 100,
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

enum _TopSlot { artwork, info }

/// Lays out the artwork above the track info, centred as a group. The info
/// is measured first at its natural height (a scroll view caps it at the
/// available height); the artwork gets the rest. A Column can't do this:
/// fixed children overflow when the space is short, and two Flexibles would
/// split it evenly.
class _ArtworkAndInfoLayout extends MultiChildLayoutDelegate {
  _ArtworkAndInfoLayout({required this.gap});

  final double gap;

  @override
  void performLayout(Size size) {
    final infoSize = layoutChild(
      _TopSlot.info,
      BoxConstraints(maxWidth: size.width, maxHeight: size.height),
    );
    final artworkMax = math.max(0.0, size.height - infoSize.height - gap);
    final artworkSize = layoutChild(
      _TopSlot.artwork,
      BoxConstraints(maxWidth: size.width, maxHeight: artworkMax),
    );
    final gapUsed = artworkSize.height > 0 ? gap : 0.0;
    var y = math.max(
      0.0,
      (size.height - artworkSize.height - gapUsed - infoSize.height) / 2,
    );
    positionChild(
      _TopSlot.artwork,
      Offset((size.width - artworkSize.width) / 2, y),
    );
    y += artworkSize.height + gapUsed;
    positionChild(_TopSlot.info, Offset((size.width - infoSize.width) / 2, y));
  }

  @override
  bool shouldRelayout(_ArtworkAndInfoLayout oldDelegate) =>
      oldDelegate.gap != gap;
}

class _LyricLine {
  _LyricLine({required this.text, this.startTicks});

  final String text;
  final int? startTicks; // Jellyfin uses ticks (100 nanoseconds)
  final GlobalKey key = GlobalKey();
}

/// Lyrics list that follows playback. It owns its position subscription and
/// rebuilds only when the active line changes, not on every position tick.
/// Plain (untimed) lyrics get no subscription and no highlighted line.
class _SyncedLyricsView extends StatefulWidget {
  const _SyncedLyricsView({required this.lyrics, required this.audioService});

  final List<_LyricLine> lyrics;
  final AudioPlayerService audioService;

  @override
  State<_SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<_SyncedLyricsView> {
  static const double _verticalPadding = 200;
  // Rough row height for lines not built yet (~20 pt * 1.4 + 24 pt padding).
  static const double _estimatedItemHeight = 52;

  final ScrollController _scrollController = ScrollController();
  StreamSubscription<Duration>? _positionSub;
  int _activeIndex = -1;
  bool _userIsScrolling = false;
  Timer? _userScrollTimer;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics) ||
        !identical(oldWidget.audioService, widget.audioService)) {
      _subscribe();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _userScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _subscribe() {
    _positionSub?.cancel();
    _positionSub = null;
    _activeIndex = -1;
    if (!widget.lyrics.any((line) => line.startTicks != null)) return;
    _activeIndex = _indexFor(widget.audioService.currentPosition);
    _positionSub = widget.audioService.positionStream.listen(_onPosition);
    _scheduleScrollToActive(animate: false);
  }

  /// Last line that has started at [position]; -1 before the first one.
  int _indexFor(Duration position) {
    final ticks = position.inMicroseconds * 10; // Jellyfin ticks (100 ns)
    var index = -1;
    final lyrics = widget.lyrics;
    for (var i = 0; i < lyrics.length; i++) {
      final start = lyrics[i].startTicks;
      if (start != null && start <= ticks) index = i;
    }
    return index;
  }

  void _onPosition(Duration position) {
    if (!mounted) return;
    final index = _indexFor(position);
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    if (!_userIsScrolling) _scheduleScrollToActive();
  }

  void _scheduleScrollToActive({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive(animate));
  }

  /// Centres the active line by scrolling this list only. (It used
  /// Scrollable.ensureVisible, which also scrolls the TabBarView around it
  /// and yanked a half-finished swipe between the tabs back to Lyrics.)
  void _scrollToActive(bool animate) {
    if (!mounted || !_scrollController.hasClients) return;
    final index = _activeIndex;
    if (index < 0 || index >= widget.lyrics.length) return;
    final position = _scrollController.position;

    double? target;
    final renderObject =
        widget.lyrics[index].key.currentContext?.findRenderObject();
    if (renderObject != null && renderObject.attached) {
      final viewport = RenderAbstractViewport.maybeOf(renderObject);
      target = viewport?.getOffsetToReveal(renderObject, 0.5).offset;
    }
    // Not built yet (outside the viewport): estimate.
    target ??= _verticalPadding +
        index * _estimatedItemHeight -
        position.viewportDimension * 0.5;
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);

    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeIndex = _activeIndex;
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction != ScrollDirection.idle) {
          _userIsScrolling = true;
          _userScrollTimer?.cancel();
          _userScrollTimer = Timer(const Duration(seconds: 2), () {
            if (!mounted) return;
            _userIsScrolling = false;
            // Back to the line being sung.
            _scrollToActive(true);
          });
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(
          horizontal: 32,
          vertical: _verticalPadding,
        ),
        itemCount: widget.lyrics.length,
        itemBuilder: (context, index) {
          final line = widget.lyrics[index];
          final isCurrent = index == activeIndex;
          final isPast = activeIndex >= 0 && index < activeIndex;

          return GestureDetector(
            key: line.key,
            onTap: () {
              final start = line.startTicks;
              if (start != null) {
                widget.audioService.seek(Duration(microseconds: start ~/ 10));
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
                            color: theme.colorScheme.primary.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : const [],
                ),
                textAlign: TextAlign.center,
                child: Text(line.text.isEmpty ? '♫' : line.text),
              ),
            ),
          );
        },
      ),
    );
  }
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
