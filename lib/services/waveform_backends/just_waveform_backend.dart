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
  WaveformData _convertWaveform(Waveform waveform) {
    final amplitudes = <double>[];

    // Extract amplitudes from waveform data
    // just_waveform stores min/max pairs per sample
    for (int i = 0; i < waveform.length; i++) {
      final min = waveform.getPixelMin(i);
      final max = waveform.getPixelMax(i);

      // Use the absolute max as amplitude (normalized to 0-1)
      // The values are typically in range -128 to 127 for 8-bit or larger for 16-bit
      final absMin = min.abs();
      final absMax = max.abs();
      final amplitude = (absMin > absMax ? absMin : absMax) / 128.0;
      amplitudes.add(amplitude.clamp(0.0, 1.0));
    }

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
