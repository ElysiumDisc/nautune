import 'dart:async';
import 'dart:io';
import 'dart:isolate' show TransferableTypedData;
import 'dart:math' show Random, cos, log, max, min, pi, sqrt;
import 'dart:typed_data' show Float64x2, Float64x2List;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fftea/fftea.dart';
import '../models/chart_data.dart';

/// Outcome of [ChartGeneratorService.generateChart]: the chart, or the
/// human-readable reason it failed.
typedef ChartGenerationResult = ({ChartData? chart, String? failure});

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

  /// Maximum notes per chart. Denser charts are thinned evenly across the
  /// whole song rather than truncated.
  static const int _maxNotes = 3000;

  // Lane assignment - 5 frequency bands mapped to musical pitch ranges
  // These are optimized for typical pop/rock music frequency distribution
  static const double _subBassMaxFreq = 100;   // Lane 0 - Green (kick drums, sub-bass)
  static const double _bassMaxFreq = 250;      // Lane 1 - Red (bass guitar, low synth)
  static const double _lowMidMaxFreq = 600;    // Lane 2 - Yellow (vocals low, guitar body)
  static const double _highMidMaxFreq = 2000;  // Lane 3 - Blue (vocals, guitar lead)
  // Lane 4 - Orange (treble > 2000Hz - synths, cymbals)

  // Maximum track duration for analysis (in minutes) - prevents memory crashes
  static const int _maxDurationMinutesIOS = 15;      // iOS: strict limit due to memory

  /// Progress (0.0 - 1.0) per track ID, so two screens or a queued request
  /// never show another track's progress.
  final Map<String, ValueNotifier<double>> _progress = {};

  /// Generations requested or running, keyed by track ID, so the same track
  /// is never decoded twice at once.
  final Map<String, Future<ChartGenerationResult>> _inFlight = {};

  /// Track IDs whose generation was cancelled (see [cancel]).
  final Set<String> _cancelled = {};

  /// Generations run one at a time: each holds a whole decoded track in
  /// memory, so two at once could exhaust it on long tracks.
  Future<void> _queueTail = Future<void>.value();

  /// Progress of the generation for [trackId] (0.0 - 1.0).
  ValueListenable<double> progressFor(String trackId) =>
      _progress.putIfAbsent(trackId, () => ValueNotifier(0.0));

  /// Stop the generation for [trackId] at its next checkpoint (before
  /// decoding and before analysis). A request that is already analysing
  /// finishes; one still waiting in the queue never starts.
  void cancel(String trackId) {
    if (_inFlight.containsKey(trackId)) _cancelled.add(trackId);
  }

  /// Check if track duration is within safe limits for current platform
  /// Returns error message if too long, null if OK
  String? checkDurationLimit(int durationMs) {
    final durationMinutes = durationMs / 60000;
    const maxMinutes = _maxDurationMinutesIOS;

    if (durationMinutes > maxMinutes) {
      return 'Track is ${durationMinutes.toStringAsFixed(1)} minutes long. '
          'Maximum for iOS is $maxMinutes minutes '
          'to prevent crashes.';
    }
    return null;
  }

  /// Maximum duration in minutes for current platform
  int get maxDurationMinutes => _maxDurationMinutesIOS;

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
      // A lane clear of regular notes, so the bonus can't take a tap meant
      // for one (or hide under it). Random type.
      final lane = pickBonusLane(notes, timestamp, random);
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

  /// Generate a chart from an audio file.
  ///
  /// Concurrent calls for the same [trackId] share one generation; calls for
  /// different tracks run one after another. Never throws: on failure the
  /// result has no chart and a reason.
  Future<ChartGenerationResult> generateChart({
    required String audioPath,
    required String trackId,
    required String trackName,
    required String artistName,
    required int durationMs,
  }) {
    // Asking again means the caller wants it after all.
    _cancelled.remove(trackId);
    final pending = _inFlight[trackId];
    if (pending != null) return pending;

    final progress = _progress.putIfAbsent(trackId, () => ValueNotifier(0.0))
      ..value = 0.0;
    final future = _queueTail
        .then((_) => _generateChart(
              audioPath: audioPath,
              trackId: trackId,
              trackName: trackName,
              artistName: artistName,
              durationMs: durationMs,
              progress: progress,
            ))
        .whenComplete(() {
      _inFlight.remove(trackId);
      _cancelled.remove(trackId);
      _progress.remove(trackId);
    });
    _queueTail = future.then<void>((_) {}, onError: (Object _) {});
    _inFlight[trackId] = future;
    return future;
  }

  Future<ChartGenerationResult> _generateChart({
    required String audioPath,
    required String trackId,
    required String trackName,
    required String artistName,
    required int durationMs,
    required ValueNotifier<double> progress,
  }) async {
    const cancelled = (chart: null, failure: 'Cancelled');
    try {
      if (_cancelled.contains(trackId)) return cancelled;
      progress.value = 0.0;

      // Check duration limit to prevent memory crashes. The metadata may be
      // missing or wrong; the native decoder enforces the real length too.
      final durationError = checkDurationLimit(durationMs);
      if (durationError != null) {
        debugPrint('🎮 ChartGenerator: $durationError');
        return (chart: null, failure: durationError);
      }

      // Read audio file
      Float32List? audioData;
      String? decodeFailure;
      (samples: audioData, failure: decodeFailure) = await _readAudioFile(audioPath);
      if (audioData == null || audioData.isEmpty) {
        debugPrint('🎮 ChartGenerator: Failed to read audio file');
        return (
          chart: null,
          failure: decodeFailure ?? 'Could not decode this audio file',
        );
      }
      if (_cancelled.contains(trackId)) return cancelled;

      // Use the real decoded length rather than (possibly missing) metadata.
      final decodedDurationMs = audioData.length * 1000 ~/ _sampleRate;

      progress.value = 0.1;

      // Run onset detection in an isolate. The samples are handed over as
      // transferable data (materialised in the isolate without another
      // copy), and the reference here is dropped so the decoded buffer can
      // be freed while the analysis runs.
      final transferable = TransferableTypedData.fromList([audioData]);
      audioData = null;
      final result = await compute(_processTransferredAudio, transferable);

      progress.value = 0.9;

      if (result.notes.isEmpty) {
        debugPrint('🎮 ChartGenerator: No notes detected');
        return (chart: null, failure: 'No beats detected (track too short or quiet)');
      }

      // Insert bonus notes (approximately 1 per 30-60 seconds)
      final notesWithBonuses = _insertBonusNotes(result.notes, decodedDurationMs);

      progress.value = 1.0;

      debugPrint('🎮 ChartGenerator: Generated ${notesWithBonuses.length} notes (${notesWithBonuses.where((n) => n.isBonus).length} bonus), BPM: ${result.bpm.round()}');

      return (
        chart: ChartData(
          id: '${trackId}_chart',
          trackId: trackId,
          trackName: trackName,
          artistName: artistName,
          notes: notesWithBonuses,
          bpm: result.bpm,
          durationMs: decodedDurationMs,
          generatedAt: DateTime.now(),
        ),
        failure: null,
      );
    } catch (e, stack) {
      debugPrint('🎮 ChartGenerator: Error - $e');
      debugPrint('$stack');
      return (chart: null, failure: 'Analysis failed');
    }
  }

  // Method channel for iOS audio decoding
  static const _iosChannel = MethodChannel('com.elysiumdisc.nautune/audio_decoder');

  /// Read raw PCM samples from audio file
  Future<({Float32List? samples, String? failure})> _readAudioFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        debugPrint('🎮 ChartGenerator: File not found: $path');
        return (samples: null, failure: 'Audio file not found');
      }

      return await _readAudioFileIOS(path);
    } catch (e) {
      debugPrint('🎮 ChartGenerator: Error reading audio: $e');
      return (samples: null, failure: null);
    }
  }

  /// iOS: Decode audio to mono float32 PCM using native AVFoundation
  Future<({Float32List? samples, String? failure})> _readAudioFileIOS(String path) async {
    try {
      debugPrint('🎮 ChartGenerator: Decoding audio with AVFoundation (iOS)...');

      final result = await _iosChannel.invokeMethod<Map>('decodeAudio', {
        'path': path,
        'sampleRate': _sampleRate,
        'maxDurationSeconds': _maxDurationMinutesIOS * 60,
      });

      if (result == null) {
        debugPrint('🎮 ChartGenerator: iOS decoder returned null');
        return (samples: null, failure: null);
      }

      // The decoder sends a typed float32 buffer (arrives as Float32List,
      // no per-sample boxing).
      final rawSamples = result['samples'];
      if (rawSamples is! Float32List) {
        debugPrint('🎮 ChartGenerator: Unexpected samples type: ${rawSamples.runtimeType}');
        return (samples: null, failure: null);
      }

      if (rawSamples.isEmpty) {
        debugPrint('🎮 ChartGenerator: No samples decoded');
        return (samples: null, failure: null);
      }

      debugPrint('🎮 ChartGenerator: Decoded ${rawSamples.length} samples (${(rawSamples.length / _sampleRate).toStringAsFixed(1)}s)');
      return (samples: rawSamples, failure: null);
    } on PlatformException catch (e) {
      debugPrint('🎮 ChartGenerator: iOS decode error: ${e.message}');
      return (
        samples: null,
        failure: e.code == 'TOO_LONG'
            ? 'Track is longer than $_maxDurationMinutesIOS minutes'
            : 'Unsupported or unreadable audio format',
      );
    }
  }
}

