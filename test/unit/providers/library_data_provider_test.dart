import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_album.dart';
import 'package:nautune/jellyfin/jellyfin_credentials.dart';
import 'package:nautune/jellyfin/jellyfin_library.dart';
import 'package:nautune/jellyfin/jellyfin_playlist.dart';
import 'package:nautune/jellyfin/jellyfin_playlist_store.dart';
import 'package:nautune/jellyfin/jellyfin_service.dart';
import 'package:nautune/jellyfin/jellyfin_session.dart';
import 'package:nautune/jellyfin/jellyfin_session_store.dart';
import 'package:nautune/providers/library_data_provider.dart';
import 'package:nautune/providers/session_provider.dart';
import 'package:nautune/services/local_cache_service.dart';

JellyfinSession _session({
  String token = 't1',
  String user = 'u1',
  String? library = 'lib1',
  bool demo = false,
}) =>
    JellyfinSession(
      serverUrl: 'https://example.test',
      username: 'me',
      credentials: JellyfinCredentials(accessToken: token, userId: user),
      deviceId: 'device',
      selectedLibraryId: library,
      isDemo: demo,
    );

class _FakeSessionProvider extends SessionProvider {
  _FakeSessionProvider(JellyfinService service)
      : super(jellyfinService: service, sessionStore: JellyfinSessionStore());

  JellyfinSession? _current;

  @override
  JellyfinSession? get session => _current;

  @override
  bool get isDemoMode => _current?.isDemo ?? false;

  void set(JellyfinSession? session) {
    _current = session;
    notifyListeners();
  }
}

/// Albums "a000".."a{total-1}" served by index; requests are recorded and
/// can be held (to test races) or made to fail.
class _FakeService extends JellyfinService {
  int total = 230;
  final List<({int start, int limit})> albumRequests = [];
  int libraryRequests = 0;
  Object? failAlbumsWith;
  int failAlbumsAfter = -1; // fail every request once this many succeeded
  Completer<void>? hold;

  @override
  Future<List<JellyfinLibrary>> loadLibraries() async {
    libraryRequests++;
    return const [];
  }

  @override
  Future<List<JellyfinAlbum>> loadAlbums({
    required String libraryId,
    bool forceRefresh = false,
    int startIndex = 0,
    int limit = 50,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    albumRequests.add((start: startIndex, limit: limit));
    final h = hold;
    if (h != null) await h.future;
    if (failAlbumsWith != null) throw failAlbumsWith!;
    if (failAlbumsAfter >= 0 && albumRequests.length > failAlbumsAfter) {
      throw StateError('network');
    }
    final end = (startIndex + limit).clamp(0, total);
    return [
      for (var i = startIndex; i < end; i++)
        JellyfinAlbum(
          id: '$libraryId-a${i.toString().padLeft(3, '0')}',
          name: 'Album $i',
          artists: const [],
        ),
    ];
  }

  // Everything else the provider may touch during these tests.
  @override
  Future<List<JellyfinPlaylist>> loadPlaylists({
    String? libraryId,
    bool forceRefresh = false,
  }) async =>
      const [];
}

class _FakeCache implements LocalCacheService {
  List<JellyfinAlbum>? cachedAlbums;

  @override
  String cacheKeyForSession(JellyfinSession session) =>
      '${session.serverUrl}|${session.credentials.userId}';

  @override
  Future<List<JellyfinAlbum>?> readAlbums(String sessionKey,
          {required String libraryId}) async =>
      cachedAlbums;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Null>.value();
}

class _FakePlaylistStore extends JellyfinPlaylistStore {
  @override
  Future<List<JellyfinPlaylist>?> load() async => null;

