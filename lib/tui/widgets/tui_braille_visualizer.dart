import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/audio_player_service.dart';
import '../../services/pulseaudio_fft_service.dart';
import '../tui_theme.dart';

/// CLI-style Braille-dot spectroscope, inspired by `tsirysndr/tunein-cli`.
///
/// Each Braille glyph (U+2800–U+28FF) is a 2×4 dot matrix, so a single line
/// of text gives 2× horizontal and 4× vertical resolution compared to the
/// block-character visualizer. The result reads as a smooth log-frequency
/// spectrum curve rather than a row of discrete bars.
///
/// Data source is shared with [TuiSpectrumVisualizer] — PulseAudio FFT on
/// Linux, falling back to the audio service's frequency bands elsewhere.
class TuiBrailleVisualizer extends StatefulWidget {
  const TuiBrailleVisualizer({
    super.key,
    required this.audioService,
    this.height = 2,
    this.width = 80,
    this.showReferenceLines = true,
  });

  final AudioPlayerService audioService;

  /// Height in terminal rows (each row holds 4 vertical dots of resolution).
  final int height;

  /// Width in terminal columns (each column holds 2 horizontal dots).
  final int width;

  /// When true, draws faint decade reference lines (like tunein-cli's
  /// 100/1k/10k guidelines) in the background so users can gauge what
  /// frequency range is driving the chart.
  final bool showReferenceLines;

  @override
  State<TuiBrailleVisualizer> createState() => _TuiBrailleVisualizerState();
}