/// Production analysis parameters for 44.1kHz mono [samples].
_AudioProcessingParams _productionParams(Float32List samples) => _AudioProcessingParams(
      samples: samples,
      sampleRate: ChartGeneratorService._sampleRate,
      windowSize: ChartGeneratorService._windowSize,
      hopSize: ChartGeneratorService._hopSize,
      maxFilterSize: ChartGeneratorService._maxFilterSize,
      avgFilterPast: ChartGeneratorService._avgFilterPast,
      avgFilterFuture: ChartGeneratorService._avgFilterFuture,
      threshold: ChartGeneratorService._threshold,
      minOnsetGapMs: ChartGeneratorService._minOnsetGapMs,
      maxNotes: ChartGeneratorService._maxNotes,
      subBassMaxFreq: ChartGeneratorService._subBassMaxFreq,
      bassMaxFreq: ChartGeneratorService._bassMaxFreq,
      lowMidMaxFreq: ChartGeneratorService._lowMidMaxFreq,
      highMidMaxFreq: ChartGeneratorService._highMidMaxFreq,
    );

/// Isolate entry point: materialise the transferred samples and analyse them.
_ProcessingResult _processTransferredAudio(TransferableTypedData data) =>
    _processAudioAdvanced(_productionParams(data.materialize().asFloat32List()));