  @override
  Future<void> save(List<JellyfinPlaylist> playlists) async {}
}

void main() {
  late _FakeService service;
  late _FakeSessionProvider sessions;
  late _FakeCache cache;
  late bool offline;
  late LibraryDataProvider provider;

  final originalDebugPrint = debugPrint;
  tearDown(() => debugPrint = originalDebugPrint);

  setUp(() {
    debugPrint = (String? message, {int? wrapWidth}) {};
    service = _FakeService();
    sessions = _FakeSessionProvider(service);
    cache = _FakeCache();
    offline = false;
    provider = LibraryDataProvider(
      sessionProvider: sessions,
      jellyfinService: service,
      cacheService: cache,
      playlistStore: _FakePlaylistStore(),
      isOffline: () => offline,
    );
  });

  List<String> ids() => [for (final a in provider.albums!) a.id];

  test('pages continue from the loaded count', () async {
    sessions.set(_session());
    await provider.loadAlbums();
    await provider.loadMoreAlbums();
    await provider.loadMoreAlbums();
    expect(provider.albums!.length, 150);
    expect(ids().toSet().length, 150);
    expect(service.albumRequests.map((r) => r.start).toList(),
        containsAllInOrder([0, 50, 100]));
  });

  test('a failed load-all never makes later pages repeat items', () async {
    sessions.set(_session());
    service.total = 2500;
    await provider.loadAlbums(); // 50
    // First 1000-chunk succeeds, the next one fails.
    service.failAlbumsAfter = service.albumRequests.length + 1;
    await provider.loadAllAlbums();
    expect(provider.albums!.length, 1050);
    expect(provider.hasMoreAlbums, isTrue);

    service.failAlbumsAfter = -1;
    await provider.loadMoreAlbums();
    expect(service.albumRequests.last.start, 1050);
    expect(ids().toSet().length, provider.albums!.length);
  });

  test('load-all waits for an in-flight page instead of giving up',
      () async {
    sessions.set(_session());
    await provider.loadAlbums();
    service.hold = Completer<void>();
    final more = provider.loadMoreAlbums();
    final all = provider.loadAllAlbums();
    service.hold!.complete();
    service.hold = null;
    await Future.wait([more, all]);
    expect(provider.albums!.length, 230);
    expect(ids().toSet().length, 230);
    expect(provider.hasMoreAlbums, isFalse);
  });

  test('a refresh during a page load never leaves "loading more" stuck',
      () async {
    sessions.set(_session());
    service.total = 60; // the refreshed first page (50) still has more
    await provider.loadAlbums();
    service.hold = Completer<void>();
    final page = provider.loadMoreAlbums();
    expect(provider.isLoadingMoreAlbums, isTrue);
    // Refresh (sort change / pull to refresh) while the page is in flight.
    service.total = 30; // now fits in one page: no further paging
    final refresh = provider.loadAlbums(forceRefresh: true);
    expect(provider.isLoadingMoreAlbums, isFalse);
    service.hold!.complete();
    service.hold = null;
    await Future.wait([page, refresh]);
    expect(provider.isLoadingMoreAlbums, isFalse);
    expect(provider.hasMoreAlbums, isFalse);
    expect(provider.albums!.length, 30);
  });

  test('a load started for another library is discarded', () async {
    sessions.set(_session());
    await pumpEventQueue();
    service.hold = Completer<void>();
    final stale = provider.loadAlbums();
    sessions.set(_session(library: 'lib2'));
    service.hold!.complete();
    service.hold = null;
    await stale;
    await pumpEventQueue();
    expect(provider.albums, isNotEmpty);
    expect(provider.albums!.every((a) => a.id.startsWith('lib2-')), isTrue);
  });

  test('demo sessions make no requests and expose no errors', () async {
    sessions.set(_session(demo: true));
    await pumpEventQueue();
    await provider.loadLibraries();
    await provider.loadAlbums();
    expect(service.libraryRequests, 0);
    expect(service.albumRequests, isEmpty);
    expect(provider.librariesError, isNull);
    expect(provider.albums, isNull);
  });

  test('offline loads read the cache and page nothing', () async {
    offline = true;
    cache.cachedAlbums = [
      JellyfinAlbum(id: 'c1', name: 'Cached', artists: const []),
    ];
    sessions.set(_session());
    await pumpEventQueue();
    await provider.loadAlbums();
    await provider.loadMoreAlbums();
    expect(service.albumRequests, isEmpty);
    expect(ids(), ['c1']);
    expect(provider.albumsError, isNull);
  });

  test('a failed refresh with cached data exposes no error', () async {
    sessions.set(_session());
    await pumpEventQueue();
    cache.cachedAlbums = [
      JellyfinAlbum(id: 'c1', name: 'Cached', artists: const []),
    ];
    service.failAlbumsWith = StateError('network');
    await provider.loadAlbums();
    expect(ids(), ['c1']);
    expect(provider.albumsError, isNull);

    cache.cachedAlbums = null;
    provider.clearAllData();
    sessions.set(_session(library: 'lib3'));
    await pumpEventQueue();
    await provider.loadAlbums();
    expect(provider.albumsError, isNotNull);
  });
}
