import 'dart:io' show Platform;
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

  // Bars for the current frame (the shared buffer from getSpectrumBars).
  List<double> _bars = const [];

  @override
  void onFrame(double dt) {
    _bars = getSpectrumBars(_barCount);
    _updatePeaks(_bars);
  }

  @override
  Widget buildVisualizer(BuildContext context) {
    // Before the first frame (e.g. opened while paused) draw the resting state.
    final bars = _bars.isEmpty ? (_bars = getSpectrumBars(_barCount)) : _bars;

    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return CustomPaint(
      painter: _SpectrumMirrorPainter(
        bars: bars,
        peaks: _peakValues,
        primaryColor: primaryColor,
        opacity: widget.opacity,
        bass: smoothBass,
        frame: frame,
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
  final int frame;
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

  // Per-bar colours of the frame being painted (see paint).
  static List<Color> _barColors = const [];


  _SpectrumMirrorPainter({
    required this.bars,
    required this.peaks,
    required this.primaryColor,
    required this.opacity,
    required this.bass,
    required this.frame,
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

  /// Gradient shader for a bar growing up ([up]) or down from the centre
  /// line. Painters are rebuilt every frame and each bar's colour follows
  /// its value, so a per-painter cache never hit.
  Shader _barGradient(Rect rect, Color color, {required bool up}) {
    return LinearGradient(
      begin: up ? Alignment.bottomCenter : Alignment.topCenter,
      end: up ? Alignment.topCenter : Alignment.bottomCenter,
      colors: [
        color.withValues(alpha: opacity * 0.95),
        color.withValues(alpha: opacity * 0.5),
      ],
    ).createShader(rect);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    // The edge glow below leaves a shader on _glowPaint; clear it, or a
    // repaint of this same painter (relayout while paused) drew every bar
    // glow with that gradient.
    _glowPaint.shader = null;

    final barCount = bars.length;
    final spacing = 1.5;
    final totalSpacing = spacing * (barCount - 1);
    final barWidth = (size.width - totalSpacing) / barCount;
    final centerY = size.height / 2;

    // iOS portrait: cap at 80% height to prevent bars from overwhelming the UI
    final effectiveHeight = Platform.isIOS && size.height > size.width
        ? size.height * 0.8
        : size.height;

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
    // Each bar's colour, shared by the glow and bar passes (it was converted
    // from HSL twice per bar per frame).
    if (_barColors.length != barCount) {
      _barColors = List<Color>.filled(barCount, Colors.transparent);
    }
    for (int i = 0; i < barCount; i++) {
      _barColors[i] = _getBarColor(i, barCount, bars[i]);
    }

    final glowBoost = 0.3 + bass * 0.4;
    for (int i = 0; i < barCount; i++) {
      final value = bars[i];
      if (value < 0.03) continue;

      final x = i * (barWidth + spacing);
      final barHeight = value * maxBarHeight;
      final color = _barColors[i];

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
      final color = _barColors[i];

      // Top bar (going up)
      final topRect = Rect.fromLTWH(
        x,
        centerY - barHeight,
        barWidth,
        barHeight,
      );

      _barPaint.shader = _barGradient(topRect, color, up: true);

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

      _barPaint.shader = _barGradient(bottomRect, color, up: false);

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
    // One repaint per visual frame (~30 fps). `bars` and `peaks` are buffers
    // reused (mutated in place) across frames, so comparing their contents
    // against the old painter's always found them equal and froze the bars.
    return old.frame != frame ||
        old.primaryColor != primaryColor ||
        old.opacity != opacity;
  }
}
