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

/// Programmatic piano synthesizer using additive synthesis + ADSR envelope.
/// Generates WAV audio in-memory (no asset files needed).
///
/// Each key of the visible range gets [_voicesPerKey] [AudioPlayer]s with the
/// note's source already loaded, so a key press is a single `resume` instead
/// of loading a new player item. Presses alternate between the voices: a
/// quick repeat starts a fresh voice while the previous one rings out,
/// instead of cutting it off mid-waveform (an audible click).
class PianoSynthService {
  static const int _sampleRate = 44100;
  static const int _channels = 1;
  static const double _noteDuration = 0.8; // seconds
  static const int _voicesPerKey = 2;

  // ADSR envelope parameters (in seconds)
  static const double _attack = 0.005;
  static const double _decay = 0.1;
  static const double _sustainLevel = 0.6;
  static const double _release = 0.2;

  /// Players for the keys of the current range ([_voicesPerKey] per key,
  /// reused when the octave changes).
  final List<AudioPlayer> _players = [];
  final Map<int, List<AudioPlayer>> _notePlayers = {};

  /// Next voice to use per MIDI note.
  final Map<int, int> _nextVoice = {};

  // Cache generated WAV bytes per MIDI note, and their temp files.
  final Map<int, Uint8List> _noteCache = {};
  String? _tempDir;
  final Map<int, String> _fileCache = {};

  Future<void>? _initFuture;
  int _preloadGeneration = 0;
  bool _disposed = false;

