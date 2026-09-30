import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart'
    show AudioSession, AudioSessionConfiguration;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'wav_builder.dart';

/// Plays a single sustained sine-wave tone at an arbitrary frequency.
/// Tones are synthesized as integer-cycle WAV buffers (no waveform
/// discontinuity at the loop point). audioplayers loops by seeking back to 0
/// when the item ends, which leaves a short gap on every wrap, so the buffer
/// is long (~30 s) to make that gap rare. Synthesis runs off the UI isolate.
///
/// Designed for the Healing Frequencies Easter egg. Works 100% offline.
class HealingFrequencyService {
  static const int _sampleRate = 44100;
  static const double _targetDurationSeconds = 30.0;
  static const double _amplitude = 0.5; // leaves headroom before clipping

  AudioPlayer? _player;
  double? _currentHz;
  double _volume = 0.7;

  final Map<double, String> _fileCache = {};
  String? _tempDir;
  bool _disposed = false;
  bool _initialized = false;
  Future<void>? _initFuture;
  // Incremented per play/stop; a superseded play() doesn't touch state.
  int _request = 0;

  final StreamController<double?> _currentHzController =
      StreamController<double?>.broadcast();

  Stream<double?> get currentHzStream => _currentHzController.stream;
  double? get currentHz => _currentHz;
  double get volume => _volume;
  bool get isInitialized => _initialized;

  /// Create the player and temp directory. A [dispose] that races this is
  /// honoured (nothing created afterwards is leaked).
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (_disposed) return;
    final dir = await getTemporaryDirectory();
    if (_disposed) return;
    // Per-instance directory so a closing screen's cleanup can't delete the
    // files of a screen that was reopened right away.
    final parent = p.join(dir.path, 'healing_freq');
    final tempDir = p.join(
      parent,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    await _removeStaleEntries(parent, keep: tempDir);
    await Directory(tempDir).create(recursive: true);
    _tempDir = tempDir;
    if (_disposed) return;

    final player = AudioPlayer();
    _player = player;
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(_volume);
    _initialized = true;
  }

  /// Delete what earlier instances left in [parent] (directories of sessions
  /// that ended without dispose, e.g. the app was killed, and loose files
  /// from older builds), except [keep]. Best effort: errors are ignored.
  static Future<void> _removeStaleEntries(String parent, {required String keep}) async {
    try {
      final dir = Directory(parent);
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (p.equals(entity.path, keep)) continue;
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('HealingFrequencyService: stale temp cleanup failed: $e');
    }
  }

  /// iOS: allow mixing so background music keeps playing. Applied on every
  /// play() because stop() hands the shared session back to the music player.
  Future<void> _applyMixingContext(AudioPlayer player) async {
    if (!Platform.isIOS) return;
    final context = AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {AVAudioSessionOptions.mixWithOthers},
      ),
    );
    await player.setAudioContext(context);
  }

  /// `playback + mixWithOthers` on the shared AVAudioSession makes the music
  /// player lose Now Playing / remote-command eligibility; restore the music
  /// configuration when the tone stops.
  Future<void> _restoreMusicSession() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('HealingFrequencyService: failed to restore audio session: $e');
    }
  }

  /// Synthesize an integer number of full cycles so the buffer loops without a
  /// zero-crossing discontinuity.
  static Uint8List _generateLoopWav(double hz) {
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
    final cached = _fileCache[hz];
    if (cached != null) return DeviceFileSource(cached, mimeType: 'audio/wav');

    // ~2.6 MB of PCM: synthesize off the UI isolate (static tear-off, so
    // nothing from `this` is sent).
    final bytes = await compute(_generateLoopWav, hz);

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
    final request = ++_request;
    bool superseded() => _disposed || request != _request;

    try {
      // Build the source first (may take a moment for a new tone) so the
      // previous tone keeps playing until the new one is ready.
      final source = await _sourceFor(hz);
      if (superseded()) return;
      await player.stop();
      await _applyMixingContext(player);
      await player.setVolume(_volume);
      if (superseded()) return;
      await player.play(source);
      if (superseded()) return;
      _currentHz = hz;
      _currentHzController.add(hz);
    } catch (e) {
      if (!superseded()) debugPrint('HealingFrequencyService: play($hz) failed: $e');
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    final player = _player;
    if (player == null) return;
    _request++;
    try {
      await player.stop();
    } catch (e) {
      debugPrint('HealingFrequencyService: stop failed: $e');
    }
    final wasPlaying = _currentHz != null;
    _currentHz = null;
    _currentHzController.add(null);
    if (wasPlaying) await _restoreMusicSession();
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
    _request++;
    try {
      await _initFuture;
    } catch (_) {}
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (e) {
      debugPrint('HealingFrequencyService: player dispose failed: $e');
    }
    _player = null;
    if (_initialized) await _restoreMusicSession();
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