/// Lane for a golden bonus note at [timestampMs]: a random lane with no
/// regular note within [clearanceMs], so the bonus never sits on (or takes a
/// tap meant for) a regular note. If every lane is busy, the lane whose
/// nearest note is furthest away. [notes] must be sorted by time.
@visibleForTesting
int pickBonusLane(
  List<ChartNote> notes,
  int timestampMs,
  Random random, {
  int clearanceMs = 300,
}) {
  // Distance to the nearest regular note per lane (clearanceMs + 1 = none).
  final nearest = List<int>.filled(5, clearanceMs + 1);
  // First note at or after timestampMs - clearanceMs.
  int lo = 0, hi = notes.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (notes[mid].timestampMs < timestampMs - clearanceMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  for (int i = lo; i < notes.length && notes[i].timestampMs <= timestampMs + clearanceMs; i++) {
    final note = notes[i];
    if (note.isBonus) continue;
    final lane = note.lane.clamp(0, 4);
    final d = (note.timestampMs - timestampMs).abs();
    if (d < nearest[lane]) nearest[lane] = d;
  }
  final clear = [for (int l = 0; l < 5; l++) if (nearest[l] > clearanceMs) l];
  if (clear.isNotEmpty) return clear[random.nextInt(clear.length)];
  int best = 0;
  for (int l = 1; l < 5; l++) {
    if (nearest[l] > nearest[best]) best = l;
  }
  return best;
}

/// Parameters for audio processing
class _AudioProcessingParams {
  final Float32List samples;
  final int sampleRate;
  final int windowSize;
  final int hopSize;
  final int maxFilterSize;
  final int avgFilterPast;
  final int avgFilterFuture;
  final double threshold;
  final int minOnsetGapMs;
  final int maxNotes;
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
    required this.maxNotes,
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
    window[i] = 0.5 * (1 - cos(2 * pi * i / (windowSize - 1)));
  }

  // Compute STFT
  final numFrames = (samples.length - windowSize) ~/ hopSize + 1;
  final numBins = windowSize ~/ 2 + 1;
  final binFreq = sampleRate.toDouble() / windowSize;

  // Frame time is the window centre, not its start, so notes aren't early.
  int frameToMs(int frame) =>
      ((frame * hopSize + windowSize / 2) * 1000 / sampleRate).round();

  // Store centroid for each frame (for pitch tracking)
  final spectroids = Float64List(numFrames);

  // Frequency bin boundaries
  final subBassMaxBin = (params.subBassMaxFreq / binFreq).round();
  final bassMaxBin = (params.bassMaxFreq / binFreq).round();
  final lowMidMaxBin = (params.lowMidMaxFreq / binFreq).round();
  final highMidMaxBin = (params.highMidMaxFreq / binFreq).round();

  // SuperFlux only looks back maxFilter frames, so keep a small ring of
  // log-magnitude spectra instead of the whole spectrogram.
  final maxFilter = params.maxFilterSize;
  final ringSize = maxFilter + 1;
  final ring = List.generate(ringSize, (_) => Float64List(numBins));
  final complexBuf = Float64x2List(windowSize);

  final spectralFlux = Float64List(numFrames);
  final bandFlux = List.generate(5, (_) => Float64List(numFrames));

  for (int frame = 0; frame < numFrames; frame++) {
    final start = frame * hopSize;

    // Apply window (reusing one complex buffer, imaginary part zero)
    for (int i = 0; i < windowSize; i++) {
      complexBuf[i] = Float64x2(samples[start + i] * window[i], 0);
    }
    fft.inPlaceFft(complexBuf);

    // Convert to log-magnitude (add small epsilon to avoid log(0))
    final logMags = ring[frame % ringSize];
    double sumMag = 0;
    double sumFreqMag = 0;

    for (int i = 0; i < numBins; i++) {
      final c = complexBuf[i];
      final mag = sqrt(c.x * c.x + c.y * c.y);
      logMags[i] = log(mag + 1e-10);

      // Compute spectral centroid (weighted average frequency)
      sumMag += mag;
      sumFreqMag += i * binFreq * mag;
    }

    // Spectral centroid - the "center of mass" of the spectrum
    // This tells us if the sound is predominantly low or high pitched
    spectroids[frame] = sumMag > 0 ? sumFreqMag / sumMag : 500.0;

    if (frame == 0) continue;

    // SuperFlux-style spectral flux: max filter over previous frames tracks
    // spectral trajectories, making it robust to vibrato and gradual changes.
    // Per-band flux uses the plain previous frame.
    final prev = ring[(frame - 1) % ringSize];
    double flux = 0;
    double subBassF = 0, bassF = 0, lowMidF = 0, highMidF = 0, trebleF = 0;

    for (int bin = 0; bin < numBins; bin++) {
      final curr = logMags[bin];
      double maxPrev = prev[bin];
      for (int m = 2; m <= maxFilter && frame - m >= 0; m++) {
        final older = ring[(frame - m) % ringSize][bin];
        if (older > maxPrev) maxPrev = older;
      }

      // Only count positive differences (energy increases)
      final superDiff = curr - maxPrev;
      if (superDiff > 0) flux += superDiff;

      final diff = curr - prev[bin];
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

    spectralFlux[frame] = flux;
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

  // STEP 1: Estimate the beat period first (before onset detection).
  // The unclamped, sub-frame period drives the snapping grid; the clamped
  // BPM only sets the hit window and the displayed tempo.
  final beatMs = _estimateBeatMsFromFlux(spectralFlux, hopSize, sampleRate);
  final bpm = (60000.0 / beatMs).clamp(70.0, 180.0);
  final beatIntervalMs = beatMs.round();
  final sixteenthMs = beatMs / 4; // 16th note grid

  debugPrint('🎮 Estimated BPM: ${bpm.round()}, beat interval: ${beatMs.toStringAsFixed(1)}ms, 16th: ${sixteenthMs.toStringAsFixed(1)}ms');

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
      final timestampMs = frameToMs(frame);
      final lastTimestampMs = lastOnsetFrame >= 0 ? frameToMs(lastOnsetFrame) : -1000;

      if (timestampMs - lastTimestampMs >= params.minOnsetGapMs) {
        onsetFrames.add(frame);
        lastOnsetFrame = frame;
      }
    }
  }

  debugPrint('🎮 Detected ${onsetFrames.length} raw onsets');

  // Snap onsets to a 16th-note grid fitted locally (per few seconds), and
  // only where the onsets there agree with it: one global grid drifts away
  // from the music within seconds. Moves are capped at about one analysis
  // hop, and no note is placed past the end of the audio.
  final onsetTimes = [for (final f in onsetFrames) frameToMs(f)];
  final snappedTimes = snapToLocalGrid(
    onsetTimes,
    sixteenthMs,
    maxSnapMs: min(12, sixteenthMs ~/ 4),
  );
  final lastMs = samples.length * 1000 ~/ sampleRate;

  // STEP 3: Create notes with beat-quantized timing and pitch-based lanes
  final notes = <ChartNote>[];
  const weights = [3.0, 2.5, 2.0, 1.5, 0.5]; // sub-bass, bass, low-mid, high-mid, treble
  final weightedFluxes = List<double>.filled(5, 0.0);

  for (int i = 0; i < onsetFrames.length; i++) {
    final frame = onsetFrames[i];
    final rawTimestampMs = onsetTimes[i];

    final quantizedMs = min(snappedTimes[i], lastMs);

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
    double maxWeightedFlux = 0;
    int fluxLane = 2; // default to middle
    double totalBandFlux = 0;

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
      final gap = onsetTimes[i + 1] - rawTimestampMs;
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
  }

  // Remove exact duplicates (same timestamp AND lane)
  final uniqueNotes = <ChartNote>[];
  final seenNotes = <int>{};

  for (final note in notes) {
    final key = note.timestampMs * 8 + note.lane;
    if (seenNotes.add(key)) {
      uniqueNotes.add(note);
    }
  }

  // Keep dense/long tracks playable to the end
  final finalNotes = thinNotesEvenly(uniqueNotes, params.maxNotes);

  // Debug: Lane distribution
  final laneCounts = [0, 0, 0, 0, 0];
  for (final note in finalNotes) {
    laneCounts[note.lane]++;
  }
  debugPrint('🎮 Final: ${finalNotes.length} notes (from ${uniqueNotes.length}), lanes: $laneCounts');

  return _ProcessingResult(notes: finalNotes, bpm: bpm);
}

