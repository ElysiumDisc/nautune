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
}
