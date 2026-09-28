import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/search_ranking.dart';

void main() {
  test('match scores', () {
    expect(searchMatchScore('Radiohead', 'radiohead'), 4);
    expect(searchMatchScore('Radiohead', 'radio'), 3);
    expect(searchMatchScore('OK Computer', 'comp'), 2);
    expect(searchMatchScore('Everything In Its Right Place', 'ing'), 1);
    expect(searchMatchScore('Kid A', 'zzz'), 0);
  });

  test('exact artist beats a track that merely contains the query', () {
    final top = topSearchResult('Air', [
      const SearchCandidate(SearchKind.track, 'Hot Air Balloon', 't'),
      const SearchCandidate(SearchKind.album, 'Airbag', 'al'),
      const SearchCandidate(SearchKind.artist, 'Air', 'ar'),
    ]);
    expect(top?.item, 'ar');
  });

  test('ties prefer artists, then albums, then tracks', () {
    final top = topSearchResult('Blue', [
      const SearchCandidate(SearchKind.track, 'Blue', 't'),
      const SearchCandidate(SearchKind.album, 'Blue', 'al'),
    ]);
    expect(top?.item, 'al');
  });

  test('no name match means no top result', () {
    expect(
      topSearchResult('xyz', [const SearchCandidate(SearchKind.track, 'Abc', 't')]),
      isNull,
    );
  });
}
