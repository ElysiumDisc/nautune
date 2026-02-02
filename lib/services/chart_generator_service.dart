import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, max, min, log, sqrt;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fftea/fftea.dart';
import '../models/chart_data.dart';

/// Service for generating rhythm game charts from audio files.
/// Uses SuperFlux-inspired spectral flux onset detection with pitch tracking.
class ChartGeneratorService {
  static ChartGeneratorService? _instance;
  static ChartGeneratorService get instance =>
      _instance ??= ChartGeneratorService._();

  ChartGeneratorService._();

  // FFT parameters - slightly larger window for better frequency resolution
  static const int _windowSize = 2048;
  static const int _hopSize = 441; // ~10ms hop at 44.1kHz for smoother tracking
  static const int _sampleRate = 44100;

  // Onset detection parameters (SuperFlux-inspired)
  static const int _maxFilterSize = 3;  // Moving max filter (frames) - 30ms
  static const int _avgFilterPast = 15;  // Moving average past context (frames) - 150ms
  static const int _avgFilterFuture = 5; // Moving average future context (frames) - 50ms
  static const double _threshold = 1.8;  // Threshold above moving average
  static const int _minOnsetGapMs = 120; // Minimum gap between notes

  // Lane assignment - 5 frequency bands mapped to musical pitch ranges
  // These are optimized for typical pop/rock music frequency distribution
  static const double _subBassMaxFreq = 100;   // Lane 0 - Green (kick drums, sub-bass)
  static const double _bassMaxFreq = 250;      // Lane 1 - Red (bass guitar, low synth)
  static const double _lowMidMaxFreq = 600;    // Lane 2 - Yellow (vocals low, guitar body)
  static const double _highMidMaxFreq = 2000;  // Lane 3 - Blue (vocals, guitar lead)
  // Lane 4 - Orange (treble > 2000Hz - synths, cymbals)

  // Maximum track duration for analysis (in minutes) - prevents memory crashes
  static const int _maxDurationMinutesIOS = 15;      // iOS: strict limit due to memory
  static const int _maxDurationMinutesOther = 30;    // Android/Desktop: more lenient

  /// Progress callback for UI updates (0.0 - 1.0)
  ValueNotifier<double> progress = ValueNotifier(0.0);

  /// Check if track duration is within safe limits for current platform
  /// Returns error message if too long, null if OK
  String? checkDurationLimit(int durationMs) {
    final durationMinutes = durationMs / 60000;
    final maxMinutes = Platform.isIOS ? _maxDurationMinutesIOS : _maxDurationMinutesOther;

    if (durationMinutes > maxMinutes) {
      return 'Track is ${durationMinutes.toStringAsFixed(1)} minutes long. '
          'Maximum for ${Platform.isIOS ? "iOS" : "this device"} is $maxMinutes minutes '
          'to prevent crashes.';
    }
    return null;
  }

  /// Maximum duration in minutes for current platform
  int get maxDurationMinutes => Platform.isIOS ? _maxDurationMinutesIOS : _maxDurationMinutesOther;

