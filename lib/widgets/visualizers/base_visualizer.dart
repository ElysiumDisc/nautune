import 'dart:async' show StreamSubscription;
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import '../../services/audio_player_service.dart';
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
  late final Ticker _ticker;

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

  // Visual frames are produced at ~30 fps whatever the display rate (60 or
  // 120 Hz): the ticker fires every vsync, but only every ~33 ms does it
  // advance the state and rebuild.
  static const _frameInterval = Duration(milliseconds: 32);
  Duration _lastFrameAt = Duration.zero;
  bool _tickerRestarted = true;

  /// Animation time in seconds. Monotonic: it advances only while playing
  /// and on screen, and never wraps (a wrap made the waves and the radial
  /// rotation jump).
  double lastPaintedTime = 0;

  /// Seconds covered by the latest visual frame (clamped), for simulations
  /// such as peak decay, trails and preset timers.
  double frameDelta = 0;

  /// Bumped once per visual frame. Painters repaint when it changes.
  int frame = 0;
  final ValueNotifier<int> _frameNotifier = ValueNotifier<int>(0);

  StreamSubscription? _playingSubscription;
  StreamSubscription? _frequencySubscription;
  StreamSubscription? _fftSubscription;

  // Whether this visualizer holds a retainVisualizer() on the service. Held
  // only while on screen (TickerMode enabled): an offstage route (covered by
  // an opaque page) or a caller that disables TickerMode (the mini player
  // under the full player) releases the iOS FFT shadow player.
  bool _retained = false;

  // Last real FFT event. The metadata-driven bands stand in whenever FFT is
  // silent (streaming on cellular / Low Power Mode, before a local copy
  // exists), instead of leaving the visualizer flat.
  DateTime? _lastFftAt;
  static const _fftStaleAfter = Duration(milliseconds: 600);

  // Reusable spectrum buffer. Filled in-place each frame to avoid allocating
  // a new List<double> at 30-60 Hz (pre-iOS this was the hottest GC source
  // in the visualizer pipeline).
  List<double>? _fakeSpectrumBuffer;
  List<double>? _spectrumBarsBuffer;

  // Real FFT sources - check synchronously from singleton services
  bool get useIOSFFT => Platform.isIOS && IOSFFTService.instance.isAvailable;
  bool get useRealFFT => useIOSFFT;

  /// Number of spectrum bars to use (subclasses can override)
  int get spectrumBarCount => 64;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _subscribeToService();
    _setPlaying(widget.audioService.isPlaying);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateRetained(TickerMode.valuesOf(context).enabled);
  }

  void _updateRetained(bool onScreen) {
    if (onScreen == _retained) return;
    _retained = onScreen;
    if (onScreen) {
      widget.audioService.retainVisualizer();
    } else {
      widget.audioService.releaseVisualizer();
    }
  }

  void _subscribeToService() {
    // Start/stop the frame ticker with playback.
    _playingSubscription = widget.audioService.playingStream.listen((playing) {
      if (mounted) _setPlaying(playing);
    });
    _initFFTSource();
  }

  void _unsubscribeFromService() {
    _fftSubscription?.cancel();
    _fftSubscription = null;
    _frequencySubscription?.cancel();
    _frequencySubscription = null;
    _playingSubscription?.cancel();
    _playingSubscription = null;
  }

  void _setPlaying(bool playing) {
    if (playing && !_ticker.isActive) {
      _tickerRestarted = true;
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    double dt;
    if (_tickerRestarted) {
      _tickerRestarted = false;
      dt = _frameInterval.inMicroseconds / 1e6;
    } else {
      final since = elapsed - _lastFrameAt;
      if (since < _frameInterval) return;
      dt = since.inMicroseconds / 1e6;
    }
    _lastFrameAt = elapsed;
    // A muted ticker (offstage) keeps counting; don't jump ahead on return.
    frameDelta = dt > 0.1 ? 0.1 : dt;
    lastPaintedTime += frameDelta;
    updateSmoothedValues();
    onFrame(frameDelta);
    frame++;
    _frameNotifier.value = frame;
  }

  /// Advances per-frame state (peaks, trails, preset timers). Called once
  /// per visual frame, after the smoothed values were updated; never from
  /// build, which can also run when a parent rebuilds.
  void onFrame(double dt) {}

  void _initFFTSource() {
    // Subscribe to real FFT stream if available
    if (useIOSFFT) {
      _fftSubscription = IOSFFTService.instance.fftStream.listen((fft) {
        _lastFftAt = DateTime.now();
        // iOS FFT values tend to run hot, scale down for visual parity
        const iosScale = 0.65;
        _targetBass = fft.bass * iosScale;
        _targetMid = fft.mid * iosScale;
        _targetTreble = fft.treble * iosScale;
        _targetAmplitude = fft.amplitude * iosScale;
        // iOS FFT doesn't provide full spectrum, generate from bands
        _targetSpectrum = _generateFakeSpectrum(_targetBass, _targetMid, _targetTreble);
      });
    }

    // Metadata-driven frequency bands: the only source off iOS, and the
    // fallback on iOS while FFT isn't delivering.
    _frequencySubscription = widget.audioService.frequencyBandsStream.listen((bands) {
      final lastFft = _lastFftAt;
      if (lastFft != null && DateTime.now().difference(lastFft) < _fftStaleAfter) {
        return;
      }
      _targetBass = bands.bass;
      _targetMid = bands.mid;
      _targetTreble = bands.treble;
      _targetAmplitude = ((bands.bass + bands.mid + bands.treble) / 3).clamp(0.0, 1.0);
      // Generate fake spectrum from bands for fallback
      _targetSpectrum = _generateFakeSpectrum(bands.bass, bands.mid, bands.treble);
    });
  }

  /// Generate a fake spectrum from frequency bands for fallback mode.
  /// Writes into a reusable buffer sized to [spectrumBarCount] so repeated
  /// 30-60 Hz calls don't churn the garbage collector.
  List<double> _generateFakeSpectrum(double bass, double mid, double treble) {
    final count = spectrumBarCount;
    final buffer = (_fakeSpectrumBuffer == null ||
            _fakeSpectrumBuffer!.length != count)
        ? (_fakeSpectrumBuffer = List<double>.filled(count, 0.0))
        : _fakeSpectrumBuffer!;

    for (int i = 0; i < count; i++) {
      final ratio = i / count;
      double value;

      if (ratio < 0.2) {
        value = bass * (1.0 - ratio * 2);
      } else if (ratio < 0.6) {
        final midRatio = (ratio - 0.2) / 0.4;
        value = mid * (0.7 + 0.3 * (1.0 - (midRatio - 0.5).abs() * 2));
      } else {
        final trebleRatio = (ratio - 0.6) / 0.4;
        value = treble * (1.0 - trebleRatio * 0.5);
      }

      buffer[i] = value.clamp(0.0, 1.0);
    }

    return buffer;
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _unsubscribeFromService();
      if (_retained) {
        widget.audioService.retainVisualizer();
        oldWidget.audioService.releaseVisualizer();
      }
      _subscribeToService();
      _setPlaying(widget.audioService.isPlaying);
    }
  }

  @override
  void dispose() {
    if (_retained) {
      _retained = false;
      widget.audioService.releaseVisualizer();
    }
    _unsubscribeFromService();
    _ticker.dispose();
    _frameNotifier.dispose();
    super.dispose();
  }

  /// Update smoothed values with fast attack, slow decay
  void updateSmoothedValues() {
    // Musical smoothing: FAST attack, SLOW decay
    // iOS needs slower attack (values come in hot) and faster decay (they stay elevated)
    final attackFactor = Platform.isIOS ? 0.4 : (useRealFFT ? 0.6 : 0.3);
    final decayFactor = Platform.isIOS ? 0.35 : (useRealFFT ? 0.12 : 0.08);

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

    final bars = (_spectrumBarsBuffer == null ||
            _spectrumBarsBuffer!.length != barCount)
        ? (_spectrumBarsBuffer = List<double>.filled(barCount, 0.0))
        : _spectrumBarsBuffer!;
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
      bars[i] = avg;
    }

    return bars;
  }

  /// Generate bars from frequency bands when spectrum is not available
  List<double> _generateBarsFromBands(int barCount) {
    final bars = (_spectrumBarsBuffer == null ||
            _spectrumBarsBuffer!.length != barCount)
        ? (_spectrumBarsBuffer = List<double>.filled(barCount, 0.0))
        : _spectrumBarsBuffer!;

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
      bars[i] = value;
    }

    return bars;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds once per visual frame (~30 fps), not on every vsync.
    return ValueListenableBuilder<int>(
      valueListenable: _frameNotifier,
      builder: (context, value, child) => buildVisualizer(context),
    );
  }

  /// Build the specific visualizer widget. Called once per visual frame
  /// (and when a parent rebuilds); pass [frame] to the painter and repaint
  /// when it changes.
  Widget buildVisualizer(BuildContext context);
}