/// Runs the full onset analysis synchronously on 44.1kHz mono [samples] with
/// the production parameters. Returns the notes and estimated BPM.
@visibleForTesting
({List<ChartNote> notes, double bpm}) analyzeSamplesForTesting(Float32List samples) {
  final result = _processAudioAdvanced(_productionParams(samples));
  return (notes: result.notes, bpm: result.bpm);
}

/// Grid offset in [0, gridMs) that best fits [onsetMs], i.e. minimises the
/// total distance from each onset to its nearest grid line.
@visibleForTesting
int estimateGridPhaseMs(List<int> onsetMs, int gridMs) {
  if (gridMs <= 1 || onsetMs.isEmpty) return 0;
  int bestPhase = 0;
  double bestCost = double.infinity;
  for (int phase = 0; phase < gridMs; phase++) {
    double cost = 0;
    for (final t in onsetMs) {
      final r = (t - phase) % gridMs; // Dart % is non-negative for positive divisor
      cost += r < gridMs - r ? r : gridMs - r;
    }
    if (cost < bestCost) {
      bestCost = cost;
      bestPhase = phase;
    }
  }
  return bestPhase;
}

/// Snap [ms] to the nearest line of a [gridMs] grid offset by [phaseMs].
/// If that line is more than [maxSnapMs] away, [ms] is returned unchanged.
@visibleForTesting
int quantizeToGrid(int ms, int gridMs, int phaseMs, {int? maxSnapMs}) {
  if (gridMs <= 0) return ms;
  final steps = ((ms - phaseMs) / gridMs).round();
  final snapped = max(0, phaseMs + steps * gridMs);
  if (maxSnapMs != null && (snapped - ms).abs() > maxSnapMs) return ms;
  return snapped;
}

