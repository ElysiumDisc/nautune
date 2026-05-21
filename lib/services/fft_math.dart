import 'dart:math' as math;

/// RMS (root-mean-square) average of a sub-range of a magnitude/spectrum list.
///
/// Used by the visualizer FFT services to collapse a frequency band (e.g.
/// bass = bins 0..40) into a single scalar. Pure function — exposed at
/// library level so it can be unit tested without spinning up the audio
/// subsystem.
///
/// `start` is inclusive, `end` is exclusive. Out-of-range indices are clamped.
/// Returns 0.0 for empty / inverted ranges.
double rmsAverageRange(List<double> data, int start, int end) {
  if (data.isEmpty || start >= end) return 0.0;
  final s = start.clamp(0, data.length);
  final e = end.clamp(s, data.length);
  if (s >= e) return 0.0;

  var sumSq = 0.0;
  for (var i = s; i < e; i++) {
    final v = data[i];
    sumSq += v * v;
  }
  return math.sqrt(sumSq / (e - s));
}
