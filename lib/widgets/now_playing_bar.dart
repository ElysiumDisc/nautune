import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../jellyfin/jellyfin_track.dart';
import '../screens/full_player_screen.dart';
import '../screens/queue_screen.dart';
import '../services/audio_player_service.dart';
import '../services/haptic_service.dart';
import '../app_state.dart';
import '../models/visualizer_type.dart';
import '../providers/now_playing_colors_provider.dart';
import '../services/playback_logic.dart' show sleepTimerLabel;
import '../theme/nautune_spacing.dart';
import '../theme/nautune_theme.dart';
import 'ios/frosted_bar.dart';
import 'ios/now_playing_route.dart';
import 'jellyfin_image.dart';
import 'visualizers/visualizer_factory.dart';
import 'jellyfin_waveform.dart';

/// Compact control surface that mirrors the full player while staying unobtrusive.
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    super.key,
    required this.audioService,
    required this.appState,
    this.embedded = false,
  });

  final AudioPlayerService audioService;
  final NautuneAppState appState;

  /// Sits above a tab bar that already handles the bottom safe area.
  final bool embedded;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  StreamSubscription<String>? _errorSubscription;
  // Cached so rebuilds don't resubscribe. The bar rebuilds on track /
  // playing changes only; position drives just the waveform strip.
  late Stream<TrackPlayingState> _trackPlayingStream;
  late Stream<PositionData> _positionDataStream;

  AudioPlayerService get audioService => widget.audioService;
  NautuneAppState get appState => widget.appState;

  @override
  void initState() {
    super.initState();
    _trackPlayingStream = audioService.trackPlayingStream;
    _positionDataStream = audioService.positionDataStream;
    _errorSubscription = audioService.playbackErrorStream.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  @override
  void didUpdateWidget(covariant NowPlayingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _trackPlayingStream = audioService.trackPlayingStream;
      _positionDataStream = audioService.positionDataStream;
    }
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    super.dispose();
  }

  void _openFullPlayer(BuildContext context) {
    if (!mounted) return;
    HapticService.lightTap();
    Navigator.of(context).push(
      NowPlayingRoute<void>(builder: (_) => const FullPlayerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Track + playing state only; the waveform strip has its own position
    // builder so position ticks don't rebuild the whole bar.
    return StreamBuilder<TrackPlayingState>(
      stream: _trackPlayingStream,
      initialData: (track: audioService.currentTrack, isPlaying: false),
      builder: (context, snapshot) {
        final data = snapshot.data;
        final track = data?.track ?? audioService.currentTrack;
        if (track == null) {
          return const SizedBox.shrink();
        }
        final isPlaying = data?.isPlaying ?? false;
        return _buildNormalBar(context, theme, track, isPlaying);
      },
    );
  }

  /// Build the Now Playing bar: a floating, frosted card (tinted from the
  /// artwork when enabled) with artwork, title, and transport controls.
  /// Tap or swipe up opens the full player; swipe sideways skips.
  Widget _buildNormalBar(BuildContext context, ThemeData theme, JellyfinTrack track, bool isPlaying) {
    final style = NautuneStyle.of(context);
    final accent = style.artworkTint
        ? context.select<NowPlayingColorsProvider, Color?>((c) => c.accent)
        : null;
    final tint = accent == null
        ? null
        : Color.alphaBlend(accent.withValues(alpha: 0.28), style.barColor);
    final showWaveform = context.select<NautuneAppState, bool>(
      (s) => s.visualizerEnabled && s.visualizerPosition == VisualizerPosition.controlsBar,
    );
    final shape = style.shape(NautuneRadius.lg);

    final card = Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: FrostedBar(
            color: tint,
            topBorder: false,
            child: Semantics(
              button: true,
              label: 'Now playing: ${track.name}, ${_subtitleFor(track)}',
              hint: 'Opens the player',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openFullPlayer(context),
                onVerticalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) < -300) {
                    _openFullPlayer(context);
                  }
                },
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity;
                  if (velocity == null) return;
                  if (velocity < -200) {
                    HapticService.mediumTap();
                    audioService.next();
                  } else if (velocity > 200) {
                    HapticService.mediumTap();
                    audioService.previous();
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showWaveform)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                        child: _WaveformStrip(
                          audioService: audioService,
                          positionDataStream: _positionDataStream,
                          track: track,
                          isPlaying: isPlaying,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                      child: Row(
                        children: [
                          Hero(
                            tag: kNowPlayingArtworkHeroTag,
                            transitionOnUserGestures: true,
                            child: _MiniArtwork(track: track),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.name,
                                  style: theme.textTheme.subhead.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Row(
                                  children: [
                                    if (audioService.infiniteRadioEnabled) ...[
                                      Icon(Icons.radio, size: 12, color: theme.colorScheme.primary),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        _subtitleFor(track),
                                        style: theme.textTheme.footnote,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    _SleepTimerChip(audioService: audioService),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_previous_rounded),
                            tooltip: 'Previous',
                            color: theme.colorScheme.onSurface,
                            onPressed: () => audioService.previous(),
                          ),
                          _PlayPauseButton(
                            audioService: audioService,
                            isPlaying: isPlaying,
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next_rounded),
                            tooltip: 'Next',
                            color: theme.colorScheme.onSurface,
                            onPressed: () => audioService.next(),
                          ),
                          IconButton(
                            icon: const Icon(Icons.queue_music_rounded),
                            tooltip: 'Queue',
                            color: theme.colorScheme.onSurfaceVariant,
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => const QueueScreen(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    if (!showWaveform)
                      _ProgressLine(positionDataStream: _positionDataStream),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return widget.embedded ? card : SafeArea(top: false, child: card);
  }

  String _subtitleFor(JellyfinTrack track) {
    if (track.artists.isNotEmpty) {
      return track.displayArtist;
    }
    return track.album ?? 'Unknown album';
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.audioService,
    required this.isPlaying,
  });

  final AudioPlayerService audioService;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: isPlaying ? 'Pause' : 'Play',
      iconSize: 34,
      color: theme.colorScheme.onSurface,
      onPressed: () {
        HapticService.lightTap();
        audioService.playPause();
      },
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          key: ValueKey(isPlaying),
        ),
      ),
    );
  }
}

/// Small square artwork for the mini player (track → album → parent art).
class _MiniArtwork extends StatelessWidget {
  const _MiniArtwork({required this.track});

  final JellyfinTrack track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? tag = track.primaryImageTag;
    String itemId = track.id;
    if (tag == null || tag.isEmpty) {
      tag = track.albumPrimaryImageTag;
      itemId = track.albumId ?? track.id;
    }
    if (tag == null || tag.isEmpty) {
      tag = track.parentThumbImageTag;
      itemId = track.albumId ?? track.id;
    }
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: theme.colorScheme.onSurfaceVariant),
    );
    return SizedBox.square(
      dimension: 44,
      child: ClipPath(
        clipper: ShapeBorderClipper(
          shape: NautuneStyle.of(context).shape(NautuneRadius.sm),
        ),
        child: tag == null || tag.isEmpty
            ? placeholder
            : JellyfinImage(
                key: ValueKey('$itemId-$tag-mini'),
                itemId: itemId,
                imageTag: tag,
                trackId: track.id,
                maxWidth: 100,
                boxFit: BoxFit.cover,
                errorBuilder: (context, url, error) => placeholder,
              ),
      ),
    );
  }
}

