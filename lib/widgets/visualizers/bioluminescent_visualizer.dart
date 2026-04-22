import 'dart:math' show pi, sin, cos;
import 'package:flutter/material.dart';
import 'base_visualizer.dart';

/// Bioluminescent ocean-themed audio visualizer.
/// On Linux: Uses real FFT from PulseAudio system audio loopback.
/// On other platforms: Uses metadata-driven frequency bands (genre/ReplayGain).
class BioluminescentVisualizer extends BaseVisualizer {
  const BioluminescentVisualizer({
    super.key,
    required super.audioService,
    super.opacity = 0.6,
  });

  @override
  State<BioluminescentVisualizer> createState() => _BioluminescentVisualizerState();
}

class _BioluminescentVisualizerState extends BaseVisualizerState<BioluminescentVisualizer> {
  @override
  Widget buildVisualizer(BuildContext context) {
    final glowColor = Theme.of(context).colorScheme.primary;

    return CustomPaint(
      painter: _BioluminescentWavePainter(
        time: lastPaintedTime,
        bass: smoothBass,
        mid: smoothMid,
        treble: smoothTreble,
        amplitude: smoothAmplitude,
        glowColor: glowColor,
        opacity: widget.opacity,
      ),
      size: Size.infinite,
    );
  }
}

class _BioluminescentWavePainter extends CustomPainter {
  final double time;
  final double bass;
  final double mid;
  final double treble;
  final double amplitude;
  final Color glowColor;
  final double opacity;

  // Cached paint objects to avoid allocation in paint()
  late final Paint _wavePaint0;
  late final Paint _wavePaint1;
  late final Paint _wavePaint2;
  late final Paint _pulsePaint;
  late final Paint _particlePaint;
  late final Paint _gradientPaint;
  late final Paint _topGlowPaint;

  // Cached mask filters (immutable, safe to reuse)
  static const MaskFilter _blurFilter12 = MaskFilter.blur(BlurStyle.normal, 12);
  static const MaskFilter _blurFilter6 = MaskFilter.blur(BlurStyle.normal, 6);
  static const MaskFilter _blurFilter3 = MaskFilter.blur(BlurStyle.normal, 3);
  static const MaskFilter _blurFilter15 = MaskFilter.blur(BlurStyle.normal, 15);
  static const MaskFilter _blurFilter10 = MaskFilter.blur(BlurStyle.normal, 10);

  // Pre-computed colors (computed once in constructor)
  late final Color _waveColor0;
  late final Color _waveColor1;
  late final Color _waveColor2;

