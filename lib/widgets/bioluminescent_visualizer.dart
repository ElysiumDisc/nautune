import 'dart:async' show StreamSubscription;
import 'dart:io' show Platform;
import 'dart:math' show pi, sin, cos;
import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';
import '../services/pulseaudio_fft_service.dart';
import '../services/ios_fft_service.dart';

/// Bioluminescent ocean-themed audio visualizer.
/// On Linux: Uses real FFT from PulseAudio system audio loopback.
/// On other platforms: Uses metadata-driven frequency bands (genre/ReplayGain).
class BioluminescentVisualizer extends StatefulWidget {
  const BioluminescentVisualizer({
    super.key,
    required this.audioService,
    this.opacity = 0.6,
  });

  final AudioPlayerService audioService;
  final double opacity;

  @override
  State<BioluminescentVisualizer> createState() => _BioluminescentVisualizerState();
}

class _BioluminescentVisualizerState extends State<BioluminescentVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  // Smoothed values (interpolate towards targets each frame)
  double _smoothBass = 0.0;
  double _smoothMid = 0.0;
  double _smoothTreble = 0.0;
  double _smoothAmplitude = 0.0;

  // Target values from FFT or metadata
  double _targetBass = 0.0;
  double _targetMid = 0.0;
  double _targetTreble = 0.0;
  double _targetAmplitude = 0.0;

  StreamSubscription? _playingSubscription;
  StreamSubscription? _frequencySubscription;
  StreamSubscription? _fftSubscription;

  // Real FFT sources
  bool _usePulseAudioFFT = false;  // Linux
  bool _useIOSFFT = false;         // iOS

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );

    _initFFTSource();

    // Listen to playing state - start/stop animation and FFT capture
    _playingSubscription = widget.audioService.playingStream.listen((playing) {
      if (mounted) {
        if (playing) {
          _animationController.repeat();
          _startFFTCapture();
        } else {
          _animationController.stop();
          _stopFFTCapture();
        }
      }
    });

    // Initial state
    if (widget.audioService.isPlaying) {
      _animationController.repeat();
      _startFFTCapture();
    }
  }

  Future<void> _initFFTSource() async {
    // Try PulseAudio loopback on Linux
    if (Platform.isLinux) {
      final pulseService = PulseAudioFFTService.instance;
      final available = await pulseService.initialize();

      if (available) {
        _usePulseAudioFFT = true;
        debugPrint('🌊 Visualizer: Using PulseAudio real FFT (Linux)');

        // Listen to real FFT data
        _fftSubscription = pulseService.fftStream.listen((fft) {
          _targetBass = fft.bass;
          _targetMid = fft.mid;
          _targetTreble = fft.treble;
          _targetAmplitude = fft.amplitude;
        });

        // Start capture if already playing
        if (widget.audioService.isPlaying) {
          pulseService.startCapture();
        }
        return;
      }
    }

    // Try AVAudioEngine FFT on iOS
    if (Platform.isIOS) {
      final iosService = IOSFFTService.instance;
      final available = await iosService.initialize();

      if (available) {
        _useIOSFFT = true;
        debugPrint('🌊 Visualizer: Using MTAudioProcessingTap real FFT (iOS)');

        // Listen to real FFT data
        _fftSubscription = iosService.fftStream.listen((fft) {
          _targetBass = fft.bass;
          _targetMid = fft.mid;
          _targetTreble = fft.treble;
          _targetAmplitude = fft.amplitude;
        });

        // Start capture if already playing
        if (widget.audioService.isPlaying) {
          iosService.startCapture();
        }
        return;
      }
    }

    // Fallback: metadata-driven frequency bands
    debugPrint('🌊 Visualizer: Using metadata-driven animation (fallback)');
    _frequencySubscription = widget.audioService.frequencyBandsStream.listen((bands) {
      _targetBass = bands.bass;
      _targetMid = bands.mid;
      _targetTreble = bands.treble;
      _targetAmplitude = ((bands.bass + bands.mid + bands.treble) / 3).clamp(0.0, 1.0);
    });
  }

  void _startFFTCapture() {
    if (_usePulseAudioFFT) {
      PulseAudioFFTService.instance.startCapture();
    } else if (_useIOSFFT) {
      IOSFFTService.instance.startCapture();
    }
  }

  void _stopFFTCapture() {
    if (_usePulseAudioFFT) {
      PulseAudioFFTService.instance.stopCapture();
    } else if (_useIOSFFT) {
      IOSFFTService.instance.stopCapture();
    }
  }

  @override
  void dispose() {
    _fftSubscription?.cancel();
    _frequencySubscription?.cancel();
    _playingSubscription?.cancel();
    _stopFFTCapture();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glowColor = Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        // Musical smoothing: FAST attack, SLOW decay
        // When target > current: snap up quickly (attack)
        // When target < current: ease down slowly (decay)
        // Use fast smoothing for real FFT (Linux/iOS), slower for metadata fallback
        final useRealFFT = _usePulseAudioFFT || _useIOSFFT;
        final attackFactor = useRealFFT ? 0.6 : 0.3;  // Fast rise
        final decayFactor = useRealFFT ? 0.12 : 0.08;  // Slow fall

        _smoothBass += (_targetBass - _smoothBass) *
            (_targetBass > _smoothBass ? attackFactor : decayFactor);
        _smoothMid += (_targetMid - _smoothMid) *
            (_targetMid > _smoothMid ? attackFactor : decayFactor);
        _smoothTreble += (_targetTreble - _smoothTreble) *
            (_targetTreble > _smoothTreble ? attackFactor : decayFactor);
        _smoothAmplitude += (_targetAmplitude - _smoothAmplitude) *
            (_targetAmplitude > _smoothAmplitude ? attackFactor : decayFactor);

        return CustomPaint(
          painter: _BioluminescentWavePainter(
            time: _animationController.value * 10,
            bass: _smoothBass,
            mid: _smoothMid,
            treble: _smoothTreble,
            amplitude: _smoothAmplitude,
            glowColor: glowColor,
            opacity: widget.opacity,
          ),
          size: Size.infinite,
        );
      },
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

  _BioluminescentWavePainter({
    required this.time,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
    required this.glowColor,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // DRAMATIC bass response - wave height scales massively with bass
    final baseAmplitude = 0.08 + amplitude * 0.25;
    final bassAmplitude = baseAmplitude + bass * 2.0;  // HUGE bass impact

    // Draw multiple glowing wave layers
    for (int layer = 0; layer < 3; layer++) {
      final layerOpacity = opacity * (1 - layer * 0.15);
      final layerBlur = layer == 0 ? 12.0 : (layer == 1 ? 6.0 : 3.0);

      final paint = Paint()
        ..color = glowColor.withValues(alpha: layerOpacity * 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0 - layer * 0.8
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, layerBlur);

      final path = Path();
      final waveAmplitude = size.height * bassAmplitude * (1 - layer * 0.15);
      final phase = time + layer * 0.5;
      final frequency = 2.5 + layer * 0.3 + bass * 0.5;  // Frequency shifts with bass

      path.moveTo(0, size.height / 2);
      for (double x = 0; x <= size.width; x += 2) {
        final normalizedX = x / size.width;

        // Primary wave - HUGE amplitude from bass
        final y1 = sin(normalizedX * frequency * pi + phase) * waveAmplitude;

        // Secondary harmonic - modulated by mid
        final y2 = sin(normalizedX * frequency * 2.5 * pi + phase * 1.3) *
                   waveAmplitude * 0.35 * (0.2 + mid * 2.0);

        // Sub-bass rumble - low frequency wobble
        final subBass = sin(normalizedX * 1.5 * pi + time * 0.7) *
                        bass * size.height * 0.15;

        // Treble shimmer - high frequency sparkle
        final shimmer = sin(normalizedX * 20 * pi + time * 4) *
                        treble * size.height * 0.08;

        final y = size.height / 2 + y1 + y2 + subBass + shimmer;
        path.lineTo(x, y);
      }
      canvas.drawPath(path, paint);
    }

    // BASS PULSE - expanding rings on bass hits
    if (bass > 0.3) {
      final pulseRadius = size.width * 0.3 * bass;
      final pulsePaint = Paint()
        ..color = glowColor.withValues(alpha: opacity * bass * 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);

      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        pulseRadius,
        pulsePaint,
      );
    }

    // Floating bioluminescent particles - react to ALL frequencies
    final particlePaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    for (int i = 0; i < 15; i++) {
      final particlePhase = i * 0.42;
      final speed = 0.06 + mid * 0.2 + bass * 0.1;

      final px = ((time * speed + particlePhase) % 1.0) * size.width;
      final verticalPhase = time * 0.4 + i * 0.7;

      // Particles bounce MORE with bass
      final py = size.height / 2 +
          sin(verticalPhase) * size.height * 0.4 * bassAmplitude +
          cos(verticalPhase * 2) * bass * size.height * 0.15;

      // Particle size PULSES hard with bass
      final radius = 3.0 + bass * 12.0 + treble * 5.0 + amplitude * 4.0 +
                     sin(time * 3 + i) * 2.0;
      final particleOpacity = (0.5 + sin(time * 2 + i * 0.5) * 0.3 + bass * 0.3) * opacity;

      particlePaint.color = glowColor.withValues(alpha: particleOpacity.clamp(0.0, 1.0));
      canvas.drawCircle(Offset(px, py), radius.clamp(2.0, 20.0), particlePaint);
    }

    // Bottom gradient glow - PULSES with bass
    final glowIntensity = 0.2 + bass * 0.6 + amplitude * 0.3;
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          glowColor.withValues(alpha: opacity * glowIntensity.clamp(0.0, 0.8)),
        ],
      ).createShader(Rect.fromLTWH(0, size.height * 0.4, size.width, size.height * 0.6));

    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.4, size.width, size.height * 0.6),
      gradientPaint,
    );

    // Top edge glow on big bass hits
    if (bass > 0.5) {
      final topGlowPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.transparent,
            glowColor.withValues(alpha: opacity * (bass - 0.5) * 0.8),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.3));

      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height * 0.3),
        topGlowPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BioluminescentWavePainter old) {
    return true; // Always repaint for smooth animation
  }
}
