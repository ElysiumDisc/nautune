import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'dart:async';

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
      stream: audioService.playingStream,
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
                    child: _WaveformVisualization(
                      isPlaying: isPlaying,
                      theme: theme,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: StreamBuilder<Duration?>(
                      stream: audioService.durationStream,
                      builder: (context, durationSnapshot) {
                        return StreamBuilder<Duration>(
                          stream: audioService.positionStream,
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

class _WaveformVisualizationState extends State<_WaveformVisualization> {
  static const int barCount = 60;
  List<double> _frequencyMagnitudes = List.filled(barCount, 0.0);
  Timer? _updateTimer;
  Timer? _smoothingTimer;

  @override
  void initState() {
    super.initState();
    _setupReactiveAnimation();
  }

  void _setupReactiveAnimation() {
    _updateTimer?.cancel();
    
    // Reactive animation that responds to audio playback
    _updateTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || !widget.isPlaying) return;
      
      setState(() {
        // Create pseudo-reactive bars using multiple sine waves
        // This simulates bass, mids, and treble frequencies
        final time = DateTime.now().millisecondsSinceEpoch / 1000.0;
        
        for (int i = 0; i < barCount; i++) {
          // Lower frequencies (bass) - slower movement, higher bars on left
          final bassWeight = 1.0 - (i / barCount);
          final bass = math.sin(time * 2.5 + i * 0.2) * 0.4 * bassWeight;
          
          // Mid frequencies - moderate movement, centered
          final midWeight = 1.0 - ((i - barCount / 2).abs() / (barCount / 2));
          final mids = math.sin(time * 4.0 + i * 0.3) * 0.3 * midWeight;
          
          // High frequencies (treble) - faster movement, right side
          final trebleWeight = i / barCount;
          final treble = math.sin(time * 7.0 + i * 0.5) * 0.25 * trebleWeight;
          
          // Combine all frequencies with some randomness
          final randomFactor = math.sin(time * 3.0 + i * 0.8) * 0.1;
          final magnitude = ((bass + mids + treble + randomFactor) * 0.5 + 0.5).clamp(0.0, 1.0);
          
          // Smooth interpolation for natural movement
          _frequencyMagnitudes[i] = _frequencyMagnitudes[i] * 0.6 + magnitude * 0.4;
        }
      });
    });

    // Decay animation when stopped
    _smoothingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (!widget.isPlaying) {
        setState(() {
          for (int i = 0; i < _frequencyMagnitudes.length; i++) {
            _frequencyMagnitudes[i] *= 0.85;
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(_WaveformVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _setupReactiveAnimation();
      }
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _smoothingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WaveformPainter(
        magnitudes: _frequencyMagnitudes,
        isPlaying: widget.isPlaying,
        color: widget.theme.colorScheme.secondary.withValues(alpha: 0.15),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.magnitudes,
    required this.isPlaying,
    required this.color,
  });

  final List<double> magnitudes;
  final bool isPlaying;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final barCount = magnitudes.length;
    final barWidth = size.width / barCount;

    for (var i = 0; i < barCount; i++) {
      final magnitude = magnitudes[i];
      
      // Height based on actual frequency magnitude
      final height = size.height * (magnitude * 0.8 + 0.1); // Min 10% height
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
    return oldDelegate.magnitudes != magnitudes ||
        oldDelegate.isPlaying != isPlaying;
  }
}
