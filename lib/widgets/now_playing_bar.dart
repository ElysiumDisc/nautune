import 'package:flutter/material.dart';

import '../jellyfin/jellyfin_track.dart';
import '../screens/full_player_screen.dart';
import '../screens/queue_screen.dart';
import '../services/audio_player_service.dart';
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
          audioService: audioService,
          appState: appState,
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
                      _PositionSlider(audioService: audioService),
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
                                  builder: (context) => QueueScreen(appState: appState),
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


class _PositionSlider extends StatefulWidget {
  const _PositionSlider({required this.audioService});

  final AudioPlayerService audioService;

  @override
  State<_PositionSlider> createState() => _PositionSliderState();
}

class _PositionSliderState extends State<_PositionSlider> {
  double? _pendingValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<Duration?>(
      stream: widget.audioService.durationStream,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;

        return StreamBuilder<Duration>(
          stream: widget.audioService.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final hasDuration = duration.inMilliseconds > 0;
            final max = hasDuration ? duration.inMilliseconds.toDouble() : 1.0;
            final clampedPosition = position.inMilliseconds.clamp(0, max.toInt());
            final sliderValue =
                _pendingValue ?? (hasDuration ? clampedPosition.toDouble() : 0.0);

            return SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: theme.colorScheme.secondary,
                inactiveTrackColor:
                    theme.colorScheme.secondary.withValues(alpha: 0.3),
                thumbColor: theme.colorScheme.secondary,
              ),
              child: Slider(
                value: sliderValue,
                min: 0,
                max: max,
                onChanged: hasDuration
                    ? (value) {
                        setState(() => _pendingValue = value.clamp(0, max));
                      }
                    : null,
                onChangeEnd: hasDuration
                    ? (value) async {
                        await widget.audioService.seek(
                          Duration(milliseconds: value.toInt()),
                        );
                        setState(() => _pendingValue = null);
                      }
                    : null,
              ),
            );
          },
        );
      },
    );
  }
}
