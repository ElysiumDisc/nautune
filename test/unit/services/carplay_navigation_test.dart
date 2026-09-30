import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/carplay_service.dart';

void main() {
  group('CarPlayNavGate', () {
    test('an action may push while its page is on top and nothing else happened', () {
      final gate = CarPlayNavGate();
      final page = Object();
      final origin = gate.begin(page);
      expect(gate.isCurrent(origin, page), isTrue);
    });

    test('going back (another page on top) blocks the push', () {
      final gate = CarPlayNavGate();
      final page = Object();
      final origin = gate.begin(page);
      expect(gate.isCurrent(origin, Object()), isFalse);
    });

    test('a later tap supersedes an earlier in-flight action', () {
      final gate = CarPlayNavGate();
      final page = Object();
      final first = gate.begin(page);
      final second = gate.begin(page);
      expect(gate.isCurrent(first, page), isFalse);
      expect(gate.isCurrent(second, page), isTrue);
    });

    test('invalidate (Now Playing, account/offline switch, disconnect) drops in-flight actions', () {
      final gate = CarPlayNavGate();
      final page = Object();
      final origin = gate.begin(page);
      gate.invalidate();
      expect(gate.isCurrent(origin, page), isFalse);
      // A tap after the event works again.
      expect(gate.isCurrent(gate.begin(page), page), isTrue);
    });

    test('no origin means no restriction', () {
      final gate = CarPlayNavGate()..invalidate();
      expect(gate.isCurrent(null, Object()), isTrue);
    });
  });

  group('A–Z letters', () {
    test('letterFilter asks the server for lowercase sort-name prefixes', () {
      final a = CarPlayService.letterFilter('A');
      expect(a.nameStartsWith, 'a');
      expect(a.nameLessThan, isNull);
      final z = CarPlayService.letterFilter('Z');
      expect(z.nameStartsWith, 'z');
    });

    test('"#" is everything sorting before "a"', () {
      final hash = CarPlayService.letterFilter('#');
      expect(hash.nameStartsWith, isNull);
      expect(hash.nameLessThan, 'a');
    });

    test('letterOf buckets local names', () {
      expect(CarPlayService.letterOf('abba'), 'A');
      expect(CarPlayService.letterOf('Zappa'), 'Z');
      expect(CarPlayService.letterOf('2Pac'), '#');
      expect(CarPlayService.letterOf(''), '#');
      expect(CarPlayService.letterOf('Édith Piaf'), '#');
    });
  });
}
