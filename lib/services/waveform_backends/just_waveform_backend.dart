import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_waveform/just_waveform.dart';

import '../../models/waveform_data.dart';

/// Waveform extraction backend for iOS, macOS, and Android using just_waveform package.
class JustWaveformBackend {
  /// Check if this backend is available on the current platform
  bool get isAvailable => Platform.isIOS || Platform.isMacOS || Platform.isAndroid;

  /// Extract waveform from audio file and save to output path.
  /// Yields progress values from 0.0 to 1.0.
  Stream<double> extract(String audioPath, String outputPath) async* {
    if (!isAvailable) {
      debugPrint('JustWaveformBackend: Not available on this platform');
      return;
    }

    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      debugPrint('JustWaveformBackend: Audio file not found: $audioPath');
      return;
    }

    try {
      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);

      // Extract waveform using just_waveform
      final progressStream = JustWaveform.extract(
        audioInFile: audioFile,
        waveOutFile: outputFile,
        zoom: const WaveformZoom.pixelsPerSecond(100), // ~100 samples per second
      );

      await for (final progress in progressStream) {
        if (progress.waveform != null) {
          // Extraction complete - convert to our format and save
          final waveformData = _convertWaveform(progress.waveform!);
          await _saveWaveformData(outputPath, waveformData);
          yield 1.0;
        } else {
          yield progress.progress.clamp(0.0, 1.0);
        }
      }
    } catch (e) {
      debugPrint('JustWaveformBackend: Extraction failed: $e');
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
      debugPrint('JustWaveformBackend: Failed to load waveform: $e');
      return null;
    }
  }

  /// Convert just_waveform's Waveform to our WaveformData format
  /// Downsamples to ~1000 samples for efficient rendering (matches FFmpeg backend)
  WaveformData _convertWaveform(Waveform waveform) {
    // Target ~1000 samples for visualization (same as FFmpeg backend)
    const int targetSampleCount = 1000;

    // First pass: find the actual max value to detect bit depth
    int maxAbsValue = 0;
    for (int i = 0; i < waveform.length; i++) {
      final min = waveform.getPixelMin(i);
      final max = waveform.getPixelMax(i);
      final absMin = min.abs();
      final absMax = max.abs();
      if (absMin > maxAbsValue) maxAbsValue = absMin;
      if (absMax > maxAbsValue) maxAbsValue = absMax;
    }

    // Use fixed normalizers to match Linux FFmpeg backend behavior
    // Check flag first, validate against actual data for robustness
    final flagSays16Bit = (waveform.flags & 1) != 0;
    final actuallyLooksLike16Bit = maxAbsValue > 128;

    // Trust 16-bit if either indicator suggests it (handles quiet 16-bit files)
    final normalizer = (flagSays16Bit || actuallyLooksLike16Bit) ? 32768.0 : 128.0;

    // Downsample to targetSampleCount for efficient rendering
    // For a 2-hour track at 100 samples/sec, this reduces 720,000 → 1,000 samples
    final sourceLength = waveform.length;
    final outputLength = sourceLength <= targetSampleCount ? sourceLength : targetSampleCount;
    final samplesPerBucket = sourceLength / outputLength;

    final amplitudes = List<double>.filled(outputLength, 0.0);

    for (int i = 0; i < outputLength; i++) {
      final startIdx = (i * samplesPerBucket).floor();
      final endIdx = ((i + 1) * samplesPerBucket).floor().clamp(0, sourceLength);

      // Find max amplitude in this bucket
      double maxAmplitude = 0.0;
      for (int j = startIdx; j < endIdx; j++) {
        final min = waveform.getPixelMin(j);
        final max = waveform.getPixelMax(j);
        final absMin = min.abs();
        final absMax = max.abs();
        final amplitude = (absMin > absMax ? absMin : absMax) / normalizer;
        if (amplitude > maxAmplitude) maxAmplitude = amplitude;
      }
      amplitudes[i] = maxAmplitude.clamp(0.0, 1.0);
    }

    debugPrint('JustWaveformBackend: Downsampled $sourceLength → $outputLength samples');

    return WaveformData(
      amplitudes: amplitudes,
      durationMs: waveform.duration.inMilliseconds,
    );
  }

  /// Save our WaveformData to file
  Future<void> _saveWaveformData(String path, WaveformData data) async {
    try {
      final file = File(path);
      await file.writeAsBytes(data.toBytes());
    } catch (e) {
      debugPrint('JustWaveformBackend: Failed to save waveform: $e');
    }
  }
}
