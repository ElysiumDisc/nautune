import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'base_visualizer.dart';

/// Mirrored spectrum bars visualizer.
/// Bars extend symmetrically from the center line, creating a "sound wave" look.
class SpectrumMirrorVisualizer extends BaseVisualizer {
  const SpectrumMirrorVisualizer({
    super.key,
    required super.audioService,
    super.opacity = 0.6,
  });

  @override
  State<SpectrumMirrorVisualizer> createState() => _SpectrumMirrorVisualizerState();
}

class _SpectrumMirrorVisualizerState extends BaseVisualizerState<SpectrumMirrorVisualizer> {
  static const int _barCount = 64;

  // Peak hold values
  final List<double> _peakValues = List<double>.filled(_barCount, 0.0);
  final List<int> _peakHoldFrames = List<int>.filled(_barCount, 0);
  static const int _peakHoldDuration = 12;
  static const double _peakFallSpeed = 0.025;

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
      painter: _SpectrumMirrorPainter(
        bars: bars,
        peaks: _peakValues,
        primaryColor: primaryColor,
        opacity: widget.opacity,
        bass: smoothBass,
        amplitude: smoothAmplitude,
      ),
      size: Size.infinite,
    );
  }
}

class _SpectrumMirrorPainter extends CustomPainter {
  final List<double> bars;
  final List<double> peaks;
  final Color primaryColor;
  final double opacity;
  final double bass;
  final double amplitude;

  late final Paint _barPaint;
  late final Paint _peakPaint;
  late final Paint _glowPaint;
  late final Paint _centerLinePaint;

  static const MaskFilter _blurFilter6 = MaskFilter.blur(BlurStyle.normal, 6);
  static const MaskFilter _blurFilter10 = MaskFilter.blur(BlurStyle.normal, 10);

  // Cache for pre-computed HSL values from primary color
  static Color? _cachedPrimaryColor;
  static double _cachedBaseHue = 0.0;
  static double _cachedBaseSaturation = 0.5;
  static double _cachedBaseLightness = 0.5;

  // Pre-computed hue offsets for bar indices (avoids per-bar computation)
  static final List<double> _hueOffsets = List.generate(64, (i) => (i / 64) * 60 - 30);

  // Gradient cache to avoid creating new shaders every frame
  final Map<int, Shader> _topGradientCache = {};
  final Map<int, Shader> _bottomGradientCache = {};

  _SpectrumMirrorPainter({
    required this.bars,
    required this.peaks,
    required this.primaryColor,
    required this.opacity,
    required this.bass,
    required this.amplitude,
  }) {
    _barPaint = Paint()..style = PaintingStyle.fill;
    _peakPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter6;
    _glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter10;
    _centerLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..maskFilter = _blurFilter6;

    // Cache HSL conversion of primary color (expensive operation)
    if (_cachedPrimaryColor != primaryColor) {
      _cachedPrimaryColor = primaryColor;
      final primaryHsl = HSLColor.fromColor(primaryColor);
      _cachedBaseHue = primaryHsl.hue;
      _cachedBaseSaturation = primaryHsl.saturation;
      _cachedBaseLightness = primaryHsl.lightness;
    }
  }

  /// Get color based on frequency position
  /// Uses cached HSL values to avoid per-bar HSL conversion
  Color _getBarColor(int index, int total, double value) {
    // Use cached hue offset instead of computing every time
    final hueShift = _hueOffsets[index.clamp(0, 63)];
    final newHue = (_cachedBaseHue + hueShift) % 360;

    // Boost saturation and lightness with value
    final saturation = (_cachedBaseSaturation * (0.7 + value * 0.3)).clamp(0.0, 1.0);
    final lightness = (_cachedBaseLightness * (0.8 + value * 0.4)).clamp(0.0, 0.9);

    return HSLColor.fromAHSL(1.0, newHue, saturation, lightness).toColor();
  }

