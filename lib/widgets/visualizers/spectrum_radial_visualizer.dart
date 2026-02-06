import 'dart:math' show pi, cos, sin, max;
import 'package:flutter/material.dart';
import 'base_visualizer.dart';

/// Circular/radial spectrum visualizer.
/// Bars arranged in a circle extending outward from center with slow rotation.
class SpectrumRadialVisualizer extends BaseVisualizer {
  const SpectrumRadialVisualizer({
    super.key,
    required super.audioService,
    super.opacity = 0.6,
  });

  @override
  State<SpectrumRadialVisualizer> createState() => _SpectrumRadialVisualizerState();
}

class _SpectrumRadialVisualizerState extends BaseVisualizerState<SpectrumRadialVisualizer> {
  static const int _barCount = 72; // More bars for smooth circle

  // Peak hold values
  final List<double> _peakValues = List<double>.filled(_barCount, 0.0);
  final List<int> _peakHoldFrames = List<int>.filled(_barCount, 0);
  static const int _peakHoldDuration = 10;
  static const double _peakFallSpeed = 0.03;

  @override
  int get spectrumBarCount => _barCount;

  void _updatePeaks(List<double> bars) {
    for (int i = 0; i < _barCount && i < bars.length; i++) {
      final value = bars[i];

      if (value >= _peakValues[i]) {
        _peakValues[i] = value;
        _peakHoldFrames[i] = _peakHoldDuration;
      } else if (_peakHoldFrames[i] > 0) {
        _peakHoldFrames[i]--;
      } else {
        _peakValues[i] = max(0.0, _peakValues[i] - _peakFallSpeed);
      }
    }
  }

  @override
  Widget buildVisualizer(BuildContext context) {
    final bars = getSpectrumBars(_barCount);
    _updatePeaks(bars);

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return CustomPaint(
      painter: _SpectrumRadialPainter(
        bars: bars,
        peaks: _peakValues,
        primaryColor: primaryColor,
        opacity: widget.opacity,
        bass: smoothBass,
        mid: smoothMid,
        treble: smoothTreble,
        amplitude: smoothAmplitude,
        time: lastPaintedTime,
      ),
      size: Size.infinite,
    );
  }
}

class _SpectrumRadialPainter extends CustomPainter {
  final List<double> bars;
  final List<double> peaks;
  final Color primaryColor;
  final double opacity;
  final double bass;
  final double mid;
  final double treble;
  final double amplitude;
  final double time;

  late final Paint _barPaint;
  late final Paint _peakPaint;
  late final Paint _glowPaint;
  late final Paint _centerPaint;

  static const MaskFilter _blurFilter4 = MaskFilter.blur(BlurStyle.normal, 4);
  static const MaskFilter _blurFilter8 = MaskFilter.blur(BlurStyle.normal, 8);
  static const MaskFilter _blurFilter12 = MaskFilter.blur(BlurStyle.normal, 12);

  _SpectrumRadialPainter({
    required this.bars,
    required this.peaks,
    required this.primaryColor,
    required this.opacity,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
    required this.time,
  }) {
    _barPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    _peakPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter4;
    _glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter12;
    _centerPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter8;
  }

