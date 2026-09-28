import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/equalizer_presets.dart';

void main() {
  test('every preset has one gain per band within range', () {
    for (final p in EqualizerPreset.values) {
      expect(p.gains, hasLength(kEqualizerBands.length), reason: p.label);
      for (final g in p.gains) {
        expect(g.abs(), lessThanOrEqualTo(kEqualizerMaxGainDb), reason: p.label);
      }
    }
  });

  test('preamp cancels the largest boost and never boosts', () {
    expect(equalizerPreampDb(EqualizerPreset.bassBoost.gains), -6);
    expect(equalizerPreampDb(EqualizerPreset.lateNight.gains), -2);
    expect(equalizerPreampDb([-3, -1, 0]), 0);
  });

  test('matching finds presets and falls back to custom', () {
    expect(EqualizerPreset.matching(EqualizerPreset.rock.gains), EqualizerPreset.rock);
    expect(EqualizerPreset.matching([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), EqualizerPreset.custom);
  });

  test('normalize clamps and pads', () {
    final g = normalizeEqualizerGains([20, -20]);
    expect(g, hasLength(10));
    expect(g.first, 12);
    expect(g[1], -12);
    expect(g.last, 0);
  });

  test('band labels', () {
    expect(equalizerBandLabel(62), '62');
    expect(equalizerBandLabel(16000), '16k');
  });
}
