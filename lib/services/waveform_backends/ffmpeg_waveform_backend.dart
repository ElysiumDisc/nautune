import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../../models/waveform_data.dart';

/// Waveform extraction backend for Linux using ffmpeg.
/// Extracts PCM audio data and computes waveform peaks in Dart.
class FFmpegWaveformBackend {
  bool _ffmpegAvailable = false;
  bool _ffprobeAvailable = false;

  /// Check if this backend is available on the current platform
  bool get isAvailable => Platform.isLinux && _ffmpegAvailable;

  /// Initialize and check ffmpeg availability
  Future<bool> initialize() async {
    if (!Platform.isLinux) {
      debugPrint('FFmpegWaveformBackend: Not on Linux, skipping');
      return false;
    }

    try {
      // Check for ffmpeg
      final ffmpegResult = await Process.run('which', ['ffmpeg']);
      _ffmpegAvailable = ffmpegResult.exitCode == 0;

      // Check for ffprobe (optional but useful)
      final ffprobeResult = await Process.run('which', ['ffprobe']);
      _ffprobeAvailable = ffprobeResult.exitCode == 0;

      if (_ffmpegAvailable) {
        debugPrint('FFmpegWaveformBackend: Initialized (ffprobe: $_ffprobeAvailable)');
        return true;
      } else {
        debugPrint('FFmpegWaveformBackend: ffmpeg not found');
        return false;
      }
    } catch (e) {
      debugPrint('FFmpegWaveformBackend: Init error: $e');
      return false;
    }
  }

  /// Extract waveform from audio file and save to output path.
  /// Yields progress values from 0.0 to 1.0.
  Stream<double> extract(String audioPath, String outputPath) async* {
    if (!isAvailable) {
      debugPrint('FFmpegWaveformBackend: Not available');
      return;
    }

    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      debugPrint('FFmpegWaveformBackend: Audio file not found: $audioPath');
      return;
    }

    try {
      yield 0.0;

      // Get duration if ffprobe is available
      int? durationMs;
      if (_ffprobeAvailable) {
        durationMs = await _getDuration(audioPath);
        yield 0.1;
      }

      // Extract PCM data using ffmpeg
      // Output: mono, 8kHz sample rate, 16-bit signed little-endian PCM
      // This gives ~8000 samples per second, which is efficient for waveform extraction
      final process = await Process.start('ffmpeg', [
        '-i', audioPath,
        '-ac', '1',           // Mono
        '-ar', '8000',        // 8kHz sample rate (efficient for waveforms)
        '-f', 's16le',        // 16-bit signed little-endian PCM
        '-acodec', 'pcm_s16le',
        '-v', 'quiet',        // Suppress output
        '-',                  // Output to stdout
      ]);

      final samples = <double>[];
      final completer = Completer<void>();

      // Collect PCM data
      final chunks = <List<int>>[];
      process.stdout.listen(
        (chunk) {
          chunks.add(chunk);
        },
        onDone: () {
          completer.complete();
        },
        onError: (e) {
          debugPrint('FFmpegWaveformBackend: Stream error: $e');
          completer.complete();
        },
      );

      // Wait for process to complete
      await completer.future;
      await process.exitCode;

      yield 0.5;

      // Combine all chunks
      final totalLength = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      final allBytes = Uint8List(totalLength);
      var offset = 0;
      for (final chunk in chunks) {
        allBytes.setAll(offset, chunk);
        offset += chunk.length;
      }

      // Convert to samples
      final byteData = ByteData.sublistView(allBytes);
      for (var i = 0; i < byteData.lengthInBytes - 1; i += 2) {
        final sample = byteData.getInt16(i, Endian.little);
        samples.add(sample / 32768.0); // Normalize to -1.0 to 1.0
      }

      yield 0.8;

      // Create waveform data
      final waveformData = WaveformData.fromPcmSamples(
        samples,
        targetSampleCount: 1000, // ~1000 samples for visualization
        durationMs: durationMs,
      );

      // Save to file
      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsBytes(waveformData.toBytes());

      yield 1.0;

      debugPrint('FFmpegWaveformBackend: Extracted ${waveformData.sampleCount} samples');
    } catch (e) {
      debugPrint('FFmpegWaveformBackend: Extraction failed: $e');
    }
  }

  /// Load waveform from a previously saved file.
  Future<WaveformData?> load(String waveformPath) async {
    try {
      final file = File(waveformPath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      return WaveformData.fromBytes(bytes);
    } catch (e) {
      debugPrint('FFmpegWaveformBackend: Failed to load waveform: $e');
      return null;
    }
  }

  /// Get audio duration using ffprobe
  Future<int?> _getDuration(String audioPath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        audioPath,
      ]);

      if (result.exitCode == 0) {
        final durationStr = (result.stdout as String).trim();
        final durationSeconds = double.tryParse(durationStr);
        if (durationSeconds != null) {
          return (durationSeconds * 1000).round();
        }
      }
    } catch (e) {
      debugPrint('FFmpegWaveformBackend: Failed to get duration: $e');
    }
    return null;
  }
}
