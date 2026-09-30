import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/data/healing_frequencies.dart';

void main() {
  group('kHealingCategories', () {
    final all = [for (final c in kHealingCategories) ...c.frequencies];

    test('every tone that is played is synthesizable and audible', () {
      for (final f in all) {
        expect(f.playbackHz, inInclusiveRange(20, 20000), reason: f.name);
      }
    });

    test('inaudible entries carry an audible octave of the real frequency', () {
      for (final f in all.where((f) => f.isInaudible)) {
        final octave = f.audibleOctaveHz;
        expect(octave, isNotNull, reason: f.name);
        // A power of two times the real frequency: the same note some
        // octaves up.
        var r = octave! / f.hz;
        expect(r, greaterThan(1), reason: f.name);
        while (r > 1.0001) {
          r /= 2;
        }
        expect(r, closeTo(1.0, 1e-3), reason: f.name);
      }
    });

    test('Schumann resonance is 7.83 Hz, played six octaves up', () {
      final schumann =
          kHealingCategories.firstWhere((c) => c.name == 'Schumann').frequencies.single;
      expect(schumann.hz, 7.83);
      expect(schumann.playbackHz, closeTo(7.83 * 64, 1e-9));
    });

    test('Solfeggio syllables follow the traditional mapping', () {
      final solfeggio = {
        for (final f
            in kHealingCategories.firstWhere((c) => c.name == 'Solfeggio').frequencies)
          f.name: f.hz,
      };
      expect(solfeggio['UT'], 396);
      expect(solfeggio['RE'], 417);
      expect(solfeggio['MI'], 528);
      expect(solfeggio['FA'], 639);
      expect(solfeggio['SOL'], 741);
      expect(solfeggio['LA'], 852);
      expect(solfeggio['SI'], 963);
      expect(solfeggio['174'], 174);
      expect(solfeggio['285'], 285);
    });
  });
}
