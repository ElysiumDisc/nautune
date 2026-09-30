import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/jellyfin_credentials.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
import 'package:nautune/jellyfin/jellyfin_session.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';

JellyfinSession _session({String user = 'uid', String token = 'tok'}) =>
    JellyfinSession(
      serverUrl: 'https://host/jf',
      username: 'u',
      credentials: JellyfinCredentials(accessToken: token, userId: user),
      deviceId: 'dev',
    );

void main() {
  late List<http.Request> requests;

  JellyfinService service(
    Future<http.Response> Function(http.Request) handler,
  ) {
    requests = [];
    final s = JellyfinService(
      httpClient: MockClient((r) {
        requests.add(r);
        return handler(r);
      }),
    );
    s.restoreSession(_session());
    return s;
  }

  http.Response items(List<Map<String, dynamic>> list) => http.Response(
        jsonEncode({'Items': list, 'TotalRecordCount': list.length}),
        200,
      );

  tearDown(() => JellyfinTrack.sessionTokenResolver = null);

  test('first-page cache is keyed by limit (CarPlay 500 vs library 50)',
      () async {
    final s = service((r) async {
      final limit = int.parse(r.url.queryParameters['Limit']!);
      return items([
        for (var i = 0; i < limit; i++) {'Id': 'a$i', 'Name': 'A$i'},
      ]);
    });
    final page50 = await s.loadAlbums(libraryId: 'lib', limit: 50);
    final page500 = await s.loadAlbums(libraryId: 'lib', limit: 500);
    expect(page50, hasLength(50));
    expect(page500, hasLength(500));
    expect(requests, hasLength(2));
    // Same size again comes from the cache.
    await s.loadAlbums(libraryId: 'lib', limit: 50);
    expect(requests, hasLength(2));
    expect(
      JellyfinService.firstPageCacheKey('lib', 'SortName', 'Ascending', 50),
      isNot(JellyfinService.firstPageCacheKey('lib', 'SortName', 'Ascending', 500)),
    );
  });

  test('loadTracksByIds chunks long id lists and keeps the requested order',
      () async {
    final s = service((r) async {
      final ids = r.url.queryParameters['Ids']!.split(',');
      // Server answers in its own (reversed) order.
      return items([
        for (final id in ids.reversed) {'Id': id, 'Name': id, 'Type': 'Audio'},
      ]);
    });
    final ids = [for (var i = 0; i < 250; i++) 't$i'];
    final tracks = await s.loadTracksByIds(ids);
    expect(requests, hasLength(3));
    for (final r in requests) {
      expect(r.url.queryParameters['Ids']!.split(',').length,
          lessThanOrEqualTo(100));
    }
    expect(tracks.map((t) => t.id), ids);
  });

  test('addItemsToPlaylist chunks ids and advances the insert position',
      () async {
    final s = service((r) async => http.Response('', 204));
    await s.addItemsToPlaylist(
      playlistId: 'pl',
      itemIds: [for (var i = 0; i < 150; i++) 'x$i'],
      position: 10,
    );
    expect(requests, hasLength(2));
    expect(requests[0].url.queryParameters['position'], '10');
    expect(requests[1].url.queryParameters['position'], '110');
    expect(requests[1].url.queryParameters['ids']!.split(','), hasLength(50));
  });

  test('getAlbumTracks is in disc/track order, audio only', () async {
    final s = service((r) async => items([
          {'Id': '1', 'Name': 'B', 'IndexNumber': 1, 'Type': 'Audio'},
        ]));
    await s.getAlbumTracks('album');
    final q = requests.single.url.queryParameters;
    expect(q['SortBy'], 'ParentIndexNumber,IndexNumber,SortName');
    expect(q['IncludeItemTypes'], 'Audio');
    expect(q['ParentId'], 'album');
  });

  test('a fetch from a replaced session is not cached into the new one',
      () async {
    var answer = 'userA';
    final s = service((r) async => items([
          {'Id': answer, 'Name': answer},
        ]));
    final pending = s.loadPlaylists(); // issued as user A
    s.restoreSession(_session(user: 'uidB', token: 'tokB'));
    await pending;
    answer = 'userB';
    final forB = await s.loadPlaylists();
    expect(forB.single.id, 'userB');
  });

  test('restoreSession installs a token resolver for stored tracks', () {
    service((r) async => http.Response('', 204));
    final stored = JellyfinTrack.fromStorageJson({
      'id': 't',
      'name': 'T',
      'serverUrl': 'https://host/jf/',
      'userId': 'uid',
    });
    expect(stored.token, 'tok');
    final otherUser = JellyfinTrack.fromStorageJson({
      'id': 't',
      'name': 'T',
      'serverUrl': 'https://host/jf',
      'userId': 'someone-else',
    });
    expect(otherUser.token, isNull);
    // Scheme/host case, default port and trailing slashes don't matter.
    final respelled = JellyfinTrack.fromStorageJson({
      'id': 't',
      'name': 'T',
      'serverUrl': 'HTTPS://Host:443/jf//',
      'userId': 'uid',
    });
    expect(respelled.token, 'tok');
    final otherServer = JellyfinTrack.fromStorageJson({
      'id': 't',
      'name': 'T',
      'serverUrl': 'https://host:8920/jf',
      'userId': 'uid',
    });
    expect(otherServer.token, isNull);
  });

  test('revokeSessionToken posts /Sessions/Logout with the old token',
      () async {
    final s = service((r) async => http.Response('', 204));
    final old = _session(token: 'old');
    s.clearSession();
    expect(await s.revokeSessionToken(old), isTrue);
    final r = requests.single;
    expect(r.method, 'POST');
    expect(r.url.path, '/jf/Sessions/Logout');
    expect(r.headers['Authorization'], contains('Token="old"'));
  });

  test('revokeSessionToken swallows failures', () async {
    final s = service((r) async => throw http.ClientException('down'));
    expect(await s.revokeSessionToken(_session()), isFalse);
  });

  test('unfavorite reads IsFavorite from the DELETE response (no extra GET)',
      () async {
    final s = service((r) async =>
        http.Response(jsonEncode({'IsFavorite': false}), 200));
    await s.markFavorite('item', false);
    expect(requests.single.method, 'DELETE');
    expect(requests.single.url.path, '/jf/UserFavoriteItems/item');
  });

  test('favorite toggle patches cached tracks instead of dropping caches',
      () async {
    var favoriteCalls = 0;
    final s = service((r) async {
      if (r.url.path.startsWith('/jf/UserFavoriteItems')) {
        favoriteCalls++;
        return http.Response(jsonEncode({'IsFavorite': true}), 200);
      }
      return items([
        {'Id': 'x', 'Name': 'X', 'Type': 'Audio'},
      ]);
    });
    final before = await s.loadRecentTracks(libraryId: 'lib');
    expect(before.single.isFavorite, isFalse);
    await s.markFavorite('x', true);
    final after = await s.loadRecentTracks(libraryId: 'lib');
    expect(after.single.isFavorite, isTrue);
    expect(favoriteCalls, 1);
    expect(requests.where((r) => r.url.path == '/jf/Items'), hasLength(1),
        reason: 'served from the patched cache');
  });
}
