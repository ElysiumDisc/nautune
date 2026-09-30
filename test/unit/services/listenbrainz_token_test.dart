import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/listenbrainz_service.dart';

void main() {
  test('valid token reports the account user_name', () {
    final c = ListenBrainzService.parseTokenCheck(
        200, '{"code":200,"message":"Token valid.","valid":true,"user_name":"rob"}');
    expect(c.status, ListenBrainzTokenStatus.valid);
    expect(c.userName, 'rob');
  });

  test('invalid token vs network/server problems', () {
    expect(
      ListenBrainzService.parseTokenCheck(200, '{"valid":false}').status,
      ListenBrainzTokenStatus.invalid,
    );
    expect(ListenBrainzService.parseTokenCheck(401, '').status,
        ListenBrainzTokenStatus.invalid);
    expect(ListenBrainzService.parseTokenCheck(503, '').status,
        ListenBrainzTokenStatus.networkError);
    expect(ListenBrainzService.parseTokenCheck(429, '').status,
        ListenBrainzTokenStatus.networkError);
    expect(ListenBrainzService.parseTokenCheck(200, '<html>').status,
        ListenBrainzTokenStatus.networkError);
  });

  group('MusicBrainz ids in listens', () {
    const a = '0383dadf-2a4e-4d10-a46a-e9e041da8eb3';
    const b = 'b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d';

    test('a release track id is never sent as the recording id', () {
      final info = ListenBrainzService.musicBrainzInfo({'MusicBrainzTrack': a});
      expect(info.containsKey('recording_mbid'), isFalse);
      expect(info['track_mbid'], a);
    });

    test('recording, release and release group go to their own fields', () {
      final info = ListenBrainzService.musicBrainzInfo({
        'MusicBrainzRecording': a,
        'MusicBrainzAlbum': b,
        'MusicBrainzReleaseGroup': a,
      });
      expect(info['recording_mbid'], a);
      expect(info['release_mbid'], b);
      expect(info['release_group_mbid'], a);
    });

    test('joined artist ids are split and invalid ones dropped', () {
      final info = ListenBrainzService.musicBrainzInfo(
          {'MusicBrainzArtist': '$a/${b.toUpperCase()}; not-an-id'});
      expect(info['artist_mbids'], [a, b]);
      expect(ListenBrainzService.musicBrainzInfo({'MusicBrainzAlbum': 'x'}),
          isEmpty);
      expect(ListenBrainzService.musicBrainzInfo(null), isEmpty);
    });
  });
}
