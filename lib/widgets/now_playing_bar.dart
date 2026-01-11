import 'package:flutter/material.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';

import '../jellyfin/jellyfin_track.dart';
import '../screens/full_player_screen.dart';
import '../screens/queue_screen.dart';
import '../services/audio_player_service.dart';
import '../services/haptic_service.dart';
import '../app_state.dart';
import 'jellyfin_waveform.dart';

/// Compact control surface that mirrors the full player while staying unobtrusive.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    super.key,
    required this.audioService,
    required this.appState,
  });

  final AudioPlayerService audioService;
  final NautuneAppState appState;

  void _openFullPlayer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullPlayerScreen(
          key: UniqueKey(), // Force fresh build
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                      // Swipe Left -> Next
                      HapticService.mediumTap();
                      audioService.next();
                    } else if (velocity > 200) {
                      // Swipe Right -> Previous
                      HapticService.mediumTap();
                      audioService.previous();
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color:
                              theme.colorScheme.secondary.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _WaveformStrip(
                          audioService: audioService,
                          track: track,
                          isPlaying: isPlaying,
                        ),
                        const SizedBox(height: 6),
                        StreamBuilder<PositionData>(
                          stream: audioService.positionDataStream,
                          builder: (context, snapshot) {
                            final positionData = snapshot.data ??
                                const PositionData(Duration.zero, Duration.zero, Duration.zero);
                            return ProgressBar(
                              progress: positionData.position,
                              buffered: positionData.bufferedPosition,
                              total: positionData.duration,
                              onSeek: audioService.seek,
                              barHeight: 3.0,
                              thumbRadius: 0.0, // Hide thumb for mini player
                              progressBarColor: theme.colorScheme.secondary,
                              baseBarColor: theme.colorScheme.secondary.withValues(alpha: 0.2),
                              bufferedBarColor: theme.colorScheme.secondary.withValues(alpha: 0.1),
                              timeLabelLocation: TimeLabelLocation.none,
                            );
                          },
                        ),
                        const SizedBox(height: 4),
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
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
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
                                        _subtitleFor(track),
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
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
          },
        );
      },
    );
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
    return StreamBuilder<Duration?>(
      stream: audioService.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: audioService.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
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
    final borderRadius = BorderRadius.circular(12);
    final primaryTint = const Color(0xFFCCB8FF);
    final secondaryTint = const Color(0xFF5F3FAE);

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
                    child: JellyfinWaveform(
                      track: widget.track,
                      progress: clampedProgress,
                      width: constraints.maxWidth,
                      height: 40,
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