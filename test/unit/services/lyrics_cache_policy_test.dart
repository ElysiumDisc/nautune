import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/lyrics_service.dart';

void main() {
  test('"no lyrics" is cached only when every source said so', () {
    expect(canCacheNoLyrics(const [
      LyricsLookup.notFound,
      LyricsLookup.notFound,
      LyricsLookup.notFound,
    ]), isTrue);
    expect(canCacheNoLyrics(const [
      LyricsLookup.notFound,
      LyricsLookup.error, // e.g. LRCLIB unreachable
      LyricsLookup.notFound,
    ]), isFalse);
    expect(canCacheNoLyrics(const [LyricsLookup.error]), isFalse);
  });

  group('parseLrcLyrics', () {
    int ms(int m, int s, [int millis = 0]) => ((m * 60 + s) * 1000 + millis) * 10000;

    test('parses centiseconds, milliseconds and no fraction', () {
      final lines = parseLrcLyrics('[00:01.50]A\n[00:02.250]B\n[00:03]C');
      expect(lines.map((l) => l.text), ['A', 'B', 'C']);
      expect(lines.map((l) => l.startTicks), [ms(0, 1, 500), ms(0, 2, 250), ms(0, 3)]);
    });

    test('lines with several timestamps repeat, sorted by time', () {
      final lines = parseLrcLyrics('[00:10.00][01:10.00]Chorus\n[00:20.00]Verse');
      expect(lines.map((l) => l.text), ['Chorus', 'Verse', 'Chorus']);
      expect(lines.last.startTicks, ms(1, 10));
    });

    test('keeps empty timed lines (breaks) but not leading ones or metadata', () {
      final lines =
          parseLrcLyrics('[ar:Someone]\n[00:00.00]\n[00:05.00]Hi\n[00:09.00] \n[00:12.00]Bye');
      expect(lines.map((l) => l.text), ['Hi', '', 'Bye']);
    });

    test('three-digit minutes', () {
      expect(parseLrcLyrics('[100:00.00]Late').single.startTicks, ms(100, 0));
    });

    test('nothing but empty lines is no lyrics', () {
      expect(parseLrcLyrics('[00:01.00]\n[00:02.00] '), isEmpty);
    });
  });
}