  /// Insert golden bonus notes into the chart at random intervals (30-60 seconds apart)
  List<ChartNote> _insertBonusNotes(List<ChartNote> notes, int durationMs) {
    if (notes.isEmpty || durationMs < 45000) return notes; // Too short for bonuses

    final random = Random();
    final result = List<ChartNote>.from(notes);
    final bonusTypes = BonusType.values;

    // Calculate how many bonus notes to add (1 per 30-60 seconds)
    final avgInterval = 45000; // 45 seconds average
    final numBonuses = max(1, durationMs ~/ avgInterval);

    // Distribute bonuses across the track duration
    // Start after 15 seconds to let player warm up
    final startMs = 15000;
    final endMs = durationMs - 10000; // Don't add in last 10 seconds
    final availableRange = endMs - startMs;

    if (availableRange < 30000) return notes; // Not enough room

    final bonusTimestamps = <int>[];

    for (int i = 0; i < numBonuses; i++) {
      // Random timestamp within the range, with some spacing
      final segmentSize = availableRange ~/ numBonuses;
      final segmentStart = startMs + (i * segmentSize);
      final jitter = random.nextInt(segmentSize ~/ 2); // Random offset within segment
      final timestamp = segmentStart + jitter;

      // Make sure not too close to existing bonus
      bool tooClose = bonusTimestamps.any((t) => (t - timestamp).abs() < 20000);
      if (!tooClose) {
        bonusTimestamps.add(timestamp);
      }
    }

    // Create bonus notes at these timestamps
    for (final timestamp in bonusTimestamps) {
      // Pick a random lane and bonus type
      final lane = random.nextInt(5);
      final bonusType = bonusTypes[random.nextInt(bonusTypes.length)];

      result.add(ChartNote(
        timestampMs: timestamp,
        lane: lane,
        band: FrequencyBand.values[lane],
        isBonus: true,
        bonusType: bonusType,
      ));
    }

    // Sort by timestamp
    result.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    return result;
  }

  /// Generate a chart from an audio file
  Future<ChartData?> generateChart({
    required String audioPath,
    required String trackId,
    required String trackName,
    required String artistName,
    required int durationMs,
  }) async {
    try {
      progress.value = 0.0;

      // Check duration limit to prevent memory crashes
      final durationError = checkDurationLimit(durationMs);
      if (durationError != null) {
        debugPrint('🎮 ChartGenerator: $durationError');
        return null;
      }

      // Read audio file
      final audioData = await _readAudioFile(audioPath);
      if (audioData == null || audioData.isEmpty) {
        debugPrint('🎮 ChartGenerator: Failed to read audio file');
        return null;
      }

      progress.value = 0.1;

      // Run onset detection in isolate
      final result = await compute(_processAudioAdvanced, _AudioProcessingParams(
        samples: audioData,
        sampleRate: _sampleRate,
        windowSize: _windowSize,
        hopSize: _hopSize,
        maxFilterSize: _maxFilterSize,
        avgFilterPast: _avgFilterPast,
        avgFilterFuture: _avgFilterFuture,
        threshold: _threshold,
        minOnsetGapMs: _minOnsetGapMs,
        subBassMaxFreq: _subBassMaxFreq,
        bassMaxFreq: _bassMaxFreq,
        lowMidMaxFreq: _lowMidMaxFreq,
        highMidMaxFreq: _highMidMaxFreq,
      ));

      progress.value = 0.9;

      if (result.notes.isEmpty) {
        debugPrint('🎮 ChartGenerator: No notes detected');
        return null;
      }

      // Insert bonus notes (approximately 1 per 30-60 seconds)
      final notesWithBonuses = _insertBonusNotes(result.notes, durationMs);

      progress.value = 1.0;

      debugPrint('🎮 ChartGenerator: Generated ${notesWithBonuses.length} notes (${notesWithBonuses.where((n) => n.isBonus).length} bonus), BPM: ${result.bpm.round()}');

      return ChartData(
        id: '${trackId}_chart',
        trackId: trackId,
        trackName: trackName,
        artistName: artistName,
        notes: notesWithBonuses,
        bpm: result.bpm,
        durationMs: durationMs,
        generatedAt: DateTime.now(),
      );
    } catch (e, stack) {
      debugPrint('🎮 ChartGenerator: Error - $e');
      debugPrint('$stack');
      return null;
    }
  }

  // Method channel for iOS audio decoding
  static const _iosChannel = MethodChannel('com.elysiumdisc.nautune/audio_decoder');