/// Snap [onsetMs] (sorted) to a 16th-note grid fitted per [segmentMs]
/// stretch of onsets, so tempo drift and small errors in the estimated
/// period ([gridMs]) never carry across the song.
///
/// Per stretch: the phase that best fits [gridMs] assigns each onset a grid
/// line, then a least-squares line through (grid line, onset time) gives the
/// local period and offset, so an estimated period that is slightly off
/// doesn't pull notes away from the beat. A stretch is snapped only when it
/// has at least [minOnsets] onsets, its local period is within 3% of
/// [gridMs] and the onsets sit close to its grid (mean distance at most 1/8
/// of the grid; onsets unrelated to the grid average 1/4). Each onset moves
/// at most [maxSnapMs]. Everything else is returned unchanged.
@visibleForTesting
List<int> snapToLocalGrid(
  List<int> onsetMs,
  double gridMs, {
  int segmentMs = 4000,
  int maxSnapMs = 12,
  int minOnsets = 4,
}) {
  final result = List<int>.of(onsetMs);
  if (gridMs <= 1 || onsetMs.isEmpty || maxSnapMs <= 0) return result;

  double distance(int t, double phase) {
    final r = (t - phase) % gridMs; // non-negative for a positive divisor
    return r < gridMs - r ? r : gridMs - r;
  }

  int start = 0;
  while (start < onsetMs.length) {
    final segmentEnd = onsetMs[start] + segmentMs;
    int end = start;
    while (end < onsetMs.length && onsetMs[end] < segmentEnd) {
      end++;
    }
    final count = end - start;
    if (count >= minOnsets) {
      double bestPhase = 0;
      double bestCost = double.infinity;
      for (double phase = 0; phase < gridMs; phase += 1) {
        double cost = 0;
        for (int i = start; i < end; i++) {
          cost += distance(onsetMs[i], phase);
        }
        if (cost < bestCost) {
          bestCost = cost;
          bestPhase = phase;
        }
      }
      // Local grid: least squares through (grid line index, onset time).
      final steps = [
        for (int i = start; i < end; i++) ((onsetMs[i] - bestPhase) / gridMs).round(),
      ];
      double meanK = 0, meanT = 0;
      for (int j = 0; j < count; j++) {
        meanK += steps[j];
        meanT += onsetMs[start + j];
      }
      meanK /= count;
      meanT /= count;
      double covKT = 0, varK = 0;
      for (int j = 0; j < count; j++) {
        final dk = steps[j] - meanK;
        covKT += dk * (onsetMs[start + j] - meanT);
        varK += dk * dk;
      }
      if (varK > 0) {
        final period = covKT / varK;
        final offset = meanT - period * meanK;
        if ((period - gridMs).abs() <= gridMs * 0.03) {
          double residual = 0;
          for (int j = 0; j < count; j++) {
            residual += (onsetMs[start + j] - (offset + period * steps[j])).abs();
          }
          if (residual / count <= gridMs / 8) {
            for (int j = 0; j < count; j++) {
              final t = onsetMs[start + j];
              final snapped = (offset + period * steps[j]).round();
              if (snapped >= 0 && (snapped - t).abs() <= maxSnapMs) {
                result[start + j] = snapped;
              }
            }
          }
        }
      }
    }
    start = end;
  }
  return result;
}

