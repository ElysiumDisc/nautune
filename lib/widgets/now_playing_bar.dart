import 'package:flutter/material.dart';
import 'dart:math' as math;

import '../services/audio_player_service.dart';

class NowPlayingBar extends StatelessWidget {
  const NowPlayingBar({
    super.key,
    required this.audioService,
    required this.onTap,
  });

  final AudioPlayerService audioService;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StreamBuilder<bool>(
      stream: audioService.player.playingStream,
      builder: (context, playingSnapshot) {
        final isPlaying = playingSnapshot.data ?? false;
        final currentTrack = audioService.currentTrack;

        if (currentTrack == null) {
          return const SizedBox.shrink();
        }

        return Material(
          elevation: 8,
          color: theme.colorScheme.surface,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: StreamBuilder<Duration>(
                      stream: audioService.player.positionStream,
                      builder: (context, positionSnapshot) {
                        return _WaveformVisualization(
                          isPlaying: isPlaying,
                          theme: theme,
                        );
                      },
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: StreamBuilder<Duration?>(
                      stream: audioService.player.durationStream,
                      builder: (context, durationSnapshot) {
                        return StreamBuilder<Duration>(
                          stream: audioService.player.positionStream,
                          builder: (context, positionSnapshot) {
                            final duration = durationSnapshot.data;
                            final position = positionSnapshot.data ?? Duration.zero;
                            final progress = duration != null && duration.inMilliseconds > 0
                                ? position.inMilliseconds / duration.inMilliseconds
                                : 0.0;

                            return LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.transparent,
                              valueColor: AlwaysStoppedAnimation(
                                theme.colorScheme.secondary.withValues(alpha: 0.6),
                              ),
                              minHeight: 2,
                            );
                          },
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            icon: Icon(
                              isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            onPressed: () => audioService.playPause(),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                currentTrack.name,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                currentTrack.displayArtist,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => audioService.playPrevious(),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => audioService.playNext(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformVisualization extends StatefulWidget {
  const _WaveformVisualization({
    required this.isPlaying,
    required this.theme,
  });

  final bool isPlaying;
  final ThemeData theme;

  @override
  State<_WaveformVisualization> createState() => _WaveformVisualizationState();
}

class _WaveformVisualizationState extends State<_WaveformVisualization>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void didUpdateWidget(_WaveformVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _WaveformPainter(
            animationValue: _controller.value,
            isPlaying: widget.isPlaying,
            color: widget.theme.colorScheme.secondary.withValues(alpha: 0.1),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.animationValue,
    required this.isPlaying,
    required this.color,
  });

  final double animationValue;
  final bool isPlaying;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const barCount = 60;
    final barWidth = size.width / barCount;
    final random = math.Random(42);

    for (var i = 0; i < barCount; i++) {
      final baseHeight = random.nextDouble() * 0.3 + 0.2;
      final animatedHeight = isPlaying
          ? baseHeight +
              math.sin((animationValue * 2 * math.pi) + (i * 0.3)) * 0.15
          : baseHeight * 0.5;

      final height = size.height * animatedHeight;
      final x = i * barWidth;
      final y = (size.height - height) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x + 1, y, barWidth - 2, height),
        const Radius.circular(2),
      );

      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.isPlaying != isPlaying;
  }
}
