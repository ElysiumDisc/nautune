/// Equalizer bands, presets and the anti-clipping preamp. Pure, so it can
/// be unit-tested; the DSP runs natively (ios/Runner/AudioEffectsPlugin).
library;

/// Band centre frequencies in Hz (must match the native plugin).
const List<int> kEqualizerBands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// Gain range per band, in dB.
const double kEqualizerMaxGainDb = 12;

String equalizerBandLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

enum EqualizerPreset {
  flat('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  bassBoost('Bass Boost', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  trebleBoost('Treble Boost', [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
  vocal('Vocal', [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
  rock('Rock', [5, 4, 2, -1, -2, -1, 2, 4, 5, 5]),
  electronic('Electronic', [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
  acoustic('Acoustic', [3, 3, 2, 1, 2, 2, 3, 3, 2, 1]),
  lateNight('Late Night', [-2, -1, 0, 1, 2, 2, 1, 0, -2, -4]),
  custom('Custom', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

  const EqualizerPreset(this.label, this.gains);
  final String label;
  final List<double> gains;

  static EqualizerPreset fromName(String? name) => EqualizerPreset.values
      .firstWhere((p) => p.name == name, orElse: () => EqualizerPreset.flat);

  /// The preset whose gains equal [gains], else [custom].
  static EqualizerPreset matching(List<double> gains) {
    for (final p in EqualizerPreset.values) {
      if (p == custom) continue;
      var same = true;
      for (var i = 0; i < kEqualizerBands.length; i++) {
        if ((p.gains[i] - (i < gains.length ? gains[i] : 0)).abs() > 0.05) {
          same = false;
          break;
        }
      }
      if (same) return p;
    }
    return custom;
  }
}

/// Preamp (dB, <= 0) that cancels the largest boost, so no band can push
/// the signal past full scale.
double equalizerPreampDb(List<double> gains) {
  var maxBoost = 0.0;
  for (final g in gains) {
    if (g > maxBoost) maxBoost = g;
  }
  return -maxBoost;
}

/// [gains] clamped to the allowed range and padded/truncated to one value
/// per band.
List<double> normalizeEqualizerGains(List<double> gains) => [
      for (var i = 0; i < kEqualizerBands.length; i++)
        (i < gains.length ? gains[i] : 0.0).clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb),
    ];
