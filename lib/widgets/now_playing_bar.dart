import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../jellyfin/jellyfin_track.dart';
import '../screens/full_player_screen.dart';
import '../services/audio_player_service.dart';

/// Compact control surface that mirrors the full player while staying unobtrusive.
class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    super.key,
    required this.audioService,
  });

  final AudioPlayerService audioService;

  void _openFullPlayer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullPlayerScreen(audioService: audioService),
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
                            tooltip: 'Previous track',
                            icon: const Icon(Icons.skip_previous),
                            onPressed: () => audioService.previous(),
                          ),
                          _PlayPauseButton(
                            audioService: audioService,
                            isPlaying: isPlaying,
                          ),
                          IconButton(
                            tooltip: 'Stop playback',
                            icon: Icon(
                              Icons.stop,
                              color: theme.colorScheme.error,
                            ),
                            onPressed: () => audioService.stop(),
                          ),
                          IconButton(
                            tooltip: 'Next track',
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
            color: theme.colorScheme.primary.withOpacity(0.3),
          ),
        ],
      ),
      child: IconButton(
        tooltip: isPlaying ? 'Pause' : 'Play',
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
  bool _waveformUnavailable = false;

  @override
  void didUpdateWidget(covariant _WaveformDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      _waveformUnavailable = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final waveformUrl =
        _waveformUnavailable ? null : widget.track.waveformImageUrl(width: 900, height: 120);
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
                    child: waveformUrl != null
                        ? ColorFiltered(
                            colorFilter: ColorFilter.mode(
                              primaryTint.withOpacity(0.65),
                              BlendMode.srcATop,
                            ),
                            child: Image.network(
                              waveformUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) {
                                if (!_waveformUnavailable) {
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    if (mounted) {
                                      setState(() => _waveformUnavailable = true);
                                    }
                                  });
                                }
                              return _WaveformFallback(
                                theme: widget.theme,
                                primaryTint: primaryTint,
                                seed: widget.track.id.hashCode,
                              );
                            },
                          ),
                        )
                        : _WaveformFallback(
                            theme: widget.theme,
                            primaryTint: primaryTint,
                            seed: widget.track.id.hashCode,
                          ),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            secondaryTint.withOpacity(0.35),
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
                              secondaryTint.withOpacity(0.8),
                              primaryTint.withOpacity(0.3),
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
                        color: Colors.white.withOpacity(0.7),
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

class _WaveformFallback extends StatelessWidget {
  const _WaveformFallback({
    required this.theme,
    required this.primaryTint,
    required this.seed,
  });

  final ThemeData theme;
  final Color primaryTint;
  final int seed;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SyntheticWaveformPainter(
        baseColor: theme.colorScheme.secondary.withOpacity(0.25),
        highlightColor: primaryTint.withOpacity(0.35),
        seed: seed,
      ),
    );
  }
}

class _SyntheticWaveformPainter extends CustomPainter {
  _SyntheticWaveformPainter({
    required this.baseColor,
    required this.highlightColor,
    required this.seed,
  });

  final Color baseColor;
  final Color highlightColor;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.fill;
    final barCount = 60;
    final random = math.Random(seed);
    final barWidth = size.width / barCount;

    for (int i = 0; i < barCount; i++) {
      final t = i / (barCount - 1);
      final base = math.sin(t * math.pi * 3) * 0.5 + 0.5;
      final jitter = random.nextDouble() * 0.3;
      final height = size.height * (0.2 + base * 0.6 + jitter * 0.2);
      final x = i * barWidth;
      final rect = Rect.fromLTWH(x, (size.height - height) / 2, barWidth * 0.7, height);
      paint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [baseColor, highlightColor],
      ).createShader(rect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SyntheticWaveformPainter oldDelegate) {
    return oldDelegate.baseColor != baseColor ||
        oldDelegate.highlightColor != highlightColor ||
        oldDelegate.seed != seed;
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
                    theme.colorScheme.secondary.withOpacity(0.3),
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
