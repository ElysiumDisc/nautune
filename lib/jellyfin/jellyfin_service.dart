import 'package:http/http.dart' as http;

import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_client.dart';
import 'jellyfin_library.dart';
import 'jellyfin_playlist.dart';
import 'jellyfin_session.dart';
import 'jellyfin_track.dart';
import 'jellyfin_user.dart';

/// High-level façade for Nautune to talk to Jellyfin.
class JellyfinService {
  JellyfinService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration _cacheTtl = const Duration(minutes: 2);

  JellyfinClient? _client;
  JellyfinSession? _session;
  final Map<String, _CacheEntry<List<JellyfinAlbum>>> _albumCache = {};
  final Map<String, _CacheEntry<List<JellyfinArtist>>> _artistCache = {};
  final Map<String, _CacheEntry<List<JellyfinPlaylist>>> _playlistCache = {};
  final Map<String, _CacheEntry<List<JellyfinTrack>>> _recentCache = {};

  JellyfinSession? get session => _session;

  Future<JellyfinSession> connect({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final normalizedUrl = _normalizeServerUrl(serverUrl);
    final client = JellyfinClient(
      serverUrl: normalizedUrl,
      httpClient: _httpClient,
    );
    final credentials = await client.authenticate(
      username: username,
      password: password,
    );

    final session = JellyfinSession(
      serverUrl: normalizedUrl,
      username: username,
      credentials: credentials,
    );

    _client = client;
    _session = session;
    _clearCaches();

    return session;
  }

  void restoreSession(JellyfinSession session) {
    _client = JellyfinClient(
      serverUrl: session.serverUrl,
      httpClient: _httpClient,
    );
    _session = session;
    _clearCaches();
  }

  void clearSession() {
    _client = null;
    _session = null;
    _clearCaches();
  }

  Future<List<JellyfinUser>> loadUsers() async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting users.');
    }
    return client.fetchUsers(session.credentials);
  }

  Future<List<JellyfinLibrary>> loadLibraries() async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting libraries.');
    }
    return client.fetchLibraries(session.credentials);
  }

  Future<List<JellyfinAlbum>> loadAlbums({
    required String libraryId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting albums.');
    }
    final cacheKey = libraryId;
    if (!forceRefresh) {
      final cached = _albumCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final albums = await client.fetchAlbums(
      credentials: session.credentials,
      libraryId: libraryId,
    );
    _albumCache[cacheKey] = _CacheEntry(albums);
    return albums;
  }

  Future<List<JellyfinArtist>> loadArtists({
    required String libraryId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting artists.');
    }
    final cacheKey = libraryId;
    if (!forceRefresh) {
      final cached = _artistCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final artists = await client.fetchArtists(
      credentials: session.credentials,
      libraryId: libraryId,
    );
    _artistCache[cacheKey] = _CacheEntry(artists);
    return artists;
  }

  Future<List<JellyfinPlaylist>> loadPlaylists({
    required String libraryId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting playlists.');
    }
    final cacheKey = libraryId;
    if (!forceRefresh) {
      final cached = _playlistCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final playlists = await client.fetchPlaylists(
      credentials: session.credentials,
      libraryId: libraryId,
    );
    _playlistCache[cacheKey] = _CacheEntry(playlists);
    return playlists;
  }

  Future<List<JellyfinTrack>> loadRecentTracks({
    required String libraryId,
    bool forceRefresh = false,
    int limit = 20,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting recent tracks.');
    }
    final cacheKey = '$libraryId#$limit';
    if (!forceRefresh) {
      final cached = _recentCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final recent = await client.fetchRecentTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
    _recentCache[cacheKey] = _CacheEntry(recent);
    return recent;
  }

  Future<List<JellyfinTrack>> loadAlbumTracks({
    required String albumId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting album tracks.');
    }
    return client.fetchAlbumTracks(
      credentials: session.credentials,
      albumId: albumId,
    );
  }

  String buildImageUrl({
    required String itemId,
    String imageType = 'Primary',
    String? tag,
    int maxWidth = 400,
  }) {
    final session = _session;
    if (session == null) {
      throw StateError('Session not initialized');
    }
    final buffer = StringBuffer()
      ..write('${session.serverUrl}/Items/$itemId/Images/$imageType');
    final params = <String, String>{
      'quality': '90',
      'maxWidth': '$maxWidth',
    };
    if (tag != null) {
      params['tag'] = tag;
    }
    params['api_key'] = session.credentials.accessToken;

    final query = params.entries
        .map((entry) => '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    buffer.write('?$query');
    return buffer.toString();
  }

  Map<String, String> imageHeaders() {
    final session = _session;
    if (session == null) {
      throw StateError('Session not initialized');
    }
    return {
      'X-MediaBrowser-Token': session.credentials.accessToken,
    };
  }

  String _normalizeServerUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  void _clearCaches() {
    _albumCache.clear();
    _artistCache.clear();
    _playlistCache.clear();
    _recentCache.clear();
  }
}

class _CacheEntry<T> {
  _CacheEntry(this.value) : timestamp = DateTime.now();

  final T value;
  final DateTime timestamp;

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}