  /// Read raw PCM samples from audio file
  Future<Float64List?> _readAudioFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('🎮 ChartGenerator: File not found: $path');
        return null;
      }

      if (Platform.isIOS) {
        return _readAudioFileIOS(path);
      } else {
        return _readAudioFileFFmpeg(path);
      }
    } catch (e) {
      debugPrint('🎮 ChartGenerator: Error reading audio: $e');
      return null;
    }
  }

  /// iOS: Decode audio using native AVFoundation
  Future<Float64List?> _readAudioFileIOS(String path) async {
    try {
      debugPrint('🎮 ChartGenerator: Decoding audio with AVFoundation (iOS)...');

      final result = await _iosChannel.invokeMethod<Map>('decodeAudio', {
        'path': path,
        'sampleRate': _sampleRate,
      });

      if (result == null) {
        debugPrint('🎮 ChartGenerator: iOS decoder returned null');
        return null;
      }

      // iOS returns List<dynamic> which needs to be converted to Float64List
      final rawSamples = result['samples'];
      if (rawSamples == null) {
        debugPrint('🎮 ChartGenerator: No samples in result');
        return null;
      }

      // Convert from List<dynamic> (List<double>) to Float64List
      Float64List samples;
      if (rawSamples is Float64List) {
        samples = rawSamples;
      } else if (rawSamples is List) {
        samples = Float64List(rawSamples.length);
        for (int i = 0; i < rawSamples.length; i++) {
          samples[i] = (rawSamples[i] as num).toDouble();
        }
      } else {
        debugPrint('🎮 ChartGenerator: Unexpected samples type: ${rawSamples.runtimeType}');
        return null;
      }

      if (samples.isEmpty) {
        debugPrint('🎮 ChartGenerator: No samples decoded');
        return null;
      }

      debugPrint('🎮 ChartGenerator: Decoded ${samples.length} samples (${(samples.length / _sampleRate).toStringAsFixed(1)}s)');
      return samples;
    } on PlatformException catch (e) {
      debugPrint('🎮 ChartGenerator: iOS decode error: ${e.message}');
      return null;
    }
  }

  /// Linux/Desktop: Decode audio using FFmpeg
  Future<Float64List?> _readAudioFileFFmpeg(String path) async {
    debugPrint('🎮 ChartGenerator: Decoding audio with FFmpeg...');

    final process = await Process.start('ffmpeg', [
      '-i', path,
      '-ac', '1',
      '-ar', '$_sampleRate',
      '-f', 's16le',
      '-acodec', 'pcm_s16le',
      '-v', 'quiet',
      '-',
    ]);

    final completer = Completer<void>();
    final chunks = <List<int>>[];

    process.stdout.listen(
      (chunk) => chunks.add(chunk),
      onDone: () => completer.complete(),
      onError: (e) {
        debugPrint('🎮 ChartGenerator: FFmpeg stream error: $e');
        completer.complete();
      },
    );

    process.stderr.listen((_) {});

    await completer.future;
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      debugPrint('🎮 ChartGenerator: FFmpeg failed with exit code $exitCode');
      return null;
    }

    final totalLength = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    if (totalLength < 2) {
      debugPrint('🎮 ChartGenerator: No audio data decoded');
      return null;
    }

    final allBytes = Uint8List(totalLength);
    var offset = 0;
    for (final chunk in chunks) {
      allBytes.setAll(offset, chunk);
      offset += chunk.length;
    }

    final byteData = ByteData.sublistView(allBytes);
    final sampleCount = byteData.lengthInBytes ~/ 2;
    final samples = Float64List(sampleCount);

    for (var i = 0; i < sampleCount; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      samples[i] = sample / 32768.0;
    }

    debugPrint('🎮 ChartGenerator: FFmpeg decoded ${samples.length} samples');
    return samples;
  }
}

/// Parameters for audio processing
class _AudioProcessingParams {
  final Float64List samples;
  final int sampleRate;
  final int windowSize;
  final int hopSize;
  final int maxFilterSize;
  final int avgFilterPast;
  final int avgFilterFuture;
  final double threshold;
  final int minOnsetGapMs;
  final double subBassMaxFreq;
  final double bassMaxFreq;
  final double lowMidMaxFreq;
  final double highMidMaxFreq;

