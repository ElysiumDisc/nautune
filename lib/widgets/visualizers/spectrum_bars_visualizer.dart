import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'base_visualizer.dart';

/// Classic vertical frequency bars visualizer (Audiomotion-style).
/// Features gradient coloring, peak hold indicators, and rounded bar caps.
class SpectrumBarsVisualizer extends BaseVisualizer {
  const SpectrumBarsVisualizer({
    super.key,
    required super.audioService,
    super.opacity = 0.6,
  });

  @override
  State<SpectrumBarsVisualizer> createState() => _SpectrumBarsVisualizerState();
}

class _SpectrumBarsVisualizerState extends BaseVisualizerState<SpectrumBarsVisualizer> {
  static const int _barCount = 48;

  // Peak hold values (fall slowly)
  final List<double> _peakValues = List<double>.filled(_barCount, 0.0);
  final List<int> _peakHoldFrames = List<int>.filled(_barCount, 0);
  static const int _peakHoldDuration = 15; // Frames to hold peak
  static const double _peakFallSpeed = 0.02;

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
      painter: _SpectrumBarsPainter(
        bars: bars,
        peaks: _peakValues,
        primaryColor: primaryColor,
        opacity: widget.opacity,
        bass: smoothBass,
      ),
      size: Size.infinite,
    );
  }
}

class _SpectrumBarsPainter extends CustomPainter {
  final List<double> bars;
  final List<double> peaks;
  final Color primaryColor;
  final double opacity;
  final double bass;

  late final Paint _barPaint;
  late final Paint _peakPaint;
  late final Paint _glowPaint;

  static const MaskFilter _blurFilter8 = MaskFilter.blur(BlurStyle.normal, 8);

  // Cache for pre-computed HSL values from primary color
  static Color? _cachedPrimaryColor;
  static double _cachedBaseHue = 0.0;
  static double _cachedBaseSaturation = 0.5;

  // Pre-computed color array for bar indices (avoids HSL conversion per bar)
  static final List<double> _hueOffsets = List.generate(48, (i) => -30 + (i / 48) * 70);

  // Gradient cache to avoid creating new shaders every frame
  final Map<int, Shader> _gradientCache = {};

  _SpectrumBarsPainter({
    required this.bars,
    required this.peaks,
    required this.primaryColor,
    required this.opacity,
    required this.bass,
  }) {
    _barPaint = Paint()..style = PaintingStyle.fill;
    _peakPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter8;
    _glowPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = _blurFilter8;

    // Cache HSL conversion of primary color (expensive operation)
    if (_cachedPrimaryColor != primaryColor) {
      _cachedPrimaryColor = primaryColor;
      final primaryHsl = HSLColor.fromColor(primaryColor);
      _cachedBaseHue = primaryHsl.hue;
      _cachedBaseSaturation = primaryHsl.saturation;
    }
  }

  /// Get color based on frequency position using album art color (primary)
  /// Creates a gradient from warm (bass) to cool (treble) based on primary color
  /// Uses cached HSL values to avoid per-bar HSL conversion
  Color _getBarColor(int index, int total, double value) {
    final ratio = index / total;

    // Use cached HSL values instead of converting every time
    final hueShift = _hueOffsets[index.clamp(0, 47)];
    final newHue = (_cachedBaseHue + hueShift) % 360;

    // Saturation increases with value
    final saturation = (_cachedBaseSaturation * (0.7 + value * 0.3)).clamp(0.0, 1.0);

    // Lightness varies: brighter in bass, slightly dimmer in treble
    final baseLightness = 0.45 + (1 - ratio) * 0.15;
    final lightness = (baseLightness + value * 0.25).clamp(0.0, 0.85);

    return HSLColor.fromAHSL(1.0, newHue, saturation, lightness).toColor();
  }

  /// Get cached gradient shader for a bar
  Shader _getBarGradient(int index, Rect rect, Color color) {
    // Key based on bar index and height bucket (rounded to reduce cache misses)
    final heightBucket = (rect.height / 10).round();
    final key = index * 1000 + heightBucket;

    return _gradientCache.putIfAbsent(key, () {
      return LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          color.withValues(alpha: opacity * 0.9),
          color.withValues(alpha: opacity * 0.6),
        ],
      ).createShader(rect);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final barCount = bars.length;
    final spacing = 2.0;
    final totalSpacing = spacing * (barCount - 1);
    final barWidth = (size.width - totalSpacing) / barCount;

    // Bass-reactive height multiplier - bars grow taller on bass hits
    final bassBoost = 1.0 + bass * 0.4;

    // Draw glow layer first (behind bars) - more intense on bass
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      if (value < 0.03) continue;

      final x = i * (barWidth + spacing);
      final barHeight = value * size.height * 0.9 * bassBoost;
      final color = _getBarColor(i, barCount, value);

      // Glow intensity increases with bass
      final glowIntensity = opacity * (0.3 + bass * 0.3) * value;
      _glowPaint.color = color.withValues(alpha: glowIntensity);

      final glowRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          x - 3,
          size.height - barHeight - 6,
          barWidth + 6,
          barHeight + 12,
        ),
        const Radius.circular(6),
      );
      canvas.drawRRect(glowRect, _glowPaint);
    }

    // Draw bars - use cached gradients to avoid per-frame allocations
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      final x = i * (barWidth + spacing);
      final barHeight = max(3.0, value * size.height * 0.85 * bassBoost);
      final color = _getBarColor(i, barCount, value);

      // Create gradient from bottom to top
      final barRect = Rect.fromLTWH(
        x,
        size.height - barHeight,
        barWidth,
        barHeight,
      );

      // Use cached shader when possible (falls back to fresh shader for color changes)
      _barPaint.shader = _getBarGradient(i, barRect, color);

      final rrect = RRect.fromRectAndRadius(
        barRect,
        Radius.circular(barWidth / 3),
      );
      canvas.drawRRect(rrect, _barPaint);
    }

    // Draw peak indicators
    for (int i = 0; i < barCount && i < peaks.length; i++) {
      final peakValue = peaks[i];
      if (peakValue < 0.05) continue;

      final x = i * (barWidth + spacing);
      final peakY = size.height - (peakValue * size.height * 0.85);
      final color = _getBarColor(i, barCount, peakValue);

      _peakPaint.color = color.withValues(alpha: opacity * 0.9);

      final peakRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, peakY - 3, barWidth, 3),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(peakRect, _peakPaint);
    }

    // Bottom glow on bass hits
    if (bass > 0.3) {
      final glowHeight = size.height * 0.15;
      final bottomRect = Rect.fromLTWH(0, size.height - glowHeight, size.width, glowHeight);

      final gradient = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          primaryColor.withValues(alpha: opacity * bass * 0.5),
          Colors.transparent,
        ],
      );

      _glowPaint.shader = gradient.createShader(bottomRect);
      canvas.drawRect(bottomRect, _glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumBarsPainter old) {
    // Always repaint - spectrum changes every frame
    return true;
  }
}