  /// Get color based on angle position
  Color _getBarColor(double angle, double value) {
    // Rainbow hue based on angle
    final hue = ((angle / (2 * pi)) * 360 + time * 20) % 360;
    final saturation = 0.7 + value * 0.3;
    final lightness = 0.4 + value * 0.3;

    return HSLColor.fromAHSL(1.0, hue, saturation.clamp(0.0, 1.0), lightness.clamp(0.0, 0.8)).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = (size.width < size.height ? size.width : size.height) / 2;

    // Bass-reactive sizing
    final bassBoost = 1.0 + bass * 0.4;
    final innerRadius = maxRadius * 0.22;
    final maxBarLength = maxRadius * 0.68 * bassBoost;

    // Rotation speed increases with amplitude
    final rotationSpeed = 0.08 + amplitude * 0.15;
    final rotation = time * rotationSpeed;

    // Draw center glow (pulsing dramatically with bass)
    final centerGlowRadius = innerRadius * (0.9 + bass * 0.8);
    _centerPaint.color = primaryColor.withValues(alpha: opacity * (0.4 + bass * 0.5));
    canvas.drawCircle(center, centerGlowRadius, _centerPaint);

    // Secondary bass pulse ring
    if (bass > 0.3) {
      final pulseRadius = innerRadius * (1.2 + bass * 1.5);
      _centerPaint.color = primaryColor.withValues(alpha: opacity * (bass - 0.3) * 0.6);
      canvas.drawCircle(center, pulseRadius, _centerPaint);
    }

    // Inner core — brighter, pulses with treble + mid
    final coreRadius = innerRadius * (0.3 + treble * 0.2 + mid * 0.1);
    _centerPaint.color = primaryColor.withValues(alpha: opacity * (0.7 + amplitude * 0.3));
    _centerPaint.maskFilter = null;
    canvas.drawCircle(center, coreRadius, _centerPaint);
    // Bright highlight in center
    _centerPaint.color = Colors.white.withValues(alpha: opacity * (0.15 + bass * 0.2));
    canvas.drawCircle(center, coreRadius * 0.5, _centerPaint);
    _centerPaint.maskFilter = _blurFilter8;

    final barCount = bars.length;
    final angleStep = 2 * pi / barCount;

    // Draw glow layer first
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      if (value < 0.03) continue;

      final angle = i * angleStep + rotation;
      final barLength = value * maxBarLength;
      final color = _getBarColor(angle, value);

      final glowX = center.dx + cos(angle) * (innerRadius + barLength);
      final glowY = center.dy + sin(angle) * (innerRadius + barLength);

      _glowPaint.color = color.withValues(alpha: opacity * 0.2 * value);
      canvas.drawCircle(Offset(glowX, glowY), 6 + value * 8, _glowPaint);
    }

    // Draw bars
    _barPaint.strokeWidth = max(2.0, (2 * pi * innerRadius / barCount) * 0.6);

    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      final angle = i * angleStep + rotation;
      final barLength = max(2.0, value * maxBarLength);
      final color = _getBarColor(angle, value);

      final startX = center.dx + cos(angle) * innerRadius;
      final startY = center.dy + sin(angle) * innerRadius;
      final endX = center.dx + cos(angle) * (innerRadius + barLength);
      final endY = center.dy + sin(angle) * (innerRadius + barLength);

      _barPaint.color = color.withValues(alpha: opacity * (0.6 + value * 0.4));
      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), _barPaint);
    }

    // Draw peak dots
    for (int i = 0; i < barCount && i < peaks.length; i++) {
      final peakValue = peaks[i];
      if (peakValue < 0.05) continue;

      final angle = i * angleStep + rotation;
      final peakDistance = innerRadius + peakValue * maxBarLength + 4;
      final color = _getBarColor(angle, peakValue);

      final peakX = center.dx + cos(angle) * peakDistance;
      final peakY = center.dy + sin(angle) * peakDistance;

      _peakPaint.color = color.withValues(alpha: opacity * 0.85);
      canvas.drawCircle(Offset(peakX, peakY), 2.5, _peakPaint);
    }

    // Draw outer ring glow on bass hits
    if (bass > 0.4) {
      final ringRadius = innerRadius + maxBarLength + 10;
      _glowPaint.color = primaryColor.withValues(alpha: opacity * (bass - 0.4) * 0.5);
      canvas.drawCircle(center, ringRadius, _glowPaint);
    }

    // Draw inner pulsing ring
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = primaryColor.withValues(alpha: opacity * (0.4 + mid * 0.4))
      ..maskFilter = _blurFilter4;

    canvas.drawCircle(center, innerRadius * (1.0 + treble * 0.1), ringPaint);
  }

  @override
  bool shouldRepaint(covariant _SpectrumRadialPainter old) {
    // Threshold-based repaint for battery optimization
    // Always repaint if time changed significantly (animation) or audio values changed
    const tolerance = 0.01;
    const timeTolerance = 0.05; // Skip frames during slow animations

    // Skip if nothing meaningful changed
    if ((time - old.time).abs() < timeTolerance &&
        (bass - old.bass).abs() < tolerance &&
        (mid - old.mid).abs() < tolerance &&
        (treble - old.treble).abs() < tolerance &&
        (amplitude - old.amplitude).abs() < tolerance) {
      return false;
    }
    return true;
  }
}