  const _AudioProcessingParams({
    required this.samples,
    required this.sampleRate,
    required this.windowSize,
    required this.hopSize,
    required this.maxFilterSize,
    required this.avgFilterPast,
    required this.avgFilterFuture,
    required this.threshold,
    required this.minOnsetGapMs,
    required this.subBassMaxFreq,
    required this.bassMaxFreq,
    required this.lowMidMaxFreq,
    required this.highMidMaxFreq,
  });
}

/// Result from audio processing
class _ProcessingResult {
  final List<ChartNote> notes;
  final double bpm;

  const _ProcessingResult({required this.notes, required this.bpm});
}

/// Advanced audio processing with SuperFlux-inspired onset detection
/// and pitch-based lane assignment
_ProcessingResult _processAudioAdvanced(_AudioProcessingParams params) {
  final samples = params.samples;
  final windowSize = params.windowSize;
  final hopSize = params.hopSize;
  final sampleRate = params.sampleRate;

  if (samples.length < windowSize * 2) {
    return const _ProcessingResult(notes: [], bpm: 120.0);
  }

  // Create FFT instance
  final fft = FFT(windowSize);

  // Pre-compute Hanning window
  final window = Float64List(windowSize);
  for (int i = 0; i < windowSize; i++) {
    window[i] = 0.5 * (1 - _cos(2 * 3.14159265359 * i / (windowSize - 1)));
  }

  // Compute STFT
  final numFrames = (samples.length - windowSize) ~/ hopSize + 1;
  final binFreq = sampleRate.toDouble() / windowSize;

  // Store log-magnitude spectra for spectral flux
  final logMagSpectra = <Float64List>[];
  // Store centroid for each frame (for pitch tracking)
  final spectroids = Float64List(numFrames);

  // Frequency bin boundaries
  final subBassMaxBin = (params.subBassMaxFreq / binFreq).round();
  final bassMaxBin = (params.bassMaxFreq / binFreq).round();
  final lowMidMaxBin = (params.lowMidMaxFreq / binFreq).round();
  final highMidMaxBin = (params.highMidMaxFreq / binFreq).round();

  for (int frame = 0; frame < numFrames; frame++) {
    final start = frame * hopSize;

    // Apply window
    final windowed = Float64List(windowSize);
    for (int i = 0; i < windowSize; i++) {
      windowed[i] = samples[start + i] * window[i];
    }

    // Compute FFT
    final spectrum = fft.realFft(windowed);
    final magnitudes = spectrum.discardConjugates().magnitudes();

    // Convert to log-magnitude (add small epsilon to avoid log(0))
    final logMags = Float64List(magnitudes.length);
    double sumMag = 0;
    double sumFreqMag = 0;

    for (int i = 0; i < magnitudes.length; i++) {
      final mag = magnitudes[i];
      logMags[i] = log(mag + 1e-10);

      // Compute spectral centroid (weighted average frequency)
      final freq = i * binFreq;
      sumMag += mag;
      sumFreqMag += freq * mag;
    }

    logMagSpectra.add(logMags);

    // Spectral centroid - the "center of mass" of the spectrum
    // This tells us if the sound is predominantly low or high pitched
    spectroids[frame] = sumMag > 0 ? sumFreqMag / sumMag : 500.0;
  }

  // Compute SuperFlux-style spectral flux
  // This uses a maximum filter to track spectral trajectories,
  // making it robust to vibrato and gradual changes
  final spectralFlux = Float64List(numFrames);
  final maxFilter = params.maxFilterSize;

  for (int frame = 1; frame < numFrames; frame++) {
    final curr = logMagSpectra[frame];
    final prev = logMagSpectra[frame - 1];

    double flux = 0;
    for (int bin = 0; bin < curr.length; bin++) {
      // Get maximum of previous frames (trajectory tracking)
      double maxPrev = prev[bin];
      for (int m = 2; m <= maxFilter && frame - m >= 0; m++) {
        final older = logMagSpectra[frame - m][bin];
        if (older > maxPrev) maxPrev = older;
      }

      // Only count positive differences (energy increases)
      final diff = curr[bin] - maxPrev;
      if (diff > 0) {
        flux += diff;
      }
    }
    spectralFlux[frame] = flux;
  }

  // Compute per-band flux for weighting
  final bandFlux = List.generate(5, (_) => Float64List(numFrames));

  for (int frame = 1; frame < numFrames; frame++) {
    final curr = logMagSpectra[frame];
    final prev = logMagSpectra[frame - 1];

    double subBassF = 0, bassF = 0, lowMidF = 0, highMidF = 0, trebleF = 0;

    for (int bin = 0; bin < curr.length; bin++) {
      final diff = curr[bin] - prev[bin];
      if (diff > 0) {
        if (bin < subBassMaxBin) {
          subBassF += diff;
        } else if (bin < bassMaxBin) {
          bassF += diff;
        } else if (bin < lowMidMaxBin) {
          lowMidF += diff;
        } else if (bin < highMidMaxBin) {
          highMidF += diff;
        } else {
          trebleF += diff;
        }
      }
    }

    bandFlux[0][frame] = subBassF;
    bandFlux[1][frame] = bassF;
    bandFlux[2][frame] = lowMidF;
    bandFlux[3][frame] = highMidF;
    bandFlux[4][frame] = trebleF;
  }

  // Calculate spectral centroid statistics for adaptive thresholds
  // This helps the chart adapt to the song's overall pitch range (e.g., bass-heavy vs treble-heavy)
  double sumCentroid = 0;
  double sumSqCentroid = 0;
  int centroidCount = 0;

  for (int i = 0; i < numFrames; i++) {
    if (spectroids[i] > 10.0) { // Ignore silence/noise
      sumCentroid += spectroids[i];
      sumSqCentroid += spectroids[i] * spectroids[i];
      centroidCount++;
    }
  }

  final meanCentroid = centroidCount > 0 ? sumCentroid / centroidCount : 500.0;
  final varianceCentroid = centroidCount > 0
      ? (sumSqCentroid / centroidCount) - (meanCentroid * meanCentroid)
      : 0.0;
  final stdDevCentroid = sqrt(varianceCentroid > 0 ? varianceCentroid : 0);

  // Dynamic thresholds based on Z-scores relative to song's own distribution
  final thresh0 = meanCentroid - 0.8 * stdDevCentroid;
  final thresh1 = meanCentroid - 0.2 * stdDevCentroid;
  final thresh2 = meanCentroid + 0.2 * stdDevCentroid;
  final thresh3 = meanCentroid + 0.8 * stdDevCentroid;

  debugPrint('🎮 Adaptive Thresholds: Mean=${meanCentroid.round()}, Std=${stdDevCentroid.round()}, Thresh=[${thresh0.round()}, ${thresh1.round()}, ${thresh2.round()}, ${thresh3.round()}]');

  // STEP 1: Estimate BPM first (before onset detection)
  // This allows proper beat-grid quantization
  final bpm = _estimateBpmFromFlux(spectralFlux, hopSize, sampleRate);
  final beatIntervalMs = (60000.0 / bpm).round();
  final sixteenthNoteMs = beatIntervalMs ~/ 4; // 16th note grid

  debugPrint('🎮 Estimated BPM: ${bpm.round()}, beat interval: ${beatIntervalMs}ms, 16th: ${sixteenthNoteMs}ms');

  // STEP 2: Peak picking with moving average threshold
  final avgPast = params.avgFilterPast;
  final avgFuture = params.avgFilterFuture;
  final threshold = params.threshold;

  // Compute moving average
  final movingAvg = Float64List(numFrames);
  for (int frame = 0; frame < numFrames; frame++) {
    final start = max(0, frame - avgPast);
    final end = min(numFrames, frame + avgFuture + 1);
    double sum = 0;
    for (int i = start; i < end; i++) {
      sum += spectralFlux[i];
    }
    movingAvg[frame] = sum / (end - start);
  }

  // Compute moving maximum
  final movingMax = Float64List(numFrames);
  for (int frame = 0; frame < numFrames; frame++) {
    final start = max(0, frame - maxFilter);
    final end = min(numFrames, frame + maxFilter + 1);
    double maxVal = 0;
    for (int i = start; i < end; i++) {
      if (spectralFlux[i] > maxVal) maxVal = spectralFlux[i];
    }
    movingMax[frame] = maxVal;
  }

  // Detect onsets: peaks that are local maximum AND above threshold
  final onsetFrames = <int>[];
  int lastOnsetFrame = -100;

  for (int frame = 1; frame < numFrames - 1; frame++) {
    // Must be equal to local maximum (within floating point tolerance)
    final isLocalMax = (spectralFlux[frame] - movingMax[frame]).abs() < 1e-6;

    // Must exceed adaptive threshold
    final aboveThreshold = spectralFlux[frame] > movingAvg[frame] * threshold;

    if (isLocalMax && aboveThreshold) {
      // Enforce minimum gap
      final timestampMs = (frame * hopSize * 1000 / sampleRate).round();
      final lastTimestampMs = lastOnsetFrame >= 0
          ? (lastOnsetFrame * hopSize * 1000 / sampleRate).round()
          : -1000;

      if (timestampMs - lastTimestampMs >= params.minOnsetGapMs) {
        onsetFrames.add(frame);
        lastOnsetFrame = frame;
      }
    }
  }

  debugPrint('🎮 Detected ${onsetFrames.length} raw onsets');

  // STEP 3: Create notes with beat-quantized timing and pitch-based lanes
  final notes = <ChartNote>[];

  for (int i = 0; i < onsetFrames.length; i++) {
    final frame = onsetFrames[i];
    final rawTimestampMs = (frame * hopSize * 1000 / sampleRate).round();

    // Quantize to 16th note grid
    final quantizedMs = ((rawTimestampMs + sixteenthNoteMs ~/ 2) ~/ sixteenthNoteMs) * sixteenthNoteMs;

    // Determine lane based on BOTH spectral centroid (pitch) and band flux
    // The centroid tells us the "pitch feel" of this moment in the song
    final centroid = spectroids[frame];

    // Map centroid to a rough lane (0-4) using ADAPTIVE thresholds
    int pitchLane;
    if (centroid < thresh0) {
      pitchLane = 0; // Green (Low relative to this song)
    } else if (centroid < thresh1) {
      pitchLane = 1; // Red
    } else if (centroid < thresh2) {
      pitchLane = 2; // Yellow
    } else if (centroid < thresh3) {
      pitchLane = 3; // Blue
    } else {
      pitchLane = 4; // Orange (High relative to this song)
    }

    // Also check which band had the strongest onset
    // Weight: bass gets boost, treble gets reduced
    final weights = [3.0, 2.5, 2.0, 1.5, 0.5]; // sub-bass, bass, low-mid, high-mid, treble
    double maxWeightedFlux = 0;
    int fluxLane = 2; // default to middle
    double totalBandFlux = 0;

    // Store weighted fluxes for chord detection
    final weightedFluxes = List<double>.filled(5, 0.0);

    for (int b = 0; b < 5; b++) {
      final flux = bandFlux[b][frame];
      totalBandFlux += flux;
      final weighted = flux * weights[b];
      weightedFluxes[b] = weighted;

      if (weighted > maxWeightedFlux) {
        maxWeightedFlux = weighted;
        fluxLane = b;
      }
    }

    // Combine: prefer flux-based lane for drums/bass, pitch-based for melodic content
    // If sub-bass or bass flux is strong relative to TOTAL band flux, use flux lane
    final bassFluxRatio = (bandFlux[0][frame] + bandFlux[1][frame]) /
        (totalBandFlux + 1e-6);

    final primaryLane = bassFluxRatio > 0.4 ? fluxLane : pitchLane;

    // SUSTAIN CALCULATION
    int? sustainMs;
    if (i < onsetFrames.length - 1) {
      final nextRawMs = (onsetFrames[i + 1] * hopSize * 1000 / sampleRate).round();
      final gap = nextRawMs - rawTimestampMs;
      // If gap is longer than a beat, make it a sustain
      if (gap > beatIntervalMs) {
        sustainMs = min(gap - 50, beatIntervalMs * 4); // Cap at 4 beats
      }
    }

    notes.add(ChartNote(
      timestampMs: quantizedMs,
      lane: primaryLane,
      sustainMs: sustainMs,
      band: FrequencyBand.values[primaryLane],
    ));

    // CHORD GENERATION
    // If we have another strong band that isn't the primary lane, add it
    for (int b = 0; b < 5; b++) {
      if (b == primaryLane) continue;

      // If this band is at least 70% as strong as the max, add it as a chord note
      // Only if total flux is high enough to justify chords (avoid chords in quiet sections)
      if (weightedFluxes[b] > maxWeightedFlux * 0.7 && totalBandFlux > 1.0) {
        notes.add(ChartNote(
          timestampMs: quantizedMs,
          lane: b,
          sustainMs: sustainMs, // Chords share sustain
          band: FrequencyBand.values[b],
        ));
        break; // Max 2 notes per chord to keep it playable
      }
    }

    // Cap at 3000 notes for very long tracks
    if (notes.length >= 3000) break;
  }

  // Remove exact duplicates (same timestamp AND lane)
  final uniqueNotes = <ChartNote>[];
  final seenNotes = <String>{};

  for (final note in notes) {
    final key = '${note.timestampMs}_${note.lane}';
    if (!seenNotes.contains(key)) {
      seenNotes.add(key);
      uniqueNotes.add(note);
    }
  }

  // Debug: Lane distribution
  final laneCounts = [0, 0, 0, 0, 0];
  for (final note in uniqueNotes) {
    laneCounts[note.lane]++;
  }
  debugPrint('🎮 Final: ${uniqueNotes.length} notes, lanes: $laneCounts');

  return _ProcessingResult(notes: uniqueNotes, bpm: bpm);
}

