import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

/// FFT implementation (Cooley-Tukey radix-2)
List<double> _performFFT(List<double> samples) {
  var n = 512;
  while (n < samples.length && n < 2048) {
    n *= 2;
  }

  final real = List<double>.filled(n, 0);
  final imag = List<double>.filled(n, 0);

  final len = math.min(samples.length, n);
  for (var i = 0; i < len; i++) {
    final window = 0.5 * (1 - math.cos(2 * math.pi * i / (len - 1)));
    real[i] = samples[i] * window;
  }

  var j = 0;
  for (var i = 0; i < n - 1; i++) {
    if (i < j) {
      final tempR = real[i];
      real[i] = real[j];
      real[j] = tempR;
    }
    var k = n >> 1;
    while (k <= j) {
      j -= k;
      k >>= 1;
    }
    j += k;
  }

  var mmax = 1;
  while (n > mmax) {
    final step = mmax << 1;
    final theta = -math.pi / mmax;
    final wpr = math.cos(theta);
    final wpi = math.sin(theta);

    var wr = 1.0;
    var wi = 0.0;

    for (var m = 0; m < mmax; m++) {
      for (var i = m; i < n; i += step) {
        final jj = i + mmax;
        final tempR = wr * real[jj] - wi * imag[jj];
        final tempI = wr * imag[jj] + wi * real[jj];
        real[jj] = real[i] - tempR;
        imag[jj] = imag[i] - tempI;
        real[i] += tempR;
        imag[i] += tempI;
      }
      final tempWr = wr;
      wr = wr * wpr - wi * wpi;
      wi = wi * wpr + tempWr * wpi;
    }
    mmax = step;
  }

  final magnitudes = <double>[];
  final halfN = n ~/ 2;
  for (var i = 0; i < halfN; i++) {
    final mag = math.sqrt(real[i] * real[i] + imag[i] * imag[i]) / halfN;
    magnitudes.add(mag);
  }

  return magnitudes;
}

/// Compute RMS average for a range of frequency bins
double _averageRange(List<double> data, int start, int end) {
  if (data.isEmpty || start >= end) return 0.0;
  final s = start.clamp(0, data.length);
  final e = end.clamp(s, data.length);
  if (s >= e) return 0.0;
  final slice = data.sublist(s, e);
  if (slice.isEmpty) return 0.0;

  var sumSq = 0.0;
  for (final v in slice) {
    sumSq += v * v;
  }
  return math.sqrt(sumSq / slice.length);
}

/// Intermediate result from isolate FFT processing
/// Real-time FFT analysis via PulseAudio loopback on Linux.
/// Uses `parec` to capture system audio output (not microphone) for visualization.
class PulseAudioFFTService {
  static PulseAudioFFTService? _instance;
  static PulseAudioFFTService get instance => _instance ??= PulseAudioFFTService._();

  PulseAudioFFTService._();

  Process? _parecProcess;
  StreamSubscription? _audioSubscription;
  bool _isCapturing = false;
  String? _monitorSource;

  // FFT output stream
  final _fftController = BehaviorSubject<FFTData>.seeded(FFTData.zero);
  Stream<FFTData> get fftStream => _fftController.stream;
  FFTData get currentFFT => _fftController.value;

  // High-pass filter state
  double _lastX = 0;
  double _lastY = 0;
  double _peakHistory = 0.1;

  // Buffer for accumulating audio data
  final List<int> _audioBuffer = [];
  static const int _bufferSize = 2048; // Process every ~23ms at 44100Hz mono 16-bit (faster updates)

  /// Check if PulseAudio loopback is available (Linux only)
  bool get isAvailable => Platform.isLinux;

  /// Initialize and find the PulseAudio monitor source
  Future<bool> initialize() async {
    if (!Platform.isLinux) {
      debugPrint('🔊 PulseAudio FFT: Not on Linux, skipping');
      return false;
    }

    try {
      // Check if parec is available
      final whichResult = await Process.run('which', ['parec']);
      if (whichResult.exitCode != 0) {
        debugPrint('🔊 PulseAudio FFT: parec not found');
        return false;
      }

      // Get the default sink name first
      String? defaultSink;
      final infoResult = await Process.run('pactl', ['get-default-sink']);
      if (infoResult.exitCode == 0) {
        defaultSink = (infoResult.stdout as String).trim();
        debugPrint('🔊 PulseAudio FFT: Default sink: $defaultSink');
      }

      // Find monitor source using pactl
      final result = await Process.run('pactl', ['list', 'sources', 'short']);
      if (result.exitCode != 0) {
        debugPrint('🔊 PulseAudio FFT: pactl failed');
        return false;
      }

      final output = result.stdout as String;
      final lines = output.split('\n');

      // First pass: try to find monitor matching default sink
      if (defaultSink != null && defaultSink.isNotEmpty) {
        final expectedMonitor = '$defaultSink.monitor';
        for (final line in lines) {
          if (line.contains(expectedMonitor)) {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              _monitorSource = parts[1];
              debugPrint('🔊 PulseAudio FFT: Found default sink monitor: $_monitorSource');
              return true;
            }
          }
        }
      }

      // Fallback: use any monitor source
      for (final line in lines) {
        if (line.contains('.monitor')) {
          // Format: "56  alsa_output.xxx.monitor  PipeWire  s32le 2ch 48000Hz  IDLE"
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            _monitorSource = parts[1];
            debugPrint('🔊 PulseAudio FFT: Found fallback monitor source: $_monitorSource');
            return true;
          }
        }
      }