/// Thin playback progress line along the bottom of the mini player.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.positionDataStream});

  final Stream<PositionData> positionDataStream;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<PositionData>(
      stream: positionDataStream,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final total = data?.duration.inMilliseconds ?? 0;
        final value = total > 0
            ? (data!.position.inMilliseconds / total).clamp(0.0, 1.0)
            : 0.0;
        return SizedBox(
          height: 2,
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            color: theme.colorScheme.primary,
          ),
        );
      },
    );
  }
}

/// Remaining sleep-timer time (or tracks) next to the artist line.
class _SleepTimerChip extends StatelessWidget {
  const _SleepTimerChip({required this.audioService});

  final AudioPlayerService audioService;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<Duration>(
      stream: audioService.sleepTimerStream,
      builder: (context, snapshot) {
        final label = sleepTimerLabel(snapshot.data ?? Duration.zero);
        if (label == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.nightlight_round, size: 11, color: theme.colorScheme.primary),
              const SizedBox(width: 2),
              Text(
                label,
                style: theme.textTheme.caption.copyWith(
                  color: theme.colorScheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WaveformStrip extends StatelessWidget {
  const _WaveformStrip({
    required this.audioService,
    required this.positionDataStream,
    required this.track,
    required this.isPlaying,
  });

  final AudioPlayerService audioService;
  final Stream<PositionData> positionDataStream;
  final JellyfinTrack track;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The only position-driven part of the bar (same stream as the
    // fullscreen player's progress bar).
    return StreamBuilder<PositionData>(
      stream: positionDataStream,
      builder: (context, snapshot) {
        final positionData = snapshot.data;
        final duration = positionData?.duration ?? Duration.zero;
        final position = positionData?.position ?? Duration.zero;
        final progress = duration.inMilliseconds > 0
            ? position.inMilliseconds / duration.inMilliseconds
            : 0.0;

        return _WaveformDisplay(
          track: track,
          progress: progress.clamp(0.0, 1.0),
          theme: theme,
          isPlaying: isPlaying,
          duration: duration,
          audioService: audioService,
        );
      },
    );
  }
}

class _WaveformDisplay extends StatefulWidget {
  const _WaveformDisplay({
    required this.track,
    required this.progress,
    required this.theme,
    required this.isPlaying,
    required this.duration,
    required this.audioService,
  });

  final JellyfinTrack track;
  final double progress;
  final ThemeData theme;
  final bool isPlaying;
  final Duration duration;
  final AudioPlayerService audioService;

  @override
  State<_WaveformDisplay> createState() => _WaveformDisplayState();
}

class _WaveformDisplayState extends State<_WaveformDisplay> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(12);
    // Use theme-based colors instead of hardcoded purple
    final primaryTint = theme.colorScheme.primary.withValues(alpha: 0.7);
    final secondaryTint = HSLColor.fromColor(theme.colorScheme.primary)
        .withLightness(0.25)
        .toColor();
    final visualizerEnabled = context.select<NautuneAppState, bool>(
      (state) => state.visualizerEnabled,
    );
    final visualizerType = context.select<NautuneAppState, VisualizerType>(
      (state) => state.visualizerType,
    );
    final visualizerPosition = context.select<NautuneAppState, VisualizerPosition>(
      (state) => state.visualizerPosition,
    );
    // Only show visualizer overlay when position is set to controlsBar
    final showVisualizerOverlay = visualizerEnabled &&
        visualizerPosition == VisualizerPosition.controlsBar;

    return SizedBox(
      height: 40,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final clampedProgress = widget.progress.clamp(0.0, 1.0);
          final indicatorLeft =
              (clampedProgress * constraints.maxWidth).clamp(0.0, constraints.maxWidth);

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (details) => _scrubTo(details.localPosition.dx, constraints.maxWidth),
            onHorizontalDragStart: (details) =>
                _scrubTo(details.localPosition.dx, constraints.maxWidth),
            onHorizontalDragUpdate: (details) =>
                _scrubTo(details.localPosition.dx, constraints.maxWidth),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: TrackWaveform(
                      trackId: widget.track.id,
                      progress: clampedProgress,
                      width: constraints.maxWidth,
                      height: 40,
                    ),
                  ),
                  // Audio visualizer overlay (shown only when position is controlsBar)
                  // Wrapped in RepaintBoundary to isolate repaints from parent layout
                  if (showVisualizerOverlay)
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: VisualizerFactory(
                          type: visualizerType,
                          audioService: widget.audioService,
                          opacity: 0.5,
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            secondaryTint.withValues(alpha: 0.35),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      widthFactor: clampedProgress,
                      alignment: Alignment.centerLeft,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              secondaryTint.withValues(alpha: 0.8),
                              primaryTint.withValues(alpha: 0.3),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: indicatorLeft,
                    top: 0,
                    bottom: 0,
                    child: AnimatedOpacity(
                      opacity: widget.isPlaying ? 1.0 : 0.4,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        width: 2,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _scrubTo(double dx, double maxWidth) {
    if (maxWidth <= 0) return;
    final durationMs = widget.duration.inMilliseconds;
    if (durationMs <= 0) return;
    final ratio = (dx / maxWidth).clamp(0.0, 1.0);
    final target = Duration(milliseconds: (durationMs * ratio).round());
    widget.audioService.seek(target);
  }
}