  _BioluminescentWavePainter({
    required this.time,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
    required this.glowColor,
    required this.opacity,
  }) {
    // Pre-compute wave colors for each layer
    _waveColor0 = glowColor.withValues(alpha: opacity * 0.8);
    _waveColor1 = glowColor.withValues(alpha: opacity * 0.85 * 0.8);
    _waveColor2 = glowColor.withValues(alpha: opacity * 0.7 * 0.8);

    // Initialize cached paint objects
    _wavePaint0 = Paint()
      ..color = _waveColor0
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..maskFilter = _blurFilter12;

    _wavePaint1 = Paint()
      ..color = _waveColor1
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..maskFilter = _blurFilter6;

    _wavePaint2 = Paint()
      ..color = _waveColor2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..maskFilter = _blurFilter3;

    _pulsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..maskFilter = _blurFilter15;

    _particlePaint = Paint()
      ..maskFilter = _blurFilter10;

    _gradientPaint = Paint();
    _topGlowPaint = Paint();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // DRAMATIC bass response - wave height scales massively with bass
    final baseAmplitude = 0.08 + amplitude * 0.25;
    final bassAmplitude = baseAmplitude + bass * 2.0;  // HUGE bass impact

    // Pre-compute shared values
    final halfHeight = size.height / 2;
    final halfWidth = size.width / 2;

    // Draw wave layers using cached paints
    final wavePaints = [_wavePaint0, _wavePaint1, _wavePaint2];

    for (int layer = 0; layer < 3; layer++) {
      final paint = wavePaints[layer];

      final path = Path();
      final waveAmplitude = size.height * bassAmplitude * (1 - layer * 0.15);
      final phase = time + layer * 0.5;
      final frequency = 2.5 + layer * 0.3 + bass * 0.5;

      path.moveTo(0, halfHeight);
      // Step 3 px instead of 2 — on a 1080-wide canvas this drops lineTo
      // calls from ~540 to ~360 per layer (~540 fewer per frame across
      // 3 layers) with no visible difference thanks to path smoothing.
      for (double x = 0; x <= size.width; x += 3) {
        final normalizedX = x / size.width;

        // Primary wave
        final y1 = sin(normalizedX * frequency * pi + phase) * waveAmplitude;

        // Secondary harmonic
        final y2 = sin(normalizedX * frequency * 2.5 * pi + phase * 1.3) *
                   waveAmplitude * 0.35 * (0.2 + mid * 2.0);

        // Sub-bass rumble
        final subBass = sin(normalizedX * 1.5 * pi + time * 0.7) *
                        bass * size.height * 0.15;

        // Treble shimmer
        final shimmer = sin(normalizedX * 20 * pi + time * 4) *
                        treble * size.height * 0.08;

        path.lineTo(x, halfHeight + y1 + y2 + subBass + shimmer);
      }
      canvas.drawPath(path, paint);
    }

    // BASS PULSE - expanding rings on bass hits
    if (bass > 0.3) {
      final pulseRadius = size.width * 0.3 * bass;
      _pulsePaint.color = glowColor.withValues(alpha: opacity * bass * 0.5);
      canvas.drawCircle(Offset(halfWidth, halfHeight), pulseRadius, _pulsePaint);
    }

    // Floating bioluminescent particles
    for (int i = 0; i < 15; i++) {
      final particlePhase = i * 0.42;
      final speed = 0.06 + mid * 0.2 + bass * 0.1;

      final px = ((time * speed + particlePhase) % 1.0) * size.width;
      final verticalPhase = time * 0.4 + i * 0.7;

      final py = halfHeight +
          sin(verticalPhase) * size.height * 0.4 * bassAmplitude +
          cos(verticalPhase * 2) * bass * size.height * 0.15;

      final radius = 3.0 + bass * 12.0 + treble * 5.0 + amplitude * 4.0 +
                     sin(time * 3 + i) * 2.0;
      final particleOpacity = (0.5 + sin(time * 2 + i * 0.5) * 0.3 + bass * 0.3) * opacity;

      _particlePaint.color = glowColor.withValues(alpha: particleOpacity.clamp(0.0, 1.0));
      canvas.drawCircle(Offset(px, py), radius.clamp(2.0, 20.0), _particlePaint);
    }

    // Bottom gradient glow
    final glowIntensity = 0.2 + bass * 0.6 + amplitude * 0.3;
    final bottomRect = Rect.fromLTWH(0, size.height * 0.4, size.width, size.height * 0.6);
    _gradientPaint.shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.transparent,
        glowColor.withValues(alpha: opacity * glowIntensity.clamp(0.0, 0.8)),
      ],
    ).createShader(bottomRect);
    canvas.drawRect(bottomRect, _gradientPaint);

    // Top edge glow on big bass hits
    if (bass > 0.5) {
      final topRect = Rect.fromLTWH(0, 0, size.width, size.height * 0.3);
      _topGlowPaint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          Colors.transparent,
          glowColor.withValues(alpha: opacity * (bass - 0.5) * 0.8),
        ],
      ).createShader(topRect);
      canvas.drawRect(topRect, _topGlowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BioluminescentWavePainter old) {
    // Only repaint if values have changed significantly
    const threshold = 0.01;
    return (old.bass - bass).abs() > threshold ||
           (old.mid - mid).abs() > threshold ||
           (old.treble - treble).abs() > threshold ||
           (old.amplitude - amplitude).abs() > threshold ||
           (old.time - time).abs() > 0.016 ||
           old.glowColor != glowColor ||
           old.opacity != opacity;
  }
}
