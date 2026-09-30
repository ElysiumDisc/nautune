import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'wav_builder.dart';

/// Plays a single sustained sine-wave tone at an arbitrary frequency.
/// Tones are synthesized as WAV buffers holding a whole number of cycles
/// (no waveform discontinuity at the loop point) and looped with just_audio's
/// `LoopMode.one`, which queues a second copy of the item for a gapless wrap
/// (audioplayers looped by seeking back to 0, leaving an audible gap).
/// Synthesis runs off the UI isolate.
///
/// Designed for the Healing Frequencies Easter egg. Works 100% offline.
class HealingFrequencyService with WidgetsBindingObserver {
  static const int _sampleRate = 44100;
  static const double _minDurationSeconds = 10.0;
  static const double _maxDurationSeconds = 20.0;
  static const double _amplitude = 0.5; // leaves headroom before clipping

  ja.AudioPlayer? _player;
  double? _currentHz;
  double _volume = 0.7;

  final Map<double, String> _fileCache = {};
  String? _tempDir;
  bool _disposed = false;
  bool _initialized = false;
  Future<void>? _initFuture;
  // Incremented per play/stop; a superseded play() doesn't touch state.
  int _request = 0;

  final List<StreamSubscription<Object?>> _sessionSubs = [];
  // Tone that was playing when an interruption (call, Siri) began.
  double? _interruptedHz;
  Timer? _reapplyTimer;

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

    // Interruptions are handled below (stop or resume the tone and keep the
    // UI in step), not by just_audio's default pause/resume.
    final player = ja.AudioPlayer(handleInterruptions: false);
    _player = player;
    await player.setLoopMode(ja.LoopMode.one);
    await player.setVolume(_volume);
    if (_disposed) return;
    await _listenToAudioSession();
    if (_disposed) return;
    WidgetsBinding.instance.addObserver(this);
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

  Future<void> _listenToAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _sessionSubs.add(session.interruptionEventStream.listen((event) {
        if (_disposed) return;
        if (event.begin) {
          _interruptedHz = _currentHz;
          if (_currentHz != null) unawaited(_player?.pause());
        } else {
          final hz = _interruptedHz;
          _interruptedHz = null;
          if (hz == null || hz != _currentHz) return;
          if (event.type == AudioInterruptionType.pause) {
            // iOS says it's fine to carry on.
            unawaited(_resumeAfterInterruption());
          } else {
            unawaited(stop());
          }
        }
      }));
      // Headphones unplugged: don't carry on out of the speaker.
      _sessionSubs.add(session.becomingNoisyEventStream.listen((_) {
        if (!_disposed && _currentHz != null) unawaited(stop());
      }));
    } catch (e) {
      debugPrint('HealingFrequencyService: audio session unavailable: $e');
    }
  }

  Future<void> _resumeAfterInterruption() async {
    final player = _player;
    if (player == null || _disposed) return;
    try {
      await _applyMixingContext();
      if (_disposed || _currentHz == null) return;
      unawaited(player.play());
    } catch (e) {
      debugPrint('HealingFrequencyService: resume failed: $e');
    }
  }

  /// The app reconfigures the shared session for music whenever it goes to
  /// the background or returns (see main.dart), which drops the mixing
  /// option while a tone plays. Put it back once that has run.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || _currentHz == null) return;
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _reapplyTimer?.cancel();
      _reapplyTimer = Timer(const Duration(milliseconds: 600), () {
        if (!_disposed && _currentHz != null) unawaited(_applyMixingContext());
      });
    }
  }

  /// iOS: allow mixing so audio from other apps keeps playing. Applied on
  /// every play() because stop() hands the shared session back to the music
  /// player.
  Future<void> _applyMixingContext() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
      ));
    } catch (e) {
      debugPrint('HealingFrequencyService: failed to set mixing session: $e');
    }
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

  /// Number of whole cycles to synthesize for [hz]: between 10 and 20 s of
  /// audio, choosing the count whose length lands closest to a whole number
  /// of samples, so the wrap from the last sample to the first continues the
  /// sine without a step.
  static int _loopCycles(double hz) {
    final minCycles = max(1, (hz * _minDurationSeconds).ceil());
    final maxCycles = max(minCycles, (hz * _maxDurationSeconds).floor());
    var best = minCycles;
    var bestError = double.infinity;
    for (var c = minCycles; c <= maxCycles; c++) {
      final samples = c * _sampleRate / hz;
      final error = (samples - samples.round()).abs();
      if (error < bestError) {
        best = c;
        bestError = error;
        if (error < 1e-6) break;
      }
    }
    return best;
  }

  /// Synthesize a loopable buffer: a whole number of cycles (see
  /// [_loopCycles]), starting at phase 0.
  @visibleForTesting
  static Uint8List generateLoopWav(double hz) {
    final safeHz = hz.clamp(20.0, 20000.0);
    final cycles = _loopCycles(safeHz);
    final numSamples = (cycles * _sampleRate / safeHz).round();
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

  static Uint8List _generateLoopWav(double hz) => generateLoopWav(hz);

  Future<String> _fileFor(double hz) async {
    final cached = _fileCache[hz];
    if (cached != null) return cached;

    // ~1-2 MB of PCM: synthesize off the UI isolate (static tear-off, so
    // nothing from `this` is sent).
    final bytes = await compute(_generateLoopWav, hz);

    final dir = _tempDir;
    if (dir == null) throw StateError('Healing tone directory unavailable');
    final safeName = hz.toStringAsFixed(2).replaceAll('.', '_');
    final path = p.join(dir, 'freq_$safeName.wav');
    await File(path).writeAsBytes(bytes, flush: true);
    _fileCache[hz] = path;
    return path;
  }

  Future<void> play(double hz) async {
    if (_disposed) return;
    final player = _player;
    if (player == null) return;

    if (_currentHz == hz) return;
    final request = ++_request;
    bool superseded() => _disposed || request != _request;

    try {
      // Build the file first (may take a moment for a new tone) so the
      // previous tone keeps playing until the new one is ready.
      final path = await _fileFor(hz);
      if (superseded()) return;
      await player.stop();
      await _applyMixingContext();
      await player.setVolume(_volume);
      if (superseded()) return;
      await player.setFilePath(path);
      if (superseded()) return;
      // play() completes only when playback stops; don't wait for it.
      unawaited(player.play().catchError((Object e) {
        debugPrint('HealingFrequencyService: play($hz) failed: $e');
      }));
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
    _interruptedHz = null;
    _reapplyTimer?.cancel();
    try {
      await player.stop();
    } catch (e) {
      debugPrint('HealingFrequencyService: stop failed: $e');
    }
    if (_disposed) return;
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
    _reapplyTimer?.cancel();
    try {
      await _initFuture;
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _sessionSubs) {
      await sub.cancel();
    }
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
