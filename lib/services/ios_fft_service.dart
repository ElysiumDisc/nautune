import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

/// Real-time FFT analysis on iOS using MTAudioProcessingTap.
/// Creates a shadow AVPlayer that loads the same audio URL with an audio tap
/// to capture real FFT data without affecting the main player.
class IOSFFTService {
  static IOSFFTService? _instance;
  static IOSFFTService get instance => _instance ??= IOSFFTService._();

  IOSFFTService._();

  static const _methodChannel = MethodChannel('com.nautune.audio_fft/methods');
  static const _eventChannel = EventChannel('com.nautune.audio_fft/events');

  StreamSubscription? _eventSubscription;
  bool _isCapturing = false;
  bool _initialized = false;
  String? _currentUrl;

  // FFT output stream
  final _fftController = BehaviorSubject<IOSFFTData>.seeded(IOSFFTData.zero);
  Stream<IOSFFTData> get fftStream => _fftController.stream;
  IOSFFTData get currentFFT => _fftController.value;

  /// Check if iOS FFT is available
  bool get isAvailable => Platform.isIOS;

  /// Initialize the iOS FFT service
  Future<bool> initialize() async {
    if (!Platform.isIOS) {
      debugPrint('🎵 iOS FFT: Not on iOS, skipping');
      return false;
    }

    if (_initialized) return true;

    try {
      final available = await _methodChannel.invokeMethod<bool>('isAvailable');
      if (available == true) {
        // Listen to FFT event stream
        _eventSubscription = _eventChannel
            .receiveBroadcastStream()
            .listen(_handleFFTEvent, onError: _handleError);
        _initialized = true;
        debugPrint('🎵 iOS FFT: Initialized with MTAudioProcessingTap');
        return true;
      }
    } catch (e) {
      debugPrint('🎵 iOS FFT: Init error - $e');
    }
    return false;
  }

  /// Set the audio URL for FFT analysis
  /// This creates a shadow player with audio tap
  Future<void> setAudioUrl(String url) async {
    if (!Platform.isIOS || !_initialized) return;
    if (url == _currentUrl) return;

    _currentUrl = url;

    try {
      await _methodChannel.invokeMethod('setAudioUrl', {'url': url});
      debugPrint('🎵 iOS FFT: Set audio URL');
    } catch (e) {
      debugPrint('🎵 iOS FFT: setAudioUrl error - $e');
    }
  }

  /// Start capturing audio for FFT analysis
  Future<void> startCapture() async {
    if (_isCapturing || !Platform.isIOS || !_initialized) return;

    try {
      await _methodChannel.invokeMethod('startCapture');
      _isCapturing = true;
      debugPrint('🎵 iOS FFT: Capture started');
    } catch (e) {
      debugPrint('🎵 iOS FFT: Start error - $e');
    }
  }

  /// Stop capturing
  Future<void> stopCapture() async {
    if (!_isCapturing) return;

    try {
      await _methodChannel.invokeMethod('stopCapture');
    } catch (e) {
      debugPrint('🎵 iOS FFT: Stop error - $e');
    } finally {
      _isCapturing = false;
      _fftController.add(IOSFFTData.zero);
      debugPrint('🎵 iOS FFT: Capture stopped');
    }
  }

  /// Sync shadow player position with main player
  Future<void> syncPosition(double positionSeconds) async {
    if (!_isCapturing || !Platform.isIOS) return;

    try {
      await _methodChannel.invokeMethod('syncPosition', {'position': positionSeconds});
    } catch (e) {
      // Ignore sync errors - not critical
    }
  }

  void _handleFFTEvent(dynamic event) {
    if (event is Map) {
      final bass = (event['bass'] as num?)?.toDouble() ?? 0.0;
      final mid = (event['mid'] as num?)?.toDouble() ?? 0.0;
      final treble = (event['treble'] as num?)?.toDouble() ?? 0.0;
      final amplitude = (event['amplitude'] as num?)?.toDouble() ?? 0.0;

      _fftController.add(IOSFFTData(
        bass: bass.clamp(0.0, 1.0),
        mid: mid.clamp(0.0, 1.0),
        treble: treble.clamp(0.0, 1.0),
        amplitude: amplitude.clamp(0.0, 1.0),
      ));
    }
  }

  void _handleError(dynamic error) {
    debugPrint('🎵 iOS FFT: Stream error - $error');
  }

  void dispose() {
    stopCapture();
    _eventSubscription?.cancel();
    _fftController.close();
    _currentUrl = null;
    _initialized = false;
    _instance = null;
  }
}

/// FFT analysis result from iOS
class IOSFFTData {
  final double bass;
  final double mid;
  final double treble;
  final double amplitude;

  const IOSFFTData({
    required this.bass,
    required this.mid,
    required this.treble,
    required this.amplitude,
  });

  static const zero = IOSFFTData(
    bass: 0,
    mid: 0,
    treble: 0,
    amplitude: 0,
  );
}
