import 'dart:typed_data';

/// Waveform data model for audio visualization.
/// Stores normalized amplitude values for rendering waveforms.
class WaveformData {
  /// Normalized amplitude values (0.0 - 1.0)
  final List<double> amplitudes;

  /// Number of samples in the waveform
  int get sampleCount => amplitudes.length;

  /// Duration of the audio in milliseconds (if known)
  final int? durationMs;

  const WaveformData({
    required this.amplitudes,
    this.durationMs,
  });

  /// Empty waveform
  static const empty = WaveformData(amplitudes: []);

  /// Get amplitude at a normalized position (0.0 - 1.0)
  double getAmplitudeAt(double position) {
    if (amplitudes.isEmpty) return 0.0;
    final index = (position * (amplitudes.length - 1)).round();
    return amplitudes[index.clamp(0, amplitudes.length - 1)];
  }

  /// Get a range of amplitudes for rendering a specific width
  List<double> getAmplitudesForWidth(int barCount) {
    if (amplitudes.isEmpty || barCount <= 0) return [];

    final result = <double>[];
    for (int i = 0; i < barCount; i++) {
      final position = i / (barCount - 1);
      result.add(getAmplitudeAt(position));
    }
    return result;
  }

  /// Serialize to bytes for caching
  Uint8List toBytes() {
    // Format: [version(1)] [durationMs(4)] [sampleCount(4)] [amplitudes as uint8...]
    final buffer = ByteData(1 + 4 + 4 + amplitudes.length);
    var offset = 0;

    // Version
    buffer.setUint8(offset, 1);
    offset += 1;

    // Duration (0 if null)
    buffer.setUint32(offset, durationMs ?? 0, Endian.little);
    offset += 4;

    // Sample count
    buffer.setUint32(offset, amplitudes.length, Endian.little);
    offset += 4;

    // Amplitudes (stored as uint8, 0-255 mapped from 0.0-1.0)
    for (final amp in amplitudes) {
      buffer.setUint8(offset, (amp.clamp(0.0, 1.0) * 255).round());
      offset += 1;
    }

    return buffer.buffer.asUint8List();
  }

  /// Deserialize from bytes
  factory WaveformData.fromBytes(Uint8List bytes) {
    if (bytes.length < 9) return WaveformData.empty;

    final buffer = ByteData.sublistView(bytes);
    var offset = 0;

    // Version check
    final version = buffer.getUint8(offset);
    offset += 1;
    if (version != 1) return WaveformData.empty;

    // Duration
    final durationMs = buffer.getUint32(offset, Endian.little);
    offset += 4;

    // Sample count
    final sampleCount = buffer.getUint32(offset, Endian.little);
    offset += 4;

    // Check if we have enough bytes
    if (bytes.length < offset + sampleCount) return WaveformData.empty;

    // Amplitudes
    final amplitudes = <double>[];
    for (var i = 0; i < sampleCount; i++) {
      final value = buffer.getUint8(offset);
      amplitudes.add(value / 255.0);
      offset += 1;
    }

    return WaveformData(
      amplitudes: amplitudes,
      durationMs: durationMs > 0 ? durationMs : null,
    );
  }

  /// Create from raw PCM samples (used by FFmpeg backend)
  factory WaveformData.fromPcmSamples(
    List<double> samples, {
    int targetSampleCount = 1000,
    int? durationMs,
  }) {
    if (samples.isEmpty) return WaveformData.empty;

    final samplesPerBucket = (samples.length / targetSampleCount).ceil();
    final amplitudes = <double>[];

    for (var i = 0; i < targetSampleCount && i * samplesPerBucket < samples.length; i++) {
      final start = i * samplesPerBucket;
      final end = (start + samplesPerBucket).clamp(0, samples.length);

      // Find max absolute value in this bucket
      var maxAmp = 0.0;
      for (var j = start; j < end; j++) {
        final absVal = samples[j].abs();
        if (absVal > maxAmp) maxAmp = absVal;
      }

      amplitudes.add(maxAmp.clamp(0.0, 1.0));
    }

    return WaveformData(
      amplitudes: amplitudes,
      durationMs: durationMs,
    );
  }
}