/// Reduce [notes] (sorted by time) to at most [maxNotes], spread evenly over
/// the whole song instead of cutting the end off. Chord partners are dropped
/// first; if that isn't enough, whole onsets are sampled evenly.
@visibleForTesting
List<ChartNote> thinNotesEvenly(List<ChartNote> notes, int maxNotes) {
  if (notes.length <= maxNotes) return notes;

  // Group notes that share a timestamp (chords); first note is the primary.
  final groups = <List<ChartNote>>[];
  for (final note in notes) {
    if (groups.isNotEmpty && groups.last.first.timestampMs == note.timestampMs) {
      groups.last.add(note);
    } else {
      groups.add([note]);
    }
  }

  // Drop chord partners, as evenly as possible, until we fit.
  final chordGroups = [for (int g = 0; g < groups.length; g++) if (groups[g].length > 1) g];
  var excess = notes.length - maxNotes;
  final keepChord = List<bool>.filled(groups.length, true);
  if (excess > 0 && chordGroups.isNotEmpty) {
    final toDrop = min(excess, chordGroups.length);
    final step = chordGroups.length / toDrop;
    for (int k = 0; k < toDrop; k++) {
      keepChord[chordGroups[(k * step).floor()]] = false;
    }
    excess -= toDrop;
  }

  List<ChartNote> flatten(Iterable<int> groupIndices) => [
        for (final g in groupIndices)
          ...(keepChord[g] ? groups[g] : [groups[g].first]),
      ];

  if (excess <= 0) return flatten(List.generate(groups.length, (g) => g));

  // Still too many single-note onsets: keep an evenly spaced subset.
  final step = groups.length / maxNotes;
  final kept = <int>{for (int k = 0; k < maxNotes; k++) (k * step).floor()};
  return [
    for (final g in kept.toList()..sort()) groups[g].first,
  ];
}

