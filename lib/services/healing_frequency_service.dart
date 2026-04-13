import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'wav_builder.dart';

/// Plays a single sustained sine-wave tone at an arbitrary frequency.
/// Tones are synthesized in memory as integer-cycle WAV buffers so they loop
/// seamlessly (head sample == tail sample → no click at the loop boundary).
///
/// Designed for the Healing Frequencies Easter egg. Works 100% offline.
class HealingFrequencyService {
  static const int _sampleRate = 44100;
  static const double _targetDurationSeconds = 2.0;
  static const double _amplitude = 0.5; // leaves headroom before clipping

  AudioPlayer? _player;
  double? _currentHz;
  double _volume = 0.7;

  final Map<double, Uint8List> _byteCache = {};
  final Map<double, String> _fileCache = {};
  String? _tempDir;
  bool _disposed = false;
  bool _initialized = false;

  final StreamController<double?> _currentHzController =
      StreamController<double?>.broadcast();

  Stream<double?> get currentHzStream => _currentHzController.stream;
  double? get currentHz => _currentHz;
  double get volume => _volume;
  bool get isInitialized => _initialized;

  Future<void> init() async {
    if (_initialized || _disposed) return;

    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      _tempDir = p.join(dir.path, 'healing_freq');
      await Directory(_tempDir!).create(recursive: true);
    }

    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(_volume);

    // iOS/macOS: allow mixing so background music keeps playing.
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      final context = AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      );
      await player.setAudioContext(context);
    }

    _player = player;
    _initialized = true;
  }

  /// Synthesize an integer number of full cycles so the buffer loops without a
  /// zero-crossing discontinuity.
  Uint8List _generateLoopWav(double hz) {
    final safeHz = hz.clamp(20.0, 20000.0);
    final cyclesTarget = (safeHz * _targetDurationSeconds).round().clamp(1, 1 << 20);
    final numSamples = (cyclesTarget * _sampleRate / safeHz).round();
    final pcm = Int16List(numSamples);

    final cycleSamples = _sampleRate / safeHz;
    for (var i = 0; i < numSamples; i++) {
      // Parameterize by cycle position to keep floating-point precision tight
      // across long buffers. sin(2π · i / cycleSamples) is mathematically the
      // same as sin(2π · hz · t) but less prone to drift at the tail.
      final sample = sin(2 * pi * i / cycleSamples) * _amplitude;
      pcm[i] = (sample * 32767).round().clamp(-32768, 32767);
    }

    return buildWavPcm16(pcm, sampleRate: _sampleRate);
  }

  Future<Source> _sourceFor(double hz) async {
    final bytes = _byteCache.putIfAbsent(hz, () => _generateLoopWav(hz));

    if (kIsWeb) {
      return BytesSource(bytes, mimeType: 'audio/wav');
    }

    final cached = _fileCache[hz];
    if (cached != null) return DeviceFileSource(cached, mimeType: 'audio/wav');

    final dir = _tempDir;
    if (dir == null) {
      // Fallback if init somehow didn't create a temp dir.
      return BytesSource(bytes, mimeType: 'audio/wav');
    }
    final safeName = hz.toStringAsFixed(2).replaceAll('.', '_');
    final path = p.join(dir, 'freq_$safeName.wav');
    await File(path).writeAsBytes(bytes, flush: true);
    _fileCache[hz] = path;
    return DeviceFileSource(path, mimeType: 'audio/wav');
  }

  Future<void> play(double hz) async {
    if (_disposed) return;
    final player = _player;
    if (player == null) return;

    if (_currentHz == hz) return;

    try {
      await player.stop();
      await player.setVolume(_volume);
      final source = await _sourceFor(hz);
      await player.play(source);
      _currentHz = hz;
      _currentHzController.add(hz);
    } catch (e) {
      debugPrint('HealingFrequencyService: play($hz) failed: $e');
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } catch (e) {
      debugPrint('HealingFrequencyService: stop failed: $e');
    }
    _currentHz = null;
    _currentHzController.add(null);
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    try {
      await _player?.setVolume(_volume);
    } catch (e) {
      debugPrint('HealingFrequencyService: setVolume failed: $e');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (e) {
      debugPrint('HealingFrequencyService: player dispose failed: $e');
    }
    _player = null;
    _byteCache.clear();
    _fileCache.clear();
    await _currentHzController.close();
    if (_tempDir != null) {
      try {
        final dir = Directory(_tempDir!);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('HealingFrequencyService: temp cleanup failed: $e');
      }
    }
  }
}
