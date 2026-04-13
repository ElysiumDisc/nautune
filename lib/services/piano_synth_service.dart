import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'wav_builder.dart';

/// Programmatic piano synthesizer using additive synthesis + ADSR envelope.
/// Generates WAV audio in-memory (no asset files needed).
/// Uses a pool of AudioPlayer instances for polyphony (round-robin).
class PianoSynthService {
  static const int _sampleRate = 44100;
  static const int _channels = 1;
  static const double _noteDuration = 0.8; // seconds

  // ADSR envelope parameters (in seconds)
  static const double _attack = 0.005;
  static const double _decay = 0.1;
  static const double _sustainLevel = 0.6;
  static const double _release = 0.2;

  // Player pool for polyphony
  static const int _poolSize = 6;
  final List<AudioPlayer> _players = [];
  int _nextPlayer = 0;

  // Cache generated WAV bytes per MIDI note
  final Map<int, Uint8List> _noteCache = {};
  // Cache file paths for written WAV files
  String? _tempDir;
  final Map<int, String> _fileCache = {};

  bool _disposed = false;

  /// Initialize the player pool and temp directory for WAV files.
  Future<void> init() async {
    final dir = await getTemporaryDirectory();
    _tempDir = p.join(dir.path, 'piano_synth');
    await Directory(_tempDir!).create(recursive: true);

    for (int i = 0; i < _poolSize; i++) {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.stop);
      _players.add(player);
    }

    // On iOS/macOS, configure audio context so piano can actually produce sound.
    // Uses playback category with mixWithOthers so it won't interrupt music.
    if (Platform.isIOS || Platform.isMacOS) {
      final context = AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.mixWithOthers},
        ),
      );
      for (final player in _players) {
        await player.setAudioContext(context);
      }
    }
  }

  /// Get or create a WAV temp file for a note, returning its path.
  Future<String> _getOrCreateNoteFile(int midiNote) async {
    if (_fileCache.containsKey(midiNote)) return _fileCache[midiNote]!;
    final wav = _noteCache[midiNote] ?? _generateNoteWav(midiNote);
    _noteCache[midiNote] = wav;
    final filePath = p.join(_tempDir!, 'note_$midiNote.wav');
    await File(filePath).writeAsBytes(wav);
    _fileCache[midiNote] = filePath;
    return filePath;
  }

  /// Play a note by MIDI number (e.g., 60 = C4).
  Future<void> playNote(int midiNote) async {
    if (_disposed || _players.isEmpty || _tempDir == null) return;

    final filePath = await _getOrCreateNoteFile(midiNote);

    final player = _players[_nextPlayer];
    _nextPlayer = (_nextPlayer + 1) % _poolSize;

    try {
      await player.stop();
      await player.play(DeviceFileSource(filePath, mimeType: 'audio/wav'));
    } catch (e) {
      debugPrint('PianoSynthService: Error playing note $midiNote: $e');
    }
  }

  /// Pre-generate and cache WAV data + temp files for a range of notes.
  Future<void> preloadRange(int startMidi, int count) async {
    for (int i = startMidi; i < startMidi + count; i++) {
      _noteCache[i] = _generateNoteWav(i);
      if (_tempDir != null) {
        final filePath = p.join(_tempDir!, 'note_$i.wav');
        await File(filePath).writeAsBytes(_noteCache[i]!);
        _fileCache[i] = filePath;
      }
    }
  }

  /// Convert MIDI note number to frequency in Hz.
  /// A4 (MIDI 69) = 440 Hz.
  static double midiToFrequency(int midiNote) {
    return 440.0 * pow(2.0, (midiNote - 69) / 12.0);
  }

  /// Generate a complete WAV file as Uint8List for a single note.
  Uint8List _generateNoteWav(int midiNote) {
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
      final envelope = _envelope(t);
      sample *= envelope;

      // Normalize and convert to 16-bit
      final clamped = (sample * 0.4 * 32767).round().clamp(-32768, 32767);
      pcmData[i] = clamped;
    }

    return buildWavPcm16(pcmData, sampleRate: _sampleRate, channels: _channels);
  }

  /// ADSR envelope function.
  double _envelope(double t) {
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

  /// Release all resources.
  Future<void> dispose() async {
    _disposed = true;
    for (final player in _players) {
      await player.stop();
      await player.dispose();
    }
    _players.clear();
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
