import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/easter_egg_keywords.dart';

void main() {
  group('matchEasterEgg', () {
    test('matches exact keywords', () {
      expect(matchEasterEgg('fire'), EasterEgg.fretsOnFire);
      expect(matchEasterEgg('frets on fire'), EasterEgg.fretsOnFire);
      expect(matchEasterEgg('relax'), EasterEgg.relaxMode);
      expect(matchEasterEgg('network'), EasterEgg.network);
      expect(matchEasterEgg('essential mix'), EasterEgg.essentialMix);
      expect(matchEasterEgg('hz'), EasterEgg.healingFrequencies);
      expect(matchEasterEgg('solfeggio'), EasterEgg.healingFrequencies);
    });

    test('is case-insensitive and ignores surrounding/extra whitespace', () {
      expect(matchEasterEgg(' PIANO '), EasterEgg.piano);
      expect(matchEasterEgg('Frets   On  Fire'), EasterEgg.fretsOnFire);
      expect(matchEasterEgg('\tHealing\n'), EasterEgg.healingFrequencies);
    });

    test('does not match keywords embedded in a longer query', () {
      expect(matchEasterEgg('Arcade Fire'), isNull);
      expect(matchEasterEgg('432hz'), isNull);
      expect(matchEasterEgg('Piano Man'), isNull);
      expect(matchEasterEgg('relaxing'), isNull);
      expect(matchEasterEgg('Social Network'), isNull);
    });

    test('returns null for empty or unrelated queries', () {
      expect(matchEasterEgg(''), isNull);
      expect(matchEasterEgg('   '), isNull);
      expect(matchEasterEgg('radiohead'), isNull);
    });
  });
}