/// Beat period in ms estimated from spectral flux by autocorrelation, refined
/// between analysis frames by fitting a parabola around the best lag (a
/// whole-frame lag is up to 5ms off per beat, which a grid accumulates).
double _estimateBeatMsFromFlux(Float64List flux, int hopSize, int sampleRate) {
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
  final corrs = Float64List(maxLag + 1);

  for (int lag = minLag; lag <= maxLag; lag++) {
    double corr = 0;
    int count = 0;

    for (int i = 0; i < normalizedFlux.length - lag; i++) {
      corr += normalizedFlux[i] * normalizedFlux[i + lag];
      count++;
    }

    if (count > 0) {
      corr /= count;
      corrs[lag] = corr;
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }
  }

  // Sub-frame refinement: vertex of the parabola through the peak and its
  // neighbours (only for a real interior peak).
  double lag = bestLag.toDouble();
  if (bestCorr > 0 && bestLag > minLag && bestLag < maxLag) {
    final a = corrs[bestLag - 1];
    final b = corrs[bestLag];
    final c = corrs[bestLag + 1];
    final denom = a - 2 * b + c;
    if (denom < 0) {
      final delta = 0.5 * (a - c) / denom;
      if (delta.abs() <= 0.5) lag += delta;
    }
  }

  return lag * hopSize * 1000.0 / sampleRate;
}
