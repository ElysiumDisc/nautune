import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../jellyfin/jellyfin_track.dart';
import '../providers/syncplay_provider.dart';
import '../screens/collab_playlist_screen.dart';
import '../screens/full_player_screen.dart';
import '../screens/queue_screen.dart';
import '../services/audio_player_service.dart';
import '../services/haptic_service.dart';
import '../app_state.dart';
import '../models/visualizer_type.dart';
import 'visualizers/visualizer_factory.dart';
import 'jellyfin_waveform.dart';

/// Compact control surface that mirrors the full player while staying unobtrusive.
/// Also handles SyncPlay Sailors who don't have local audio playing.
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    super.key,
    required this.audioService,
    required this.appState,
  });

  final AudioPlayerService audioService;
  final NautuneAppState appState;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  StreamSubscription<String>? _errorSubscription;

  AudioPlayerService get audioService => widget.audioService;
  NautuneAppState get appState => widget.appState;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
    _errorSubscription?.cancel();
    super.dispose();
  }

  void _openFullPlayer(BuildContext context, {bool isSailorMode = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullPlayerScreen(
          key: UniqueKey(), // Force fresh build
          sailorMode: isSailorMode,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final syncPlay = context.watch<SyncPlayProvider>();

    // Check if user is a Sailor in a SyncPlay session (no local audio)
    final isSailor = syncPlay.isInSession && !syncPlay.isCaptain;

    // Sailor mode: Show collab track info
    if (isSailor && syncPlay.currentTrack != null) {
      return _buildSailorBar(context, theme, syncPlay);
    }

    // Normal mode: Show audio player track
    return StreamBuilder<JellyfinTrack?>(
      stream: audioService.currentTrackStream,
      initialData: audioService.currentTrack,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data ?? audioService.currentTrack;
        if (track == null) {
          return const SizedBox.shrink();
        }

        return StreamBuilder<bool>(
          stream: audioService.playingStream,
          initialData: false,
          builder: (context, playingSnapshot) {
            final isPlaying = playingSnapshot.data ?? false;

            return _buildNormalBar(context, theme, track, isPlaying);
          },
        );
      },
    );
  }

  /// Build the Now Playing bar for Sailors (SyncPlay participants without audio)
  Widget _buildSailorBar(BuildContext context, ThemeData theme, SyncPlayProvider syncPlay) {
    final track = syncPlay.currentTrack!.track;
    final isPlaying = !syncPlay.isPaused;

    return Material(
      elevation: 10,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity;
            if (velocity == null) return;
            if (velocity < -200) {
              HapticService.mediumTap();
              syncPlay.nextTrack();
            } else if (velocity > 200) {
              HapticService.mediumTap();
              syncPlay.previousTrack();
            }
          },
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.primary.withValues(alpha: 0.5),
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Simple progress bar for Sailors (no waveform/FFT)
                _SailorProgressBar(syncPlay: syncPlay, theme: theme),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => syncPlay.previousTrack(),
                    ),
                    _SailorPlayPauseButton(syncPlay: syncPlay, isPlaying: isPlaying),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => syncPlay.nextTrack(),
                    ),
                    const SizedBox(width: 8),
                    // Collab indicator
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.group, size: 12, color: theme.colorScheme.onPrimaryContainer),
                          const SizedBox(width: 4),
                          Text(
                            'FLEET',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _openFullPlayer(context, isSailorMode: true),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                track.name,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.displayArtist,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const CollabPlaylistScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build the normal Now Playing bar (Captain or regular playback)
  Widget _buildNormalBar(BuildContext context, ThemeData theme, JellyfinTrack track, bool isPlaying) {
    return Material(
      elevation: 10,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
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
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.25),
                ),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _WaveformStrip(
                  audioService: audioService,
                  track: track,
                  isPlaying: isPlaying,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => audioService.previous(),
                    ),
                    _PlayPauseButton(
                      audioService: audioService,
                      isPlaying: isPlaying,
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.stop,
                        color: theme.colorScheme.error,
                      ),
                      onPressed: () => audioService.stop(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => audioService.next(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _openFullPlayer(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                track.name,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  if (audioService.infiniteRadioEnabled) ...[
                                    Icon(Icons.radio, size: 12, color: theme.colorScheme.primary),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Text(
                                      _subtitleFor(track),
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitleFor(JellyfinTrack track) {
    if (track.artists.isNotEmpty) {
      return track.displayArtist;
    }
    return track.album ?? 'Unknown album';
  }
}

/// Play/Pause button for Sailors
class _SailorPlayPauseButton extends StatelessWidget {
  const _SailorPlayPauseButton({
    required this.syncPlay,
    required this.isPlaying,
  });

  final SyncPlayProvider syncPlay;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary,
        boxShadow: [
          BoxShadow(
            blurRadius: 14,
            spreadRadius: 1,
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ],
      ),
      child: IconButton(
        icon: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          color: theme.colorScheme.onPrimary,
        ),
        onPressed: () => syncPlay.togglePlayPause(),
      ),
    );
  }
}

/// Simple progress bar for Sailors (no waveform/FFT)
class _SailorProgressBar extends StatelessWidget {
  const _SailorProgressBar({
    required this.syncPlay,
    required this.theme,
  });

  final SyncPlayProvider syncPlay;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final position = syncPlay.position;
    final duration = syncPlay.currentTrack?.track.duration ?? const Duration(seconds: 1);
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SizedBox(
      height: 40,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            // Background
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            // Progress fill
            FractionallySizedBox(
              widthFactor: progress,
              alignment: Alignment.centerLeft,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary.withValues(alpha: 0.6),
                      theme.colorScheme.primary.withValues(alpha: 0.3),
                    ],
                  ),
                ),
              ),
            ),
            // Collab icon in center
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.group,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${syncPlay.participants.length} listening',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
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
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary,
        boxShadow: [
          BoxShadow(
            blurRadius: 14,
            spreadRadius: 1,
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ],
      ),
      child: IconButton(
        icon: Icon(
          isPlaying ? Icons.pause : Icons.play_arrow,
          color: theme.colorScheme.onPrimary,
        ),
        onPressed: () => audioService.playPause(),
      ),
    );
  }
}

class _WaveformStrip extends StatelessWidget {
  const _WaveformStrip({
    required this.audioService,
    required this.track,
    required this.isPlaying,
  });

  final AudioPlayerService audioService;
  final JellyfinTrack track;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Use the combined positionDataStream for reliable position updates
    // This is the same stream used by the fullscreen player
    return StreamBuilder<PositionData>(
      stream: audioService.positionDataStream,
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
                        color: Colors.white.withValues(alpha: 0.7),
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