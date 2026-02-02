import 'dart:math' show pi, cos, sin, max;
import 'package:flutter/material.dart';
import 'base_visualizer.dart';

/// Milkdrop/Butterchurn-inspired psychedelic visualizer.
/// Features radial waves, color cycling, kaleidoscope symmetry, and auto-cycling presets.
class ButterchurnVisualizer extends BaseVisualizer {
  const ButterchurnVisualizer({
    super.key,
    required super.audioService,
    super.opacity = 0.6,
  });

  @override
  State<ButterchurnVisualizer> createState() => _ButterchurnVisualizerState();
}

class _ButterchurnVisualizerState extends BaseVisualizerState<ButterchurnVisualizer> {
  // Preset cycling
  int _currentPreset = 0;
  double _presetTimer = 0.0;
  static const double _presetDuration = 30.0; // Seconds per preset
  static const int _presetCount = 3;

  // Motion blur trail (previous frame positions)
  final List<_TrailPoint> _trailPoints = [];
  static const int _maxTrailPoints = 150;

  @override
  Widget buildVisualizer(BuildContext context) {
    // Update preset timer
    _presetTimer += 0.033; // ~30fps
    if (_presetTimer >= _presetDuration) {
      _presetTimer = 0.0;
      _currentPreset = (_currentPreset + 1) % _presetCount;
    }

    // Update trail points
    _updateTrailPoints();

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return CustomPaint(
      painter: _ButterchurnPainter(
        bass: smoothBass,
        mid: smoothMid,
        treble: smoothTreble,
        amplitude: smoothAmplitude,
        time: lastPaintedTime,
        primaryColor: primaryColor,
        opacity: widget.opacity,
        preset: _currentPreset,
        trailPoints: List.from(_trailPoints),
      ),
      size: Size.infinite,
    );
  }

  void _updateTrailPoints() {
    // Add new trail points based on audio
    final intensity = (smoothBass + smoothMid + smoothTreble) / 3;
    if (intensity > 0.1) {
      for (int i = 0; i < 3; i++) {
        final angle = lastPaintedTime * (0.5 + i * 0.3) + i * pi * 2 / 3;
        final radius = 0.2 + smoothBass * 0.3;
        _trailPoints.add(_TrailPoint(
          x: cos(angle) * radius,
          y: sin(angle) * radius,
          age: 0,
          color: _getTrailColor(angle),
          size: 3 + smoothBass * 10,
        ));
      }
    }

    // Age and remove old points
    _trailPoints.removeWhere((p) {
      p.age++;
      return p.age > 40;
    });

    // Limit trail length
    while (_trailPoints.length > _maxTrailPoints) {
      _trailPoints.removeAt(0);
    }
  }

  Color _getTrailColor(double angle) {
    final hue = (angle / (2 * pi) * 360 + lastPaintedTime * 30) % 360;
    return HSLColor.fromAHSL(1.0, hue, 0.8, 0.6).toColor();
  }
}

class _TrailPoint {
  double x;
  double y;
  int age;
  Color color;
  double size;

  _TrailPoint({
    required this.x,
    required this.y,
    required this.age,
    required this.color,
    required this.size,
  });
}

class _ButterchurnPainter extends CustomPainter {
  final double bass;
  final double mid;
  final double treble;
  final double amplitude;
  final double time;
  final Color primaryColor;
  final double opacity;
  final int preset;
  final List<_TrailPoint> trailPoints;

  late final Paint _ringPaint;
  late final Paint _spiralPaint;
  late final Paint _particlePaint;
  late final Paint _glowPaint;
  late final Paint _kaleidoscopePaint;

  static const MaskFilter _blurFilter6 = MaskFilter.blur(BlurStyle.normal, 6);
  static const MaskFilter _blurFilter10 = MaskFilter.blur(BlurStyle.normal, 10);
  static const MaskFilter _blurFilter15 = MaskFilter.blur(BlurStyle.normal, 15);

  _ButterchurnPainter({
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
    required this.time,
    required this.primaryColor,
    required this.opacity,
    required this.preset,
    required this.trailPoints,
  }) {
    _ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..maskFilter = _blurFilter6;
    _spiralPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..maskFilter = _blurFilter6;
    _particlePaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter10;
    _glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter15;
    _kaleidoscopePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
  }

  /// Get cycling color based on time and position
  Color _getCyclingColor(double phase, double intensity) {
    final hue = (phase * 60 + time * 40) % 360;
    final saturation = 0.6 + intensity * 0.4;
    final lightness = 0.4 + intensity * 0.35;
    return HSLColor.fromAHSL(1.0, hue, saturation.clamp(0.0, 1.0), lightness.clamp(0.0, 0.85)).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = (size.width < size.height ? size.width : size.height) / 2;

    // Choose preset-specific rendering
    switch (preset) {
      case 0:
        _paintNeonPulse(canvas, size, center, maxRadius);
        break;
      case 1:
        _paintCosmicSpiral(canvas, size, center, maxRadius);
        break;
      case 2:
        _paintKaleidoscope(canvas, size, center, maxRadius);
        break;
    }

    // Draw motion trails (common to all presets)
    _drawMotionTrails(canvas, center, maxRadius);
  }

  /// Preset 1: Neon Pulse - Bright concentric rings, fast color cycle
  void _paintNeonPulse(Canvas canvas, Size size, Offset center, double maxRadius) {
    // DRAMATIC bass-reactive scaling
    final bassScale = 1.0 + bass * 0.6;

    // Pulsing concentric rings - more rings, bigger pulse
    final ringCount = 10;
    for (int i = 0; i < ringCount; i++) {
      final baseRadius = maxRadius * (0.08 + i * 0.1) * bassScale;
      final pulse = sin(time * 4 + i * 0.6) * bass * 35;
      final radius = baseRadius + pulse;

      final phase = i / ringCount;
      final color = _getCyclingColor(phase * 6, bass);

      _ringPaint.color = color.withValues(alpha: opacity * (0.6 + bass * 0.35));
      _ringPaint.strokeWidth = 3 + bass * 8;

      canvas.drawCircle(center, max(5, radius), _ringPaint);
    }

    // Central burst on bass hits - lower threshold, bigger burst
    if (bass > 0.25) {
      final burstRadius = maxRadius * bass * 1.0;
      final color = _getCyclingColor(time * 2, bass);

      _glowPaint.color = color.withValues(alpha: opacity * (bass - 0.2) * 0.9);
      canvas.drawCircle(center, burstRadius, _glowPaint);

      // More rays, longer
      final rayCount = 16;
      for (int i = 0; i < rayCount; i++) {
        final angle = i * 2 * pi / rayCount + time * 0.8;
        final rayLength = maxRadius * 0.5 * bass;

        final startX = center.dx + cos(angle) * burstRadius * 0.2;
        final startY = center.dy + sin(angle) * burstRadius * 0.2;
        final endX = center.dx + cos(angle) * (burstRadius * 0.2 + rayLength);
        final endY = center.dy + sin(angle) * (burstRadius * 0.2 + rayLength);

        _ringPaint.color = color.withValues(alpha: opacity * bass * 0.7);
        _ringPaint.strokeWidth = 2 + bass * 6;
        canvas.drawLine(Offset(startX, startY), Offset(endX, endY), _ringPaint);
      }
    }

    // Floating particles - more reactive
    final particleCount = 25;
    for (int i = 0; i < particleCount; i++) {
      final speedMod = 0.4 + amplitude * 0.5;
      final angle = time * speedMod + i * pi * 2 / particleCount;
      final radiusOffset = sin(time * 3 + i) * maxRadius * 0.2 * bassScale;
      final baseParticleRadius = maxRadius * (0.25 + i % 4 * 0.12);
      final particleRadius = baseParticleRadius + radiusOffset + bass * maxRadius * 0.15;

      final px = center.dx + cos(angle) * particleRadius;
      final py = center.dy + sin(angle) * particleRadius;

      final color = _getCyclingColor(i / particleCount * 8 + time, mid);
      _particlePaint.color = color.withValues(alpha: opacity * (0.6 + mid * 0.35));

      canvas.drawCircle(Offset(px, py), 4 + treble * 8 + bass * 4, _particlePaint);
    }
  }

  /// Preset 2: Cosmic Spiral - Rotating spiral arms, slow drift
  void _paintCosmicSpiral(Canvas canvas, Size size, Offset center, double maxRadius) {
    // Bass-reactive scaling
    final bassScale = 1.0 + bass * 0.5;
    final rotationSpeed = 0.25 + amplitude * 0.35;

    // Draw spiral arms - more arms, more reactive
    final armCount = 5;
    for (int arm = 0; arm < armCount; arm++) {
      final armOffset = arm * 2 * pi / armCount;
      final points = <Offset>[];

      // Generate spiral points with bass-reactive wobble
      for (double t = 0; t < 5 * pi; t += 0.08) {
        final spiralRadius = t / (5 * pi) * maxRadius * 0.95 * bassScale;
        final angle = t + armOffset + time * rotationSpeed;
        final wobble = sin(t * 4 + time * 2) * bass * 25;

        final x = center.dx + cos(angle) * (spiralRadius + wobble);
        final y = center.dy + sin(angle) * (spiralRadius + wobble);
        points.add(Offset(x, y));
      }

      // Draw spiral path
      if (points.length > 1) {
        final path = Path()..moveTo(points[0].dx, points[0].dy);
        for (int i = 1; i < points.length; i++) {
          path.lineTo(points[i].dx, points[i].dy);
        }

        final color = _getCyclingColor(arm / armCount * 8 + time, amplitude);
        _spiralPaint.color = color.withValues(alpha: opacity * (0.5 + mid * 0.45));
        _spiralPaint.strokeWidth = 2.5 + bass * 5;

        canvas.drawPath(path, _spiralPaint);
      }
    }

    // Central vortex - more dramatic
    final vortexRadius = maxRadius * 0.2 * (1 + bass * 0.8);
    for (int i = 0; i < 7; i++) {
      final radius = vortexRadius * (1 - i * 0.12);
      final color = _getCyclingColor(i.toDouble() + time * 2, bass);

      _ringPaint.color = color.withValues(alpha: opacity * (0.7 - i * 0.08));
      _ringPaint.strokeWidth = 4 + bass * 3 - i * 0.5;

      canvas.drawCircle(center, max(5, radius), _ringPaint);
    }

    // Bass pulse from center
    if (bass > 0.3) {
      final pulseRadius = vortexRadius * (1.5 + bass * 2);
      final color = _getCyclingColor(time * 3, bass);
      _glowPaint.color = color.withValues(alpha: opacity * (bass - 0.3) * 0.7);
      canvas.drawCircle(center, pulseRadius, _glowPaint);
    }

    // Drifting stars - more of them, more reactive
    final starCount = 25;
    for (int i = 0; i < starCount; i++) {
      final speedMod = 0.2 + mid * 0.3;
      final angle = i * 2.2 + time * speedMod;
      final distance = maxRadius * (0.15 + (i % 6) * 0.12 + sin(time * 1.5 + i) * 0.15 * bassScale);

      final sx = center.dx + cos(angle) * distance;
      final sy = center.dy + sin(angle) * distance;

      final color = _getCyclingColor(i / starCount * 8 + time * 0.5, treble);
      _particlePaint.color = color.withValues(alpha: opacity * (0.5 + treble * 0.45));

      canvas.drawCircle(Offset(sx, sy), 3 + treble * 6 + bass * 3, _particlePaint);
    }
  }

  /// Preset 3: Kaleidoscope - High symmetry, geometric patterns
  void _paintKaleidoscope(Canvas canvas, Size size, Offset center, double maxRadius) {
    // Bass-reactive symmetry and scaling
    final bassScale = 1.0 + bass * 0.5;
    final symmetry = 8; // 8-fold symmetry for more dramatic effect
    final angleStep = 2 * pi / symmetry;
    final rotationSpeed = 0.15 + amplitude * 0.2;

    // Draw kaleidoscope segments
    for (int seg = 0; seg < symmetry; seg++) {
      final segAngle = seg * angleStep + time * rotationSpeed;

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(segAngle);

      // Draw geometric shapes within segment
      _drawKaleidoscopeSegment(canvas, maxRadius * bassScale);

      canvas.restore();
    }

    // Bass pulse ring
    if (bass > 0.25) {
      final pulseRadius = maxRadius * 0.6 * bass;
      final color = _getCyclingColor(time * 4, bass);
      _glowPaint.color = color.withValues(alpha: opacity * (bass - 0.2) * 0.6);
      canvas.drawCircle(center, pulseRadius, _glowPaint);
    }

    // Center mandala - more rings, more reactive
    final mandalaRadius = maxRadius * 0.25 * (1 + bass * 0.6);
    for (int ring = 0; ring < 6; ring++) {
      final radius = mandalaRadius * (0.2 + ring * 0.18);
      final petals = 8 + ring * 3;

      for (int petal = 0; petal < petals; petal++) {
        final speedMod = 0.3 + ring * 0.12 + mid * 0.2;
        final angle = petal * 2 * pi / petals + time * speedMod;
        final petalLength = radius * 0.5 * (1 + mid * 0.6 + bass * 0.3);

        final startX = cos(angle) * radius * 0.4;
        final startY = sin(angle) * radius * 0.4;
        final endX = cos(angle) * (radius * 0.4 + petalLength);
        final endY = sin(angle) * (radius * 0.4 + petalLength);

        final color = _getCyclingColor(ring * 1.5 + petal / petals * 3 + time, amplitude);
        _kaleidoscopePaint.color = color.withValues(alpha: opacity * (0.65 + amplitude * 0.3));
        _kaleidoscopePaint.strokeWidth = 2.5 + bass * 4;

        canvas.drawLine(
          Offset(center.dx + startX, center.dy + startY),
          Offset(center.dx + endX, center.dy + endY),
          _kaleidoscopePaint,
        );
      }
    }

    // Center core glow
    final coreRadius = mandalaRadius * 0.3 * (1 + treble * 0.5);
    final coreColor = _getCyclingColor(time * 5, amplitude);
    _glowPaint.color = coreColor.withValues(alpha: opacity * (0.5 + amplitude * 0.4));
    canvas.drawCircle(center, coreRadius, _glowPaint);
  }

  void _drawKaleidoscopeSegment(Canvas canvas, double maxRadius) {
    // Triangular patterns - more depth, more reactive
    final depth = 6;
    for (int d = 0; d < depth; d++) {
      final baseDistance = maxRadius * (0.15 + d * 0.14);
      final triangleSize = maxRadius * 0.12 * (1 + bass * 0.6 + mid * 0.3);
      final wobble = sin(time * 3 + d * 0.8) * (treble * 15 + bass * 10);

      final x1 = baseDistance + wobble;
      final y1 = -triangleSize / 2;
      final x2 = baseDistance + triangleSize + wobble;
      final y2 = 0.0;
      final x3 = baseDistance + wobble;
      final y3 = triangleSize / 2;

      final color = _getCyclingColor(d * 2.0 + time, mid);
      _kaleidoscopePaint.color = color.withValues(alpha: opacity * (0.55 + mid * 0.4));
      _kaleidoscopePaint.strokeWidth = 2 + bass * 3;

      final path = Path()
        ..moveTo(x1, y1)
        ..lineTo(x2, y2)
        ..lineTo(x3, y3)
        ..close();

      canvas.drawPath(path, _kaleidoscopePaint);
    }

    // Arc decorations - more arcs, more reactive
    for (int arc = 0; arc < 5; arc++) {
      final arcRadius = maxRadius * (0.2 + arc * 0.18);
      final sweepAngle = pi / 6 * (1 + sin(time * 2 + arc) * 0.4 + bass * 0.3);

      final color = _getCyclingColor(arc * 2.5 + time * 0.5, treble);
      _kaleidoscopePaint.color = color.withValues(alpha: opacity * (0.45 + treble * 0.4));
      _kaleidoscopePaint.strokeWidth = 2 + bass * 2;

      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: arcRadius),
        -sweepAngle / 2,
        sweepAngle,
        false,
        _kaleidoscopePaint,
      );
    }
  }

  /// Draw motion trails (common effect)
  void _drawMotionTrails(Canvas canvas, Offset center, double maxRadius) {
    for (final point in trailPoints) {
      final alpha = ((40 - point.age) / 40 * opacity).clamp(0.0, 1.0);
      if (alpha < 0.05) continue;

      final x = center.dx + point.x * maxRadius;
      final y = center.dy + point.y * maxRadius;
      final size = point.size * (1 - point.age / 50);

      _particlePaint.color = point.color.withValues(alpha: alpha * 0.6);
      canvas.drawCircle(Offset(x, y), max(1, size), _particlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ButterchurnPainter old) {
    // Threshold-based repaint for battery optimization
    const tolerance = 0.01;
    const timeTolerance = 0.05; // Skip frames during slow animations

    // Always repaint if preset changed or trail points changed significantly
    if (preset != old.preset || trailPoints.length != old.trailPoints.length) {
      return true;
    }

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
