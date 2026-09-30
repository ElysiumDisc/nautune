import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_library.dart';
import 'package:nautune/jellyfin/jellyfin_playlist.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';

JellyfinTrack _track({String? token = 'tok', List<String> artists = const ['A']}) =>
    JellyfinTrack(
      id: 'id1',
      name: 'Song',
      album: 'Album',
      artists: artists,
      serverUrl: 'https://host/jf',
      token: token,
      userId: 'u1',
      primaryImageTag: 'tag',
      providerIds: const {'MusicBrainzTrack': 'mbid'},
    );

void main() {
  tearDown(() => JellyfinTrack.sessionTokenResolver = null);

  group('scrobbleArtist', () {
    test('joins every artist instead of the UI abbreviation', () {
      final t = _track(artists: const ['Daft Punk', 'Pharrell Williams']);
      expect(t.displayArtist, 'Daft Punk & 1 more');
      expect(t.scrobbleArtist, 'Daft Punk, Pharrell Williams');
    });

    test('single artist, empty and placeholder credits', () {
      expect(JellyfinTrack.scrobbleArtistFor(const ['Björk']), 'Björk');
      expect(JellyfinTrack.scrobbleArtistFor(const []), isNull);
      expect(JellyfinTrack.scrobbleArtistFor(const ['  ']), isNull);
      expect(JellyfinTrack.scrobbleArtistFor(const ['Unknown Artist']), isNull);
    });

    test('repairs a credit persisted from displayArtist', () {
      expect(JellyfinTrack.scrobbleArtistFor(const ['Daft Punk & 2 more']),
          'Daft Punk');
    });

    test('Last.fm gets the primary artist only', () {
      final t = _track(artists: const ['Daft Punk', 'Pharrell Williams']);
      expect(t.lastFmArtist, 'Daft Punk');
      expect(JellyfinTrack.lastFmArtistFor(const ['  ', 'Björk']), 'Björk');
      expect(JellyfinTrack.lastFmArtistFor(const ['Daft Punk & 1 more']),
          'Daft Punk');
      expect(JellyfinTrack.lastFmArtistFor(const []), isNull);
    });
  });

  group('storage JSON', () {
    test('never persists the access token', () {
      final json = _track().toStorageJson();
      expect(json.containsKey('token'), isFalse);
      expect(json.values.whereType<String>(), isNot(contains('tok')));
    });

    test('restored tracks resolve the active session token lazily', () {
      final restored = JellyfinTrack.fromStorageJson(_track().toStorageJson());
      expect(restored.token, isNull);
      expect(restored.artworkUrl(), isNull);

      // Session becomes available after the queue was restored.
      JellyfinTrack.sessionTokenResolver = (server, user) =>
          server == 'https://host/jf' && user == 'u1' ? 'fresh' : null;
      expect(restored.token, 'fresh');
      expect(Uri.parse(restored.artworkUrl()!).queryParameters['ApiKey'], 'fresh');
      expect(
        restored.originalQualityStreamUrl(deviceId: 'd'),
        contains('ApiKey=fresh'),
      );
    });

    test('resolver does not hand out tokens for another server/user', () {
      JellyfinTrack.sessionTokenResolver = (server, user) =>
          server == 'https://other' ? 'x' : null;
      final restored = JellyfinTrack.fromStorageJson(_track().toStorageJson());
      expect(restored.token, isNull);
    });

    test('legacy records that still contain a token keep working', () {
      final legacy = {..._track().toStorageJson(), 'token': 'old'};
      expect(JellyfinTrack.fromStorageJson(legacy).token, 'old');
    });

    test('provider ids survive the round trip (ListenBrainz MBIDs)', () {
      final restored = JellyfinTrack.fromStorageJson(_track().toStorageJson());
      expect(restored.providerIds, {'MusicBrainzTrack': 'mbid'});
    });

    test('copyWith keeps a restored track lazy', () {
      final restored = JellyfinTrack.fromStorageJson(_track().toStorageJson())
          .copyWith(isFavorite: true);
      JellyfinTrack.sessionTokenResolver = (_, _) => 'late';
      expect(restored.token, 'late');
    });
  });

  group('Hive-restored nested maps (Map<dynamic, dynamic>)', () {
    test('playlist image tag', () {
      final json = <String, dynamic>{
        'Id': 'p',
        'Name': 'P',
        'ChildCount': 3,
        'ImageTags': <dynamic, dynamic>{'Primary': 'tag'},
      };
      final p = JellyfinPlaylist.fromJson(json);
      expect(p.primaryImageTag, 'tag');
      expect(p.trackCount, 3);
    });

    test('library image tag', () {
      final lib = JellyfinLibrary.fromJson(<String, dynamic>{
        'Id': 'l',
        'Name': 'Music',
        'CollectionType': 'music',
        'ImageTags': <dynamic, dynamic>{'Primary': 'tag'},
      });
      expect(lib.imageTag, 'tag');
    });
  });
}
