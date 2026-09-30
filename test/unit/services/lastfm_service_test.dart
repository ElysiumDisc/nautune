import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
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

  group('queue flushing', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => Hive.init(
        Directory.systemTemp.createTempSync('lastfm_test').path));
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    const s1 = LastFmScrobble(artist: 'A', track: 'One', timestamp: 1);
    const s2 = LastFmScrobble(artist: 'B', track: 'Two', timestamp: 2);

    test('disconnect during an in-flight flush neither throws nor eats the '
        'new account\'s queue', () async {
      final service = LastFmService.instance;
      final gate = Completer<void>();
      service.httpClient = MockClient((_) async {
        await gate.future;
        return http.Response('{"scrobbles":{}}', 200);
      });
      service.debugConfigure(
          apiKey: 'k', secret: 's', sessionKey: 'sk', pending: const [s1]);
      final flushing = service.flush();
      await service.disconnect();
      // A new account connects and queues a play before the old batch ends.
      service.debugConfigure(
          apiKey: 'k2', secret: 's2', sessionKey: 'sk2', pending: const [s2]);
      gate.complete();
      await flushing; // must not throw a RangeError
      expect(service.pendingCount, greaterThanOrEqualTo(1));
    });

    test('an invalid-parameters error isolates and drops only the bad play',
        () async {
      final service = LastFmService.instance;
      final sent = <String>[];
      service.httpClient = MockClient((request) async {
        final body = Uri.splitQueryString(request.body);
        if (body['track[0]'] == 'Bad' || body['track[1]'] == 'Bad') {
          return http.Response('{"error":6,"message":"Invalid parameters"}', 200);
        }
        sent.add(body['track[0]']!);
        return http.Response('{"scrobbles":{}}', 200);
      });
      service.debugConfigure(apiKey: 'k', secret: 's', sessionKey: 'sk', pending: const [
        LastFmScrobble(artist: 'A', track: 'Good1', timestamp: 1),
        LastFmScrobble(artist: 'A', track: 'Bad', timestamp: 2),
        LastFmScrobble(artist: 'A', track: 'Good2', timestamp: 3),
      ]);
      await service.flush();
      expect(sent, ['Good1', 'Good2']);
      expect(service.pendingCount, 0);
    });

    test('plays without a usable artist are not queued', () async {
      final service = LastFmService.instance;
      service.httpClient = MockClient((_) async => http.Response('{}', 200));
      service.debugConfigure(apiKey: 'k', secret: 's', sessionKey: 'sk');
      await service.scrobble(
        JellyfinTrack(id: 't', name: 'T', album: null, artists: const []),
        DateTime(2026),
      );
      expect(service.pendingCount, 0);
    });
  });

  group('scrobble rules and queue limits', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => Hive.init(
        Directory.systemTemp.createTempSync('lastfm_rules_test').path));
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    JellyfinTrack track(String name, {int seconds = 200, List<String>? artists}) =>
        JellyfinTrack(
          id: name,
          name: name,
          album: null,
          artists: artists ?? const ['A'],
          runTimeTicks: seconds * 10000000,
        );

    test('tracks of 30 seconds or less are not scrobbled', () async {
      final service = LastFmService.instance;
      service.httpClient = MockClient((_) async => http.Response('{}', 200));
      service.debugConfigure(apiKey: 'k', secret: 's', sessionKey: 'sk');
      final gate = Completer<void>();
      service.httpClient = MockClient((_) async {
        await gate.future;
        return http.Response('{}', 200);
      });
      unawaited(service.scrobble(track('Short', seconds: 30), DateTime(2026)));
      expect(service.pendingCount, 0);
      unawaited(service.scrobble(track('Long', seconds: 31), DateTime(2026)));
      await Future<void>.delayed(Duration.zero);
      expect(service.pendingCount, 1);
      gate.complete();
      await service.flush();
    });

    test('scrobbles under the primary artist', () async {
      final service = LastFmService.instance;
      final artists = <String?>[];
      service.httpClient = MockClient((request) async {
        artists.add(Uri.splitQueryString(request.body)['artist[0]']);
        return http.Response('{}', 200);
      });
      service.debugConfigure(apiKey: 'k', secret: 's', sessionKey: 'sk');
      await service.scrobble(
          track('Get Lucky', artists: const ['Daft Punk', 'Pharrell Williams']),
          DateTime(2026));
      expect(artists, ['Daft Punk']);
    });

    test('trimming a full queue during a send loses no unsent play', () async {
      final service = LastFmService.instance;
      final sent = <String>[];
      final gate = Completer<void>();
      var first = true;
      service.httpClient = MockClient((request) async {
        if (first) {
          first = false;
          await gate.future;
        }
        final body = Uri.splitQueryString(request.body);
        for (var i = 0; body['track[$i]'] != null; i++) {
          sent.add(body['track[$i]']!);
        }
        return http.Response('{}', 200);
      });
      service.debugConfigure(apiKey: 'k', secret: 's', sessionKey: 'sk', pending: [
        for (var i = 0; i < 1000; i++)
          LastFmScrobble(artist: 'A', track: 'q$i', timestamp: i),
      ]);
      final flushing = service.flush();
      // Queue is full: this play pushes the oldest (in flight) out.
      unawaited(service.scrobble(track('new'), DateTime(2026)));
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await flushing;
      await service.flush();
      expect(service.pendingCount, 0);
      expect(sent.toSet(), {for (var i = 0; i < 1000; i++) 'q$i', 'new'});
      expect(sent, hasLength(1001));
    });
  });
}