/// Estimate BPM from spectral flux using autocorrelation
double _estimateBpmFromFlux(Float64List flux, int hopSize, int sampleRate) {
  // Look for periodicities in flux corresponding to 60-200 BPM
  // At 44100Hz and 441 hop, each frame is ~10ms
  // 60 BPM = 1000ms per beat = 100 frames
  // 200 BPM = 300ms per beat = 30 frames

  final minLag = 30;  // 200 BPM
  final maxLag = 100; // 60 BPM

  // Normalize flux
  double mean = 0;
  for (int i = 0; i < flux.length; i++) {
    mean += flux[i];
  }
  mean /= flux.length;

  final normalizedFlux = Float64List(flux.length);
  for (int i = 0; i < flux.length; i++) {
    normalizedFlux[i] = flux[i] - mean;
  }

  // Compute autocorrelation for different lags
  double bestCorr = 0;
  int bestLag = 50; // default to ~120 BPM

  for (int lag = minLag; lag <= maxLag; lag++) {
    double corr = 0;
    int count = 0;

    for (int i = 0; i < normalizedFlux.length - lag; i++) {
      corr += normalizedFlux[i] * normalizedFlux[i + lag];
      count++;
    }

    if (count > 0) {
      corr /= count;
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }
  }

  // Convert lag to BPM
  final lagMs = bestLag * hopSize * 1000.0 / sampleRate;
  final bpm = 60000.0 / lagMs;

  // Clamp to reasonable range
  return bpm.clamp(70.0, 180.0);
}

double _cos(double x) {
  x = x % (2 * 3.14159265359);
  double result = 1.0;
  double term = 1.0;
  for (int i = 1; i <= 10; i++) {
    term *= -x * x / ((2 * i - 1) * (2 * i));
    result += term;
  }
  return result;
}
