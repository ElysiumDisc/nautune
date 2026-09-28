import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/letter_index.dart';

void main() {
  group('indexLetterFor', () {
    test('letters, accents, digits and symbols', () {
      expect(indexLetterFor('abba'), 'A');
      expect(indexLetterFor('Émilie'), 'E');
      expect(indexLetterFor('ñu'), 'N');
      expect(indexLetterFor('2Pac'), '#');
      expect(indexLetterFor('!!!'), '#');
      expect(indexLetterFor('坂本龍一'), '#');
      expect(indexLetterFor('  Zed'), 'Z');
      expect(indexLetterFor(''), '#');
    });
  });

  group('sectionsByLetter', () {
    final names = ['Beta', '10cc', 'alpha', 'Bravo', 'Échos'];

    test('ascending puts # first and keeps item order', () {
      final s = sectionsByLetter(names, (n) => n, ascending: true);
      expect(s.map((e) => e.letter), ['#', 'A', 'B', 'E']);
      expect(s[2].items, ['Beta', 'Bravo']);
    });

    test('descending puts # last', () {
      final s = sectionsByLetter(names, (n) => n, ascending: false);
      expect(s.map((e) => e.letter), ['E', 'B', 'A', '#']);
    });
  });

  group('sectionOffsets', () {
    test('grid rows count spacing between rows only', () {
      const g = SectionGeometry(
        headerExtent: 32,
        itemExtent: 200,
        columns: 2,
        rowSpacing: 16,
        paddingTop: 4,
        paddingBottom: 12,
      );
      // 3 items -> 2 rows: 32 + 4 + 200 + 16 + 200 + 12
      expect(g.extentFor(3), 464);
      final sections = [
        const LetterSection('A', [1, 2, 3]),
        const LetterSection('B', [4]),
        const LetterSection('C', [5]),
      ];
      final o = sectionOffsets(sections, g, leading: 8);
      expect(o['A'], 8);
      expect(o['B'], 8 + 464);
      expect(o['C'], 8 + 464 + (32 + 4 + 200 + 12));
    });

    test('list sections are header plus fixed-extent rows', () {
      const g = SectionGeometry(headerExtent: 32, itemExtent: 72);
      final o = sectionOffsets([
        const LetterSection('A', [1, 2]),
        const LetterSection('B', [3]),
      ], g);
      expect(o['B'], 32 + 144);
    });
  });

  group('resolveIndexLetter', () {
    test('exact, next in direction, or last', () {
      expect(resolveIndexLetter('C', ['A', 'C'], ascending: true), 'C');
      expect(resolveIndexLetter('B', ['A', 'C'], ascending: true), 'C');
      expect(resolveIndexLetter('Z', ['A', 'C'], ascending: true), 'C');
      expect(resolveIndexLetter('B', ['C', 'A'], ascending: false), 'A');
      expect(resolveIndexLetter('#', ['A'], ascending: true), 'A');
      expect(resolveIndexLetter('A', [], ascending: true), isNull);
    });
  });

  group('letterBeyondLoaded', () {
    test('only letters past the last loaded section need more pages', () {
      expect(letterBeyondLoaded('M', ['A', 'B'], ascending: true), isTrue);
      expect(letterBeyondLoaded('A', ['#', 'B'], ascending: true), isFalse);
      expect(letterBeyondLoaded('B', ['A', 'B'], ascending: true), isFalse);
      expect(letterBeyondLoaded('A', ['Z', 'M'], ascending: false), isTrue);
    });
  });
}