  /// Get cached gradient shader for top bar
  Shader _getTopGradient(int index, Rect rect, Color color) {
    final heightBucket = (rect.height / 10).round();
    final key = index * 1000 + heightBucket;

    return _topGradientCache.putIfAbsent(key, () {
      return LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          color.withValues(alpha: opacity * 0.95),
          color.withValues(alpha: opacity * 0.5),
        ],
      ).createShader(rect);
    });
  }

  /// Get cached gradient shader for bottom bar
  Shader _getBottomGradient(int index, Rect rect, Color color) {
    final heightBucket = (rect.height / 10).round();
    final key = index * 1000 + heightBucket;

    return _bottomGradientCache.putIfAbsent(key, () {
      return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: opacity * 0.95),
          color.withValues(alpha: opacity * 0.5),
        ],
      ).createShader(rect);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final barCount = bars.length;
    final spacing = 1.5;
    final totalSpacing = spacing * (barCount - 1);
    final barWidth = (size.width - totalSpacing) / barCount;
    final centerY = size.height / 2;

    final effectiveHeight = size.height;

    // Bass-reactive height - bars extend further on bass hits
    final bassBoost = 1.0 + bass * 0.5;
    final maxBarHeight = effectiveHeight * 0.45 * bassBoost;

    // Draw center line glow - pulses with bass
    final centerLineWidth = 2.0 + bass * 3.0;
    _centerLinePaint.strokeWidth = centerLineWidth;
    _centerLinePaint.color = primaryColor.withValues(alpha: opacity * (0.4 + bass * 0.5));
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      _centerLinePaint,
    );

    // Draw glow layer first - more intense with bass
    final glowBoost = 0.3 + bass * 0.4;
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      if (value < 0.03) continue;

      final x = i * (barWidth + spacing);
      final barHeight = value * maxBarHeight;
      final color = _getBarColor(i, barCount, value);

      _glowPaint.color = color.withValues(alpha: opacity * glowBoost * value);

      // Top glow
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - 2, centerY - barHeight - 6, barWidth + 4, barHeight + 6),
          const Radius.circular(4),
        ),
        _glowPaint,
      );

      // Bottom glow (mirrored)
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - 2, centerY, barWidth + 4, barHeight + 6),
          const Radius.circular(4),
        ),
        _glowPaint,
      );
    }

    // Draw bars (both top and bottom)
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      final x = i * (barWidth + spacing);
      final barHeight = max(1.0, value * maxBarHeight);
      final color = _getBarColor(i, barCount, value);

      // Top bar (going up)
      final topRect = Rect.fromLTWH(
        x,
        centerY - barHeight,
        barWidth,
        barHeight,
      );

      _barPaint.shader = _getTopGradient(i, topRect, color);

      canvas.drawRRect(
        RRect.fromRectAndRadius(topRect, Radius.circular(barWidth / 4)),
        _barPaint,
      );

      // Bottom bar (going down, mirrored)
      final bottomRect = Rect.fromLTWH(
        x,
        centerY,
        barWidth,
        barHeight,
      );

      _barPaint.shader = _getBottomGradient(i, bottomRect, color);

      canvas.drawRRect(
        RRect.fromRectAndRadius(bottomRect, Radius.circular(barWidth / 4)),
        _barPaint,
      );
    }

    // Draw peak indicators
    for (int i = 0; i < barCount && i < peaks.length; i++) {
      final peakValue = peaks[i];
      if (peakValue < 0.05) continue;

      final x = i * (barWidth + spacing);
      final peakHeight = peakValue * maxBarHeight;
      final color = _getBarColor(i, barCount, peakValue);

      _peakPaint.color = color.withValues(alpha: opacity * 0.85);

      // Top peak
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centerY - peakHeight - 2, barWidth, 2),
          const Radius.circular(1),
        ),
        _peakPaint,
      );

      // Bottom peak (mirrored)
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centerY + peakHeight, barWidth, 2),
          const Radius.circular(1),
        ),
        _peakPaint,
      );
    }

    // Edge glow on bass hits
    if (bass > 0.4) {
      final edgeGlow = bass * 0.4;
      final glowHeight = effectiveHeight * 0.2;

      // Top edge
      final topRect = Rect.fromLTWH(0, 0, size.width, glowHeight);
      _glowPaint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: opacity * edgeGlow),
          Colors.transparent,
        ],
      ).createShader(topRect);
      canvas.drawRect(topRect, _glowPaint);

      // Bottom edge
      final bottomRect = Rect.fromLTWH(0, size.height - glowHeight, size.width, glowHeight);
      _glowPaint.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          primaryColor.withValues(alpha: opacity * edgeGlow),
          Colors.transparent,
        ],
      ).createShader(bottomRect);
      canvas.drawRect(bottomRect, _glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumMirrorPainter old) {
    const tolerance = 0.005;
    if (bars.length != old.bars.length) return true;
    if ((bass - old.bass).abs() > tolerance) return true;
    if ((amplitude - old.amplitude).abs() > tolerance) return true;
    if ((opacity - old.opacity).abs() > tolerance) return true;
    if (primaryColor != old.primaryColor) return true;
    for (int i = 0; i < bars.length; i++) {
      if ((bars[i] - old.bars[i]).abs() > tolerance) return true;
    }
    return false;
  }
}
