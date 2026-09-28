import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/jellyfin_credentials.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
import 'package:nautune/jellyfin/jellyfin_session.dart';

/// Records requests and answers `/Items` queries from an in-memory library.
class _Server {
  _Server({this.trackCount = 0, this.playedCount = 0});

  final int trackCount;
  final int playedCount;
  final List<http.Request> requests = [];

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final q = {
      for (final e in request.url.queryParameters.entries)
        e.key.toLowerCase(): e.value,
    };
    if (request.method == 'GET' && path == '/jf/Items') {
      final played = q['filters'] == 'IsPlayed';
      final total = played ? playedCount : trackCount;
      final start = int.parse(q['startindex'] ?? '0');
      final limit = int.parse(q['limit'] ?? '$total');
      final end = (start + limit).clamp(0, total);
      final items = [
        for (var i = start.clamp(0, total); i < end; i++)
          {'Id': 'id$i', 'Name': 'Track $i', 'Type': 'Audio'},
      ];
      return http.Response(
        jsonEncode({'Items': items, 'TotalRecordCount': total}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method == 'GET' && path == '/jf/Artists') {
      return http.Response(
        jsonEncode({'Items': [], 'TotalRecordCount': 0}),
        200,
      );
    }
    return http.Response('', 204);
  }
}

JellyfinService _service(_Server server) {
  final service = JellyfinService(httpClient: MockClient(server.handle));
  service.restoreSession(
    JellyfinSession(
      serverUrl: 'https://host/jf',
      username: 'u',
      credentials: const JellyfinCredentials(accessToken: 'tok', userId: 'uid'),
      deviceId: 'dev',
    ),
  );
  return service;
}

void main() {
  test('updatePlaylist uses POST /Playlists/{id} with a partial DTO', () async {
    final server = _Server();
    await _service(server).updatePlaylist(playlistId: 'pl1', newName: 'New');
    final req = server.requests.single;
    expect(req.method, 'POST');
    expect(req.url.path, '/jf/Playlists/pl1');
    expect(jsonDecode(req.body), {'Name': 'New'});
    expect(req.headers['Authorization'], contains('Token="tok"'));
  });

  test('addItemsToPlaylist sends ids, userId and optional position', () async {
    final server = _Server();
    final service = _service(server);
    await service.addItemsToPlaylist(playlistId: 'pl', itemIds: ['a', 'b']);
    await service.addItemsToPlaylist(
      playlistId: 'pl',
      itemIds: ['c'],
      position: 0,
    );
    expect(server.requests[0].url.path, '/jf/Playlists/pl/Items');
    expect(server.requests[0].url.queryParameters, {
      'ids': 'a,b',
      'userId': 'uid',
    });
    expect(server.requests[1].url.queryParameters['position'], '0');
  });

  test('movePlaylistItem sends no query parameters', () async {
    final server = _Server();
    await _service(
      server,
    ).movePlaylistItem(playlistId: 'pl', itemId: 'it', newIndex: 3);
    final req = server.requests.single;
    expect(req.method, 'POST');
    expect(req.url.path, '/jf/Playlists/pl/Items/it/Move/3');
    expect(req.url.query, isEmpty);
  });

  test('loadArtists requests user data and no unsupported params', () async {
    final server = _Server();
    await _service(server).loadArtists(libraryId: 'lib');
    final q = server.requests.single.url.queryParameters;
    expect(q['userId'], 'uid');
    expect(q.keys.map((k) => k.toLowerCase()), isNot(contains('recursive')));
  });

  test(
    'getAllPlayedTracks pages to TotalRecordCount without duplicates',
    () async {
      final server = _Server(playedCount: 1203);
      final tracks = await _service(
        server,
      ).getAllPlayedTracks(libraryId: 'lib');
      expect(tracks.length, 1203);
      expect(tracks.map((t) => t.id).toSet().length, 1203);
      expect(server.requests.length, 3);
      final q = server.requests.first.url.queryParameters;
      expect(q['SortBy'], 'PlayCount,SortName');
      expect(q['SortOrder'], 'Descending,Ascending');
    },
  );

  test('getAllTracks on a small library pages a stable order', () async {
    final server = _Server(trackCount: 1100);
    final tracks = await _service(server).getAllTracks(libraryId: 'lib');
    expect(tracks.length, 1100);
    expect(tracks.map((t) => t.id).toSet().length, 1100);
    final sorts = server.requests
        .map((r) => r.url.queryParameters['SortBy'])
        .toList();
    expect(sorts.first, 'Random');
    expect(sorts.skip(1), everyElement('SortName,DateCreated'));
  });

  test('getAllTracks is cached and concurrent calls share one fetch', () async {
    final server = _Server(trackCount: 300);
    final service = _service(server);
    final results = await Future.wait([
      service.getAllTracks(libraryId: 'lib'),
      service.getAllTracks(libraryId: 'lib'),
    ]);
    expect(results[0].length, 300);
    expect(results[1].length, 300);
    final afterFirst = server.requests.length;
    expect(afterFirst, 1);
    await service.getAllTracks(libraryId: 'lib');
    expect(server.requests.length, afterFirst, reason: 'served from cache');
    await service.getAllTracks(libraryId: 'lib', forceRefresh: true);
    expect(server.requests.length, afterFirst + 1);
  });

  group('buildImageUrl', () {
    test('buckets sizes so near-identical requests share a URL', () {
      final service = _service(_Server());
      final a = service.buildImageUrl(itemId: 'i', tag: 't', maxWidth: 346);
      final b = service.buildImageUrl(itemId: 'i', tag: 't', maxWidth: 400);
      expect(a, b);
      expect(Uri.parse(a).queryParameters['maxWidth'], '400');
      expect(
        Uri.parse(a).queryParameters.containsKey('ApiKey'),
        isFalse,
        reason: 'token goes in headers so cache keys survive re-login',
      );
    });

    test('bucketImageDimension rounds up and clamps', () {
      expect(bucketImageDimension(0), 64);
      expect(bucketImageDimension(64), 64);
      expect(bucketImageDimension(65), 96);
      expect(bucketImageDimension(801), 960);
      expect(bucketImageDimension(99999), 2000);
    });
  });
}
