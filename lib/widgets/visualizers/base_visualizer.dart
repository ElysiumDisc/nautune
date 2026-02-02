import 'dart:async' show StreamSubscription;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import '../../services/audio_player_service.dart';
import '../../services/pulseaudio_fft_service.dart';
import '../../services/ios_fft_service.dart';

/// Abstract base class for all audio visualizers.
/// Provides shared FFT subscription logic, animation control, and value smoothing.
abstract class BaseVisualizer extends StatefulWidget {
  const BaseVisualizer({
    super.key,
    required this.audioService,
    this.opacity = 0.6,
  });

  final AudioPlayerService audioService;
  final double opacity;
}

/// Base state class with FFT subscription and smoothing logic.
/// Subclasses must implement [buildVisualizer] to render their specific visualization.
abstract class BaseVisualizerState<T extends BaseVisualizer> extends State<T>
    with SingleTickerProviderStateMixin {
  late AnimationController animationController;

  // Smoothed values (interpolate towards targets each frame)
  double smoothBass = 0.0;
  double smoothMid = 0.0;
  double smoothTreble = 0.0;
  double smoothAmplitude = 0.0;
  List<double> smoothSpectrum = [];

  // Target values from FFT or metadata
  double _targetBass = 0.0;
  double _targetMid = 0.0;
  double _targetTreble = 0.0;
  double _targetAmplitude = 0.0;
  List<double> _targetSpectrum = [];

  // Frame rate throttling for battery savings
  // iOS: 20fps (50ms) - more aggressive throttling for battery
  // Other: 30fps (33ms)
  DateTime _lastFrameTime = DateTime.now();
  static final _frameInterval = Duration(milliseconds: Platform.isIOS ? 50 : 33);

  // Cached values for frame skipping
  double lastPaintedTime = 0;

  StreamSubscription? _playingSubscription;
  StreamSubscription? _frequencySubscription;
  StreamSubscription? _fftSubscription;

  // Real FFT sources - check synchronously from singleton services
  bool get usePulseAudioFFT => Platform.isLinux && PulseAudioFFTService.instance.isAvailable;
  bool get useIOSFFT => Platform.isIOS && IOSFFTService.instance.isAvailable;
  bool get useRealFFT => usePulseAudioFFT || useIOSFFT;

  /// Number of spectrum bars to use (subclasses can override)
  int get spectrumBarCount => 64;

  @override
  void initState() {
    super.initState();
    animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    _initFFTSource();

    // Listen to playing state - start/stop animation only
    _playingSubscription = widget.audioService.playingStream.listen((playing) {
      if (mounted) {
        if (playing) {
          animationController.repeat();
        } else {
          animationController.stop();
        }
      }
    });

    // Initial state
    if (widget.audioService.isPlaying) {
      animationController.repeat();
    }
  }

  void _initFFTSource() {
    // Subscribe to real FFT stream if available
    if (usePulseAudioFFT) {
      _fftSubscription = PulseAudioFFTService.instance.fftStream.listen((fft) {
        _targetBass = fft.bass;
        _targetMid = fft.mid;
        _targetTreble = fft.treble;
        _targetAmplitude = fft.amplitude;
        _targetSpectrum = fft.spectrum;
      });
      return;
    }

    if (useIOSFFT) {
      _fftSubscription = IOSFFTService.instance.fftStream.listen((fft) {
        _targetBass = fft.bass;
        _targetMid = fft.mid;
        _targetTreble = fft.treble;
        _targetAmplitude = fft.amplitude;
        // iOS FFT doesn't provide full spectrum, generate from bands
        _targetSpectrum = _generateFakeSpectrum(fft.bass, fft.mid, fft.treble);
      });
      return;
    }

    // Fallback: metadata-driven frequency bands
    _frequencySubscription = widget.audioService.frequencyBandsStream.listen((bands) {
      _targetBass = bands.bass;
      _targetMid = bands.mid;
      _targetTreble = bands.treble;
      _targetAmplitude = ((bands.bass + bands.mid + bands.treble) / 3).clamp(0.0, 1.0);
      // Generate fake spectrum from bands for fallback
      _targetSpectrum = _generateFakeSpectrum(bands.bass, bands.mid, bands.treble);
    });
  }

  /// Generate a fake spectrum from frequency bands for fallback mode
  List<double> _generateFakeSpectrum(double bass, double mid, double treble) {
    final spectrum = <double>[];
    final count = spectrumBarCount;

    for (int i = 0; i < count; i++) {
      final ratio = i / count;
      double value;

      if (ratio < 0.2) {
        // Bass region
        value = bass * (1.0 - ratio * 2);
      } else if (ratio < 0.6) {
        // Mid region
        final midRatio = (ratio - 0.2) / 0.4;
        value = mid * (0.7 + 0.3 * (1.0 - (midRatio - 0.5).abs() * 2));
      } else {
        // Treble region
        final trebleRatio = (ratio - 0.6) / 0.4;
        value = treble * (1.0 - trebleRatio * 0.5);
      }

      spectrum.add(value.clamp(0.0, 1.0));
    }

    return spectrum;
  }

  @override
  void dispose() {
    _fftSubscription?.cancel();
    _frequencySubscription?.cancel();
    _playingSubscription?.cancel();
    animationController.dispose();
    super.dispose();
  }

  /// Update smoothed values with fast attack, slow decay
  void updateSmoothedValues() {
    final now = DateTime.now();
    if (now.difference(_lastFrameTime) < _frameInterval) return;
    _lastFrameTime = now;

    // Musical smoothing: FAST attack, SLOW decay
    // iOS needs faster decay since FFT values tend to stay elevated
    final attackFactor = useRealFFT ? 0.6 : 0.3;
    final decayFactor = useRealFFT ? (Platform.isIOS ? 0.25 : 0.12) : 0.08;

    smoothBass += (_targetBass - smoothBass) *
        (_targetBass > smoothBass ? attackFactor : decayFactor);
    smoothMid += (_targetMid - smoothMid) *
        (_targetMid > smoothMid ? attackFactor : decayFactor);
    smoothTreble += (_targetTreble - smoothTreble) *
        (_targetTreble > smoothTreble ? attackFactor : decayFactor);
    smoothAmplitude += (_targetAmplitude - smoothAmplitude) *
        (_targetAmplitude > smoothAmplitude ? attackFactor : decayFactor);

    // Smooth spectrum values
    _updateSmoothedSpectrum(attackFactor, decayFactor);

    lastPaintedTime = animationController.value * 10;
  }

  void _updateSmoothedSpectrum(double attackFactor, double decayFactor) {
    if (_targetSpectrum.isEmpty) return;

    // Ensure smoothSpectrum has correct size
    if (smoothSpectrum.length != _targetSpectrum.length) {
      smoothSpectrum = List<double>.filled(_targetSpectrum.length, 0.0);
    }

    for (int i = 0; i < _targetSpectrum.length; i++) {
      final target = _targetSpectrum[i];
      final current = smoothSpectrum[i];
      smoothSpectrum[i] += (target - current) *
          (target > current ? attackFactor : decayFactor);
    }
  }

  /// Get interpolated spectrum values for the specified number of bars
  /// Values are boosted for more dramatic visualization
  List<double> getSpectrumBars(int barCount) {
    if (smoothSpectrum.isEmpty) {
      // Fallback: generate bars from bass/mid/treble when no spectrum available
      return _generateBarsFromBands(barCount);
    }

    final bars = <double>[];
    final spectrumLength = smoothSpectrum.length;

    for (int i = 0; i < barCount; i++) {
      // Map bar index to spectrum range (use first half for better frequency representation)
      final startRatio = i / barCount;
      final endRatio = (i + 1) / barCount;

      // Use first 40% of spectrum (most musical content)
      final usableRange = (spectrumLength * 0.4).round();
      final start = (startRatio * usableRange).round().clamp(0, spectrumLength - 1);
      final end = (endRatio * usableRange).round().clamp(start + 1, spectrumLength);

      // Average the spectrum values in this range
      var sum = 0.0;
      var count = 0;
      for (int j = start; j < end; j++) {
        sum += smoothSpectrum[j];
        count++;
      }

      var avg = count > 0 ? sum / count : 0.0;

      // BOOST: Apply frequency-dependent gain for more dramatic effect
      // Bass frequencies get extra boost, treble gets moderate boost
      final freqRatio = i / barCount;
      double boost;
      if (freqRatio < 0.2) {
        // Bass: massive boost
        boost = 3.0 + smoothBass * 2.0;
      } else if (freqRatio < 0.5) {
        // Mids: good boost
        boost = 2.5 + smoothMid * 1.5;
      } else {
        // Treble: moderate boost
        boost = 2.0 + smoothTreble * 1.0;
      }

      avg = (avg * boost).clamp(0.0, 1.0);
      bars.add(avg);
    }

    return bars;
  }

  /// Generate bars from frequency bands when spectrum is not available
  List<double> _generateBarsFromBands(int barCount) {
    final bars = <double>[];

    for (int i = 0; i < barCount; i++) {
      final ratio = i / barCount;
      double value;

      if (ratio < 0.25) {
        // Bass region - use bass with variation
        final variation = 0.7 + 0.3 * (1.0 - (ratio / 0.25 - 0.5).abs() * 2);
        value = smoothBass * variation * 1.2;
      } else if (ratio < 0.6) {
        // Mid region
        final midRatio = (ratio - 0.25) / 0.35;
        final variation = 0.6 + 0.4 * (1.0 - (midRatio - 0.5).abs() * 2);
        value = smoothMid * variation * 1.1;
      } else {
        // Treble region
        final trebleRatio = (ratio - 0.6) / 0.4;
        final variation = 0.5 + 0.5 * (1.0 - trebleRatio * 0.5);
        value = smoothTreble * variation;
      }

      // Add overall amplitude influence
      value = (value * (0.7 + smoothAmplitude * 0.5)).clamp(0.0, 1.0);
      bars.add(value);
    }

    return bars;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animationController,
      builder: (context, child) {
        updateSmoothedValues();
        return buildVisualizer(context);
      },
    );
  }

  /// Build the specific visualizer widget. Called every frame.
  Widget buildVisualizer(BuildContext context);
}
