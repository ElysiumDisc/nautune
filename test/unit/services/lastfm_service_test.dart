import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/lastfm_service.dart';

void main() {
  test('signature: sorted name+value pairs plus secret, format excluded', () {
    final params = {
      'method': 'track.scrobble',
      'api_key': 'KEY',
      'sk': 'SK',
      'artist[0]': 'Björk',
      'track[0]': 'Jóga',
      'timestamp[0]': '100',
    };
    const expected = '0af04046d090e1d57c7c72861aa5bf5f';
    expect(lastFmSignature(params, 'SECRET'), expected);
    expect(lastFmSignature({...params, 'format': 'json'}, 'SECRET'), expected);
  });

  test('batch scrobble parameters are indexed and skip empty fields', () {
    final params = lastFmScrobbleParams(const [
      LastFmScrobble(artist: 'A', track: 'One', timestamp: 10, album: 'X', durationSeconds: 200),
      LastFmScrobble(artist: 'B', track: 'Two', timestamp: 20),
    ]);
    expect(params, {
      'artist[0]': 'A',
      'track[0]': 'One',
      'timestamp[0]': '10',
      'album[0]': 'X',
      'duration[0]': '200',
      'artist[1]': 'B',
      'track[1]': 'Two',
      'timestamp[1]': '20',
    });
  });

  test('queued scrobbles round-trip through JSON', () {
    const s = LastFmScrobble(artist: 'A', track: 'T', timestamp: 5, album: 'L', durationSeconds: 9);
    final back = LastFmScrobble.fromJson(s.toJson())!;
    expect(back.toJson(), s.toJson());
    expect(LastFmScrobble.fromJson({'artist': 'A'}), isNull);
  });
}