  /// Initialize the temp directory and iOS audio context. Safe to call once;
  /// a [dispose] that races it is honoured.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    final dir = await getTemporaryDirectory();
    if (_disposed) return;
    // Per-instance directory: a closing screen's cleanup can't delete the
    // files of a piano that was reopened right away.
    final parent = p.join(dir.path, 'piano_synth');
    final tempDir = p.join(
      parent,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    await _removeStaleEntries(parent, keep: tempDir);
    await Directory(tempDir).create(recursive: true);
    _tempDir = tempDir;
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
      debugPrint('PianoSynthService: stale temp cleanup failed: $e');
    }
  }

  /// On iOS the audio context is global. Use playback + mixWithOthers so the
  /// piano doesn't interrupt other apps' audio.
  Future<void> _applyAudioContext(AudioPlayer player) async {
    if (!Platform.isIOS) return;
    await player.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      ),
    );
  }

  /// Our players switched the shared iOS AVAudioSession to
  /// `playback + mixWithOthers`, which makes the music player lose Now
  /// Playing / remote-command eligibility. Put the music configuration back.
  Future<void> _restoreMusicSession() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('PianoSynthService: failed to restore audio session: $e');
    }
  }

  /// Play a note by MIDI number (e.g., 60 = C4). Notes outside the loaded
  /// range are ignored until [preloadRange] covers them.
  Future<void> playNote(int midiNote) async {
    if (_disposed) return;
    final voices = _notePlayers[midiNote];
    if (voices == null || voices.isEmpty) return;
    final index = (_nextVoice[midiNote] ?? 0) % voices.length;
    _nextVoice[midiNote] = index + 1;
    final player = voices[index];

    try {
      if (player.state == PlayerState.playing) {
        // This voice is still ringing (both voices busy): restart it. Always
        // resume after the seek: if the native player's own completion raced
        // an earlier press, it may consider itself stopped (the seek then
        // pauses it and no completion is ever reported), and the resume
        // recovers it instead of leaving the key silent.
        await player.seek(Duration.zero);
      }
      await player.resume();
    } catch (e) {
      debugPrint('PianoSynthService: Error playing note $midiNote: $e');
    }
  }

  /// Synthesize (off the UI isolate), write and load [count] notes starting
  /// at [startMidi], [_voicesPerKey] players per key. Keys already loaded
  /// keep their players; only players of keys that left the range are
  /// reloaded. A newer call supersedes an older one still in progress.
  Future<void> preloadRange(int startMidi, int count) async {
    try {
      await _preloadRange(startMidi, count);
    } catch (e) {
      // Expected if the screen closed mid-load (players disposed).
      if (!_disposed) debugPrint('PianoSynthService: preload failed: $e');
    }
  }

  Future<void> _preloadRange(int startMidi, int count) async {
    await init();
    final generation = ++_preloadGeneration;
    bool superseded() => _disposed || generation != _preloadGeneration;
    if (superseded()) return;
    final tempDir = _tempDir;
    if (tempDir == null) return;

    final notes = [for (var i = 0; i < count; i++) startMidi + i];
    final missing = notes.where((n) => !_noteCache.containsKey(n)).toList();
    if (missing.isNotEmpty) {
      // Static tear-off (no closure) so nothing from `this` is sent.
      final generated = await compute(_generateNotes, missing);
      for (var i = 0; i < missing.length; i++) {
        _noteCache[missing[i]] = generated[i];
      }
      if (superseded()) return;
    }

    // Keys that left the range give up their players; players a superseded
    // call loaded but never assigned are free too.
    final wanted = notes.toSet();
    _notePlayers.removeWhere((note, _) => !wanted.contains(note));
    final assigned = {for (final voices in _notePlayers.values) ...voices};
    final free = [for (final player in _players) if (!assigned.contains(player)) player];

    for (final note in notes) {
      if (_notePlayers[note]?.length == _voicesPerKey) continue;

      var path = _fileCache[note];
      if (path == null) {
        path = p.join(tempDir, 'note_$note.wav');
        await File(path).writeAsBytes(_noteCache[note]!);
        _fileCache[note] = path;
        if (superseded()) return;
      }

      final voices = <AudioPlayer>[];
      for (var v = 0; v < _voicesPerKey; v++) {
        final AudioPlayer player;
        if (free.isNotEmpty) {
          player = free.removeLast();
        } else {
          player = AudioPlayer();
          _players.add(player);
          await player.setReleaseMode(ReleaseMode.stop);
          if (_players.length == 1) await _applyAudioContext(player);
          if (_disposed) return;
        }
        await player.setSource(DeviceFileSource(path, mimeType: 'audio/wav'));
        if (superseded()) return;
        voices.add(player);
      }
      _notePlayers[note] = voices;
    }
  }

  static List<Uint8List> _generateNotes(List<int> notes) =>
      [for (final n in notes) generateNoteWav(n)];

  /// Convert MIDI note number to frequency in Hz.
  /// A4 (MIDI 69) = 440 Hz.
  static double midiToFrequency(int midiNote) {
    return 440.0 * pow(2.0, (midiNote - 69) / 12.0);
  }

  /// Generate a complete WAV file as Uint8List for a single note.
  @visibleForTesting
  static Uint8List generateNoteWav(int midiNote) {
    final frequency = midiToFrequency(midiNote);
    final numSamples = (_sampleRate * _noteDuration).toInt();
    final pcmData = Int16List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / _sampleRate;

      // Additive synthesis: fundamental + harmonics
      double sample = 0.0;
      sample += sin(2 * pi * frequency * t); // fundamental
      sample += 0.5 * sin(2 * pi * frequency * 2 * t); // 2nd harmonic
      sample += 0.25 * sin(2 * pi * frequency * 3 * t); // 3rd harmonic

      // ADSR envelope
      sample *= _envelope(t);

      // Normalize and convert to 16-bit (peak 1.75 * 0.4 = 0.7: no clipping)
      pcmData[i] = (sample * 0.4 * 32767).round().clamp(-32768, 32767);
    }

    return buildWavPcm16(pcmData, sampleRate: _sampleRate, channels: _channels);
  }

  /// ADSR envelope function.
  static double _envelope(double t) {
    if (t < _attack) {
      return t / _attack;
    } else if (t < _attack + _decay) {
      final decayProgress = (t - _attack) / _decay;
      return 1.0 - decayProgress * (1.0 - _sustainLevel);
    } else if (t < _noteDuration - _release) {
      return _sustainLevel;
    } else {
      final releaseProgress = (t - (_noteDuration - _release)) / _release;
      return _sustainLevel * (1.0 - releaseProgress).clamp(0.0, 1.0);
    }
  }

  /// Release all resources. Waits for an in-flight [init] so nothing it
  /// creates afterwards is leaked.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _preloadGeneration++;
    try {
      await _initFuture;
    } catch (_) {}

    final players = List<AudioPlayer>.of(_players);
    _players.clear();
    _notePlayers.clear();
    for (final player in players) {
      try {
        await player.dispose();
      } catch (e) {
        debugPrint('PianoSynthService: player dispose failed: $e');
      }
    }
    if (players.isNotEmpty) await _restoreMusicSession();
    _noteCache.clear();
    _fileCache.clear();
    if (_tempDir != null) {
      try {
        final dir = Directory(_tempDir!);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('PianoSynthService: temp cleanup failed: $e');
      }
    }
  }
}
