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
}