      debugPrint('🔊 PulseAudio FFT: No monitor source found');
      return false;
    } catch (e) {
      debugPrint('🔊 PulseAudio FFT: Init error: $e');
      return false;
    }
  }

  /// Start capturing system audio for FFT analysis using parec
  Future<void> startCapture() async {
    if (_isCapturing || _monitorSource == null) return;

    try {
      // Start parec process to capture from monitor source
      // Format: signed 16-bit little-endian, mono, 44100 Hz
      // Low latency for responsive visualization
      _parecProcess = await Process.start('parec', [
        '--device=$_monitorSource',
        '--format=s16le',
        '--channels=1',
        '--rate=44100',
        '--latency-msec=20',  // Lower latency for snappier response
      ]);

      _audioBuffer.clear();

      // Listen to stdout (raw PCM data)
      _audioSubscription = _parecProcess!.stdout.listen((data) {
        _audioBuffer.addAll(data);

        // Process when we have enough data
        while (_audioBuffer.length >= _bufferSize) {
          final chunk = _audioBuffer.sublist(0, _bufferSize);
          _audioBuffer.removeRange(0, _bufferSize);
          _processAudioData(Uint8List.fromList(chunk));
        }
      });

      // Log any errors
      _parecProcess!.stderr.listen((data) {
        final error = String.fromCharCodes(data).trim();
        if (error.isNotEmpty) {
          debugPrint('🔊 PulseAudio FFT stderr: $error');
        }
      });

      _isCapturing = true;
      debugPrint('🔊 PulseAudio FFT: Capture started via parec from $_monitorSource');
    } catch (e) {
      debugPrint('🔊 PulseAudio FFT: Start failed: $e');
      _isCapturing = false;
    }
  }

  /// Stop capturing
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    try {
      await _audioSubscription?.cancel();
      _parecProcess?.kill();
      await _parecProcess?.exitCode.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          _parecProcess?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (e) {
      debugPrint('🔊 PulseAudio FFT: Stop error: $e');
    } finally {
      _audioSubscription = null;
      _parecProcess = null;
      _isCapturing = false;
      _audioBuffer.clear();
      _fftController.add(FFTData.zero);
      debugPrint('🔊 PulseAudio FFT: Capture stopped');
    }
  }

  /// Process raw PCM audio data through FFT
  void _processAudioData(Uint8List rawBytes) {
    if (rawBytes.isEmpty) return;

    try {
      // Convert to normalized doubles (16-bit signed LE)
      final byteData = ByteData.sublistView(rawBytes);
      final samples = <double>[];

      for (var i = 0; i < byteData.lengthInBytes - 1; i += 2) {
        final sample = byteData.getInt16(i, Endian.little);
        samples.add(sample / 32768.0);
      }

      if (samples.isEmpty) return;

      // DC offset removal
      var sum = 0.0;
      for (final s in samples) {
        sum += s;
      }
      final mean = sum / samples.length;

      // High-pass filter + find peak
      final filtered = <double>[];
      var localPeak = 0.001;

      for (final raw in samples) {
        final x = raw - mean;
        final y = 0.98 * (_lastY + x - _lastX);
        _lastX = x;
        _lastY = y;
        filtered.add(y);
        localPeak = math.max(localPeak, y.abs());
      }

      // Smooth peak for AGC
      _peakHistory = _peakHistory * 0.92 + localPeak * 0.08;

      // Noise gate + gain
      const noiseThreshold = 0.008;
      const maxGain = 20.0;

      var gain = 0.4 / math.max(0.001, _peakHistory);
      gain = gain.clamp(1.0, maxGain);

      if (_peakHistory < noiseThreshold) {
        final gateFactor = math.pow(_peakHistory / noiseThreshold, 2);
        gain *= gateFactor;
      }

      // Apply gain and compute RMS
      final processed = <double>[];
      var sumSquares = 0.0;

      for (final s in filtered) {
        final scaled = (s * gain).clamp(-1.0, 1.0);
        processed.add(scaled);
        sumSquares += scaled * scaled;
      }

      final amplitude = math.sqrt(sumSquares / processed.length);

      // Perform FFT
      final spectrum = _performFFT(processed);

      // Extract frequency bands
      if (spectrum.isNotEmpty) {
        final len = spectrum.length;
        // Better frequency band splits for 44100Hz sample rate
        final bassEnd = (len * 0.04).round().clamp(1, len);    // ~0-180Hz (sub-bass + bass)
        final midEnd = (len * 0.20).round().clamp(bassEnd, len);  // ~180-2000Hz (mids)
        // Treble is 2000Hz+ (rest of spectrum)

        // AGGRESSIVE boosting for dramatic visualization
        final rawBass = _averageRange(spectrum, 0, bassEnd);
        final rawMid = _averageRange(spectrum, bassEnd, midEnd);
        final rawTreble = _averageRange(spectrum, midEnd, len);

        final bass = rawBass * 30.0;
        final mid = rawMid * 40.0;
        final treble = rawTreble * 80.0;  // Treble needs MASSIVE boost

        _fftController.add(FFTData(
          bass: bass.clamp(0.0, 1.0),
          mid: mid.clamp(0.0, 1.0),
          treble: treble.clamp(0.0, 1.0),
          amplitude: (amplitude * 2.0).clamp(0.0, 1.0),
          spectrum: spectrum,
        ));
      }
    } catch (e) {
      // Silent fail - don't spam logs
    }
  }

  void dispose() {
    stopCapture();
    _fftController.close();
    _instance = null;
  }
}

/// FFT analysis result with frequency bands
class FFTData {
  final double bass;
  final double mid;
  final double treble;
  final double amplitude;
  final List<double> spectrum;

  const FFTData({
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
    this.spectrum = const [],
  });

  static const zero = FFTData(
    bass: 0,
    mid: 0,
    treble: 0,
    amplitude: 0,
  );
}
