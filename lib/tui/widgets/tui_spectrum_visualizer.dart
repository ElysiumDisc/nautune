import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/audio_player_service.dart';
import '../../services/pulseaudio_fft_service.dart';
import '../tui_theme.dart';

/// ASCII spectrum visualizer for the TUI status bar.
/// Renders frequency bars using Unicode block elements: ▁▂▃▄▅▆▇█
class TuiSpectrumVisualizer extends StatefulWidget {
  const TuiSpectrumVisualizer({
    super.key,
    required this.audioService,
    this.barCount = 16,
    this.height = 1,
    this.compact = false,
  });

  final AudioPlayerService audioService;

  /// Number of frequency bars to display.
  final int barCount;

  /// Height in text rows (1 = single row of block chars, 2+ = stacked).
  final int height;

  /// Compact mode shows fewer bars for the status bar.
  final bool compact;

  @override
  State<TuiSpectrumVisualizer> createState() => _TuiSpectrumVisualizerState();
}

class _TuiSpectrumVisualizerState extends State<TuiSpectrumVisualizer>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  StreamSubscription? _fftSubscription;
  StreamSubscription? _playingSubscription;

  // Bar heights (0.0 - 1.0)
  late List<double> _bars;
  late List<double> _targetBars;
  late List<double> _peakBars;
  late List<double> _peakDecay;

  bool _isPlaying = false;
  DateTime _lastFrame = DateTime.now();

  // Block elements for bar rendering (8 levels + space)
  static const _blockChars = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

  @override
  void initState() {
    super.initState();

    final count = widget.compact ? 12 : widget.barCount;
    _bars = List<double>.filled(count, 0.0);
    _targetBars = List<double>.filled(count, 0.0);
    _peakBars = List<double>.filled(count, 0.0);
    _peakDecay = List<double>.filled(count, 0.0);

    _ticker = createTicker(_onTick);

    _initFFTSource();

    _playingSubscription = widget.audioService.playingStream.listen((playing) {
      if (!mounted) return;
      _isPlaying = playing;
      if (playing && !_ticker.isActive) {
        _ticker.start();
      } else if (!playing && _ticker.isActive) {
        // Let bars decay before stopping ticker
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
      // Fallback: use frequency bands from audio service
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

    final barCount = _targetBars.length;
    final usableRange = (spectrum.length * 0.4).round();

    for (int i = 0; i < barCount; i++) {
      final startRatio = i / barCount;
      final endRatio = (i + 1) / barCount;
      final start = (startRatio * usableRange).round().clamp(0, spectrum.length - 1);
      final end = (endRatio * usableRange).round().clamp(start + 1, spectrum.length);

      var sum = 0.0;
      var count = 0;
      for (int j = start; j < end; j++) {
        sum += spectrum[j];
        count++;
      }

      var avg = count > 0 ? sum / count : 0.0;

      // Frequency-dependent boost
      final freqRatio = i / barCount;
      double boost;
      if (freqRatio < 0.2) {
        boost = 3.0 + fft.bass * 2.0;
      } else if (freqRatio < 0.5) {
        boost = 2.5 + fft.mid * 1.5;
      } else {
        boost = 2.0 + fft.treble * 1.0;
      }

      _targetBars[i] = (avg * boost).clamp(0.0, 1.0);
    }
  }

  void _updateTargetsFromBands(double bass, double mid, double treble) {
    final barCount = _targetBars.length;
    final rng = math.Random(42); // Deterministic pseudo-random for consistent variation

    for (int i = 0; i < barCount; i++) {
      final ratio = i / barCount;
      double value;

      if (ratio < 0.25) {
        final variation = 0.7 + 0.3 * (1.0 - (ratio / 0.25 - 0.5).abs() * 2);
        value = bass * variation;
      } else if (ratio < 0.6) {
        final midRatio = (ratio - 0.25) / 0.35;
        final variation = 0.6 + 0.4 * (1.0 - (midRatio - 0.5).abs() * 2);
        value = mid * variation;
      } else {
        final trebleRatio = (ratio - 0.6) / 0.4;
        final variation = 0.5 + 0.5 * (1.0 - trebleRatio * 0.5);
        value = treble * variation;
      }

      // Add slight per-bar variation
      value *= (0.85 + rng.nextDouble() * 0.3);
      _targetBars[i] = value.clamp(0.0, 1.0);
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    if (now.difference(_lastFrame).inMilliseconds < 33) return; // ~30fps
    _lastFrame = now;

    bool anyActive = false;
    for (int i = 0; i < _bars.length; i++) {
      final target = _isPlaying ? _targetBars[i] : 0.0;

      // Fast attack, slow decay
      if (target > _bars[i]) {
        _bars[i] += (target - _bars[i]) * 0.6;
      } else {
        _bars[i] += (target - _bars[i]) * 0.15;
      }

      // Peak tracking with gravity
      if (_bars[i] > _peakBars[i]) {
        _peakBars[i] = _bars[i];
        _peakDecay[i] = 0.0;
      } else {
        _peakDecay[i] += 0.002;
        _peakBars[i] -= _peakDecay[i];
        _peakBars[i] = _peakBars[i].clamp(0.0, 1.0);
      }

      if (_bars[i] > 0.01 || _peakBars[i] > 0.01) anyActive = true;
    }

    if (mounted) setState(() {});

    // Stop ticker when everything has decayed
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
    if (widget.height > 1) {
      return _buildMultiRowSpectrum();
    }
    return _buildSingleRowSpectrum();
  }

  /// Single-row spectrum using block element characters.
  Widget _buildSingleRowSpectrum() {
    final buffer = StringBuffer();

    for (int i = 0; i < _bars.length; i++) {
      final level = (_bars[i] * 8).round().clamp(0, 8);
      buffer.write(_blockChars[level]);
    }

    return Text(
      buffer.toString(),
      style: TuiTextStyles.normal.copyWith(
        color: TuiColors.primary,
        letterSpacing: 1,
      ),
    );
  }

  /// Multi-row spectrum for taller display (e.g., in a dedicated pane).
  Widget _buildMultiRowSpectrum() {
    final rows = <Widget>[];
    final totalLevels = widget.height * 8;

    for (int row = widget.height - 1; row >= 0; row--) {
      final buffer = StringBuffer();
      for (int i = 0; i < _bars.length; i++) {
        final barLevel = (_bars[i] * totalLevels).round();
        final rowBase = row * 8;
        final rowLevel = (barLevel - rowBase).clamp(0, 8);

        // Check if peak indicator falls in this row
        final peakLevel = (_peakBars[i] * totalLevels).round();
        final isPeakRow = peakLevel >= rowBase && peakLevel < rowBase + 8;

        if (isPeakRow && rowLevel < 8 && _peakBars[i] > _bars[i] + 0.05) {
          // Show peak dot
          buffer.write('╸');
        } else {
          buffer.write(_blockChars[rowLevel]);
        }
      }

      final rowRatio = row / widget.height;
      final color = Color.lerp(TuiColors.accent, TuiColors.primary, rowRatio) ?? TuiColors.primary;

      rows.add(Text(
        buffer.toString(),
        style: TuiTextStyles.normal.copyWith(
          color: color,
          letterSpacing: 1,
          height: 1.0,
        ),
      ));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}