class _TuiBrailleVisualizerState extends State<TuiBrailleVisualizer>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  StreamSubscription? _fftSubscription;
  StreamSubscription? _playingSubscription;

  /// Smoothed spectrum, one sample per horizontal dot-column (width * 2).
  late List<double> _spectrum;
  late List<double> _targetSpectrum;

  bool _isPlaying = false;
  DateTime _lastFrame = DateTime.now();

  /// Bit table for Braille dots. `bitFor[col][row]` → bit to OR into the
  /// cell's byte. Columns: 0 (left), 1 (right). Rows: 0 (top) … 3 (bottom).
  /// Matches the Unicode Braille pattern layout exactly.
  static const List<List<int>> _brailleBits = [
    [0x01, 0x02, 0x04, 0x40], // col 0: dots 1, 2, 3, 7
    [0x08, 0x10, 0x20, 0x80], // col 1: dots 4, 5, 6, 8
  ];

  @override
  void initState() {
    super.initState();

    final dotCols = widget.width * 2;
    _spectrum = List<double>.filled(dotCols, 0.0);
    _targetSpectrum = List<double>.filled(dotCols, 0.0);

    _ticker = createTicker(_onTick);

    _initFFTSource();

    _playingSubscription = widget.audioService.playingStream.listen((playing) {
      if (!mounted) return;
      _isPlaying = playing;
      if (playing && !_ticker.isActive) {
        _ticker.start();
      } else if (!playing && _ticker.isActive) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && !_isPlaying && _ticker.isActive) {
            _ticker.stop();
          }
        });
      }
    });

    if (widget.audioService.isPlaying) {
      _isPlaying = true;
      _ticker.start();
    }
  }

  void _initFFTSource() {
    if (Platform.isLinux && PulseAudioFFTService.instance.isAvailable) {
      _fftSubscription = PulseAudioFFTService.instance.fftStream.listen((fft) {
        if (!mounted) return;
        _updateTargetsFromFFT(fft);
      });
    } else {
      _fftSubscription = widget.audioService.frequencyBandsStream.listen((bands) {
        if (!mounted) return;
        _updateTargetsFromBands(bands.bass, bands.mid, bands.treble);
      });
    }
  }

  void _updateTargetsFromFFT(FFTData fft) {
    final spectrum = fft.spectrum;
    if (spectrum.isEmpty) {
      _updateTargetsFromBands(fft.bass, fft.mid, fft.treble);
      return;
    }

    // Map incoming linear-frequency spectrum to a log-frequency display axis,
    // matching the `(i * resolution).ln()` mapping in tunein-cli's
    // spectroscope.rs so the bass range gets the horizontal real estate it
    // deserves on a wide terminal.
    final dotCols = _targetSpectrum.length;
    // Use the lower 40% of the FFT bins — above that is mostly noise / Nyquist.
    final usable = math.max(4, (spectrum.length * 0.4).round());
    final minLog = math.log(1);
    final maxLog = math.log(usable.toDouble());
    final logRange = maxLog - minLog;

    for (int x = 0; x < dotCols; x++) {
      final t = x / (dotCols - 1);
      final binF = math.exp(minLog + t * logRange);
      final i0 = binF.floor().clamp(0, spectrum.length - 1);
      final i1 = (i0 + 1).clamp(0, spectrum.length - 1);
      final frac = (binF - i0).clamp(0.0, 1.0);
      final v0 = spectrum[i0];
      final v1 = spectrum[i1];
      var value = v0 + (v1 - v0) * frac;

      // Frequency-dependent gain so all ranges read on a single axis.
      // Bass is loud naturally, so boost less; treble gets more help.
      final ratio = t;
      final boost = ratio < 0.25
          ? 2.0 + fft.bass * 1.2
          : ratio < 0.6
              ? 2.4 + fft.mid * 1.5
              : 2.8 + fft.treble * 1.8;

      _targetSpectrum[x] = (value * boost).clamp(0.0, 1.0);
    }
  }

  void _updateTargetsFromBands(double bass, double mid, double treble) {
    final dotCols = _targetSpectrum.length;
    // Synth a smooth spectrum-shaped curve from the 3 coarse bands so the
    // Braille chart still animates on platforms without full FFT.
    for (int x = 0; x < dotCols; x++) {
      final ratio = x / (dotCols - 1);
      double value;
      if (ratio < 0.25) {
        // Bass hump peaking around 0.12.
        final hump = 1.0 - ((ratio - 0.12) / 0.15).abs();
        value = bass * hump.clamp(0.0, 1.0);
      } else if (ratio < 0.6) {
        final midRatio = (ratio - 0.25) / 0.35;
        final hump = 1.0 - ((midRatio - 0.5)).abs() * 2;
        value = mid * hump.clamp(0.0, 1.0);
      } else {
        final trebleRatio = (ratio - 0.6) / 0.4;
        value = treble * (1.0 - trebleRatio * 0.5);
      }
      _targetSpectrum[x] = value.clamp(0.0, 1.0);
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    if (now.difference(_lastFrame).inMilliseconds < 33) return; // ~30fps
    _lastFrame = now;

    bool anyActive = false;
    for (int i = 0; i < _spectrum.length; i++) {
      final target = _isPlaying ? _targetSpectrum[i] : 0.0;
      // Fast attack, slow decay — same shape as the block visualizer so
      // swapping styles at runtime doesn't feel jarring.
      if (target > _spectrum[i]) {
        _spectrum[i] += (target - _spectrum[i]) * 0.55;
      } else {
        _spectrum[i] += (target - _spectrum[i]) * 0.12;
      }
      if (_spectrum[i] > 0.01) anyActive = true;
    }

    if (mounted) setState(() {});

    if (!_isPlaying && !anyActive && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fftSubscription?.cancel();
    _playingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cells = _rasterize();
    final rows = <Widget>[];
    for (int r = 0; r < widget.height; r++) {
      final buffer = StringBuffer();
      for (int c = 0; c < widget.width; c++) {
        buffer.writeCharCode(0x2800 + cells[r * widget.width + c]);
      }
      // Gradient: top rows use accent, bottom rows use primary. Mirrors the
      // "cold top, hot bottom" intuition from the block visualizer.
      final rowRatio = widget.height == 1 ? 1.0 : (r / (widget.height - 1));
      final color = Color.lerp(TuiColors.accent, TuiColors.primary, rowRatio)
          ?? TuiColors.primary;
      rows.add(Text(
        buffer.toString(),
        style: TuiTextStyles.normal.copyWith(
          color: color,
          height: 1.0,
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  /// Produce the flat `width * height` byte array of Braille bit patterns
  /// to feed into the text renderer.
  List<int> _rasterize() {
    final cellCount = widget.width * widget.height;
    final cells = List<int>.filled(cellCount, 0);

    final dotH = widget.height * 4;
    final dotW = widget.width * 2;

    // Background: faint reference gridlines at roughly 1 decade intervals in
    // log-frequency space, matching tunein-cli's DarkGray guidelines.
    if (widget.showReferenceLines) {
      // Treat the horizontal axis as log10(f) from 1 to 10000 (4 decades).
      // Put lines at each integer decade boundary.
      const decades = 4;
      for (int d = 1; d < decades; d++) {
        final x = ((d / decades) * (dotW - 1)).round();
        for (int y = 0; y < dotH; y += 2) {
          _setDot(cells, x, y);
        }
      }
      // Midline so the viewer has a visual floor when the chart is quiet.
      final midY = dotH - 1;
      for (int x = 0; x < dotW; x += 4) {
        _setDot(cells, x, midY);
      }
    }

    // Foreground spectrum curve.
    final topY = 0;
    final botY = dotH - 1;
    // Draw a continuous line connecting spectrum[x] values. Using a simple
    // step-and-fill: plot the dot at the calculated Y, and also fill any
    // vertical gap between consecutive points so the curve stays connected.
    int? prevY;
    for (int x = 0; x < dotW; x++) {
      final v = _spectrum[x].clamp(0.0, 1.0);
      // Higher magnitude → dot closer to the top (lower y index).
      final y = ((1.0 - v) * (botY - topY)).round() + topY;
      _setDot(cells, x, y);
      if (prevY != null) {
        final lo = math.min(prevY, y);
        final hi = math.max(prevY, y);
        for (int yy = lo; yy <= hi; yy++) {
          _setDot(cells, x, yy);
        }
      }
      prevY = y;
    }

    return cells;
  }

  void _setDot(List<int> cells, int x, int y) {
    if (x < 0 || y < 0) return;
    if (x >= widget.width * 2 || y >= widget.height * 4) return;
    final cellCol = x >> 1;
    final cellRow = y >> 2;
    final dotCol = x & 1;
    final dotRow = y & 3;
    cells[cellRow * widget.width + cellCol] |= _brailleBits[dotCol][dotRow];
  }
}
