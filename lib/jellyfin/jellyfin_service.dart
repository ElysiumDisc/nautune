import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_client.dart';
import 'jellyfin_genre.dart';
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
  final Map<String, _CacheEntry<List<JellyfinGenre>>> _genreCache = {};

  JellyfinSession? get session => _session;
  JellyfinClient? get jellyfinClient => _client;

  String? get baseUrl => _session?.serverUrl;
  String? get token => _session?.credentials.accessToken;

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
    int startIndex = 0,
    int limit = 50,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting albums.');
    }
    
    // Only use cache for first page and when not forcing refresh
    final cacheKey = libraryId;
    if (!forceRefresh && startIndex == 0) {
      final cached = _albumCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final albums = await client.fetchAlbums(
      credentials: session.credentials,
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
    );
    
    // Only cache first page
    if (startIndex == 0) {
      _albumCache[cacheKey] = _CacheEntry(albums);
    }
    
    return albums;
  }

  Future<List<JellyfinArtist>> loadArtists({
    required String libraryId,
    bool forceRefresh = false,
    int startIndex = 0,
    int limit = 50,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting artists.');
    }
    
    // Only use cache for first page and when not forcing refresh
    final cacheKey = libraryId;
    if (!forceRefresh && startIndex == 0) {
      final cached = _artistCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final artists = await client.fetchArtists(
      credentials: session.credentials,
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
    );
    
    // Only cache first page
    if (startIndex == 0) {
      _artistCache[cacheKey] = _CacheEntry(artists);
    }
    
    return artists;
  }

  Future<List<JellyfinAlbum>> loadAlbumsByArtist({
    required String artistId,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting albums by artist.');
    }

    return client.fetchAlbumsByArtist(
      credentials: session.credentials,
      artistId: artistId,
    );
  }

  Future<List<JellyfinPlaylist>> loadPlaylists({
    String? libraryId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting playlists.');
    }
    final cacheKey = libraryId ?? 'all';
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

  Future<List<JellyfinTrack>> loadTracksByIds(List<String> ids) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null || ids.isEmpty) {
      return const [];
    }
    return client.fetchTracksByIds(
      credentials: session.credentials,
      ids: ids,
    );
  }

  Future<List<JellyfinTrack>> loadRecentlyPlayedTracks({
    required String libraryId,
    bool forceRefresh = false,
    int limit = 20,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting recently played tracks.');
    }
    final cacheKey = 'played_$libraryId#$limit';
    if (!forceRefresh) {
      final cached = _recentCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final recent = await client.fetchRecentlyPlayedTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
    _recentCache[cacheKey] = _CacheEntry(recent);
    return recent;
  }

  Future<List<JellyfinAlbum>> loadRecentlyAddedAlbums({
    required String libraryId,
    bool forceRefresh = false,
    int limit = 20,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting recently added albums.');
    }
    final cacheKey = 'added_albums_$libraryId#$limit';
    if (!forceRefresh) {
      final cached = _albumCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final recent = await client.fetchRecentlyAddedAlbums(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
    _albumCache[cacheKey] = _CacheEntry(recent);
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
    var tracks = await client.fetchAlbumTracks(
      credentials: session.credentials,
      albumId: albumId,
      recursive: true,
    );

    if (tracks.isEmpty) {
      tracks = await client.fetchAlbumTracksByAlbumIds(
        credentials: session.credentials,
        albumId: albumId,
      );
    }

    if (tracks.isEmpty) {
      // Fallback: try non-recursive parent query to handle atypical library layouts.
      tracks = await client.fetchAlbumTracks(
        credentials: session.credentials,
        albumId: albumId,
        recursive: false,
      );
    }

    return tracks;
  }

  Future<List<JellyfinAlbum>> searchAlbums({
    required String libraryId,
    required String query,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before searching albums.');
    }
    if (query.trim().isEmpty) {
      return const [];
    }
    return client.searchAlbums(
      credentials: session.credentials,
      libraryId: libraryId,
      query: query,
    );
  }

  Future<List<JellyfinArtist>> searchArtists({
    required String libraryId,
    required String query,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before searching artists.');
    }
    if (query.trim().isEmpty) {
      return const [];
    }
    return client.searchArtists(
      credentials: session.credentials,
      libraryId: libraryId,
      query: query,
    );
  }
  
  Future<List<JellyfinTrack>> searchTracks({
    required String libraryId,
    required String query,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before searching tracks.');
    }
    if (query.trim().isEmpty) {
      return const [];
    }
    return client.searchTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      query: query,
    );
  }

  String buildImageUrl({
    required String itemId,
    String imageType = 'Primary',
    String? tag,
    int maxWidth = 400,
    int? maxHeight,
    int quality = 90,
    String format = 'jpg',  // jpg, webp, png
  }) {
    final session = _session;
    if (session == null) {
      throw StateError('Session not initialized');
    }
    final buffer = StringBuffer()
      ..write('${session.serverUrl}/Items/$itemId/Images/$imageType');
    final params = <String, String>{
      'quality': '$quality',
      'maxWidth': '$maxWidth',
      'format': format,
    };
    if (maxHeight != null) {
      params['maxHeight'] = '$maxHeight';
    }
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

  // Playlist Management
  Future<JellyfinPlaylist> createPlaylist({
    required String name,
    List<String>? itemIds,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final response = await client.request(
      method: 'POST',
      path: '/Playlists',
      credentials: session.credentials,
      body: {
        'Name': name,
        'Ids': itemIds ?? [],
        'UserId': session.credentials.userId,
        'MediaType': 'Audio',
      },
    );

    _playlistCache.clear();
    return JellyfinPlaylist.fromJson(response);
  }

  Future<void> updatePlaylist({
    required String playlistId,
    required String newName,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');
    
    await client.request(
      method: 'POST',
      path: '/Items/$playlistId',
      credentials: session.credentials,
      body: {
        'Name': newName,
      },
    );

    _playlistCache.clear();
  }

  Future<void> deletePlaylist(String playlistId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');
    
    await client.request(
      method: 'DELETE',
      path: '/Items/$playlistId',
      credentials: session.credentials,
    );
    
    _playlistCache.clear();
  }

  Future<void> addItemsToPlaylist({
    required String playlistId,
    required List<String> itemIds,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    await client.request(
      method: 'POST',
      path: '/Playlists/$playlistId/Items',
      credentials: session.credentials,
      queryParams: {
        'ids': itemIds.join(','),
        'userId': session.credentials.userId,
      },
    );

    _playlistCache.clear();
  }

  Future<void> removeItemsFromPlaylist({
    required String playlistId,
    required List<String> entryIds,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');
    
    await client.request(
      method: 'DELETE',
      path: '/Playlists/$playlistId/Items',
      credentials: session.credentials,
      queryParams: {
        'entryIds': entryIds.join(','),
      },
    );

    _playlistCache.clear();
  }

  Future<List<JellyfinTrack>> getPlaylistItems(String playlistId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final response = await client.request(
      method: 'GET',
      path: '/Playlists/$playlistId/Items',
      credentials: session.credentials,
      queryParams: {
        'userId': session.credentials.userId,
        'fields':
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,AudioInfo,ParentId',
        'enableImageTypes': 'Primary,Thumb',
      },
    );

    final items = (response['Items'] as List?) ?? [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => JellyfinTrack.fromJson(
            json,
            serverUrl: session.serverUrl,
            token: session.credentials.accessToken,
            userId: session.credentials.userId,
          ),
        )
        .toList();
  }

  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final response = await client.request(
      method: 'GET',
      path: '/Users/${session.credentials.userId}/Items',
      credentials: session.credentials,
      queryParams: {
        'parentId': albumId,
        'sortBy': 'SortName',
        'fields':
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,AudioInfo,ParentId',
        'enableImageTypes': 'Primary,Thumb',
      },
    );

    final items = (response['Items'] as List?) ?? [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => JellyfinTrack.fromJson(
            json,
            serverUrl: session.serverUrl,
            token: session.credentials.accessToken,
            userId: session.credentials.userId,
          ),
        )
        .toList();
  }

  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    final session = _session;
    if (session == null) throw Exception('Not connected');
    
    debugPrint('🔵 markFavorite called: itemId=$itemId, shouldBeFavorite=$shouldBeFavorite');
    
    final client = JellyfinClient(
      serverUrl: session.serverUrl,
      httpClient: _httpClient,
    );

    if (shouldBeFavorite) {
      // Add to favorites - POST request (correct endpoint)
      final addPath = '/Users/${session.credentials.userId}/FavoriteItems/$itemId';
      debugPrint('🔵 Adding favorite - Sending POST to $addPath');
      
      try {
        final response = await client.request(
          method: 'POST',
          path: addPath,
          credentials: session.credentials,
        );
        debugPrint('✅ Add favorite response: $response');
        debugPrint('✅ Successfully added item $itemId to Jellyfin favorites');
      } catch (e) {
        debugPrint('❌ Failed to add favorite: $e');
        rethrow;
      }
    } else {
      // Remove from favorites - DELETE request (correct endpoint)
      final deletePath = '/Users/${session.credentials.userId}/FavoriteItems/$itemId';
      debugPrint('🔵 Removing favorite - Sending DELETE to $deletePath');
      
      try {
        final response = await client.request(
          method: 'DELETE',
          path: deletePath,
          credentials: session.credentials,
        );
        debugPrint('✅ Delete favorite response: $response');
        
        // VERIFY: Fetch the item again to confirm it was unfavorited
        debugPrint('🔍 Verifying item was actually unfavorited...');
        final verifyPath = '/Users/${session.credentials.userId}/Items/$itemId';
        final verifyResponse = await client.request(
          method: 'GET',
          path: verifyPath,
          credentials: session.credentials,
        );
        final actualIsFavorite = verifyResponse['UserData']?['IsFavorite'] ?? false;
        debugPrint('🔍 Server confirms IsFavorite=$actualIsFavorite');
        
        if (actualIsFavorite) {
          throw Exception('Failed to unfavorite: Server still shows as favorite!');
        }
        
        debugPrint('✅ Successfully removed item $itemId from Jellyfin favorites');
      } catch (e) {
        debugPrint('❌ Failed to remove favorite: $e');
        rethrow;
      }
    }
    
    // Clear caches so next fetch gets updated data
    _clearCaches();
    debugPrint('🧹 Cleared caches after favorite update');
  }

  Future<List<JellyfinAlbum>> getFavoriteAlbums() async {
    final session = _session;
    if (session == null) return [];

    final client = JellyfinClient(
      serverUrl: session.serverUrl,
      httpClient: _httpClient,
    );

    final response = await client.request(
      method: 'GET',
      path: '/Users/${session.credentials.userId}/Items',
      credentials: session.credentials,
      queryParams: {
        'includeItemTypes': 'MusicAlbum',
        'recursive': 'true',
        'filters': 'IsFavorite',
        'sortBy': 'SortName',
        'fields': 'DateCreated,Genres,ParentId',
      },
    );

    final items = (response['Items'] as List?) ?? [];
    return items.map((json) => JellyfinAlbum.fromJson(json as Map<String, dynamic>)).toList();
  }

  Future<List<JellyfinTrack>> getFavoriteTracks() async {
    final session = _session;
    if (session == null) return [];

    final client = JellyfinClient(
      serverUrl: session.serverUrl,
      httpClient: _httpClient,
    );

    final response = await client.request(
      method: 'GET',
      path: '/Users/${session.credentials.userId}/Items',
      credentials: session.credentials,
      queryParams: {
        'includeItemTypes': 'Audio',
        'recursive': 'true',
        'filters': 'IsFavorite',
        'sortBy': 'SortName',
        'fields':
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,AudioInfo,ParentId',
        'enableImageTypes': 'Primary,Thumb',
      },
    );

    final items = (response['Items'] as List?) ?? [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (json) => JellyfinTrack.fromJson(
            json,
            serverUrl: session.serverUrl,
            token: session.credentials.accessToken,
            userId: session.credentials.userId,
          ),
        )
        .toList();
  }

  /// Load genres for a library
  Future<List<JellyfinGenre>> loadGenres({
    String? libraryId,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final cacheKey = 'genres_$libraryId';
    if (!forceRefresh) {
      final cached = _genreCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }
    }

    final genresJson = await client.fetchGenres(
      session.credentials,
      parentId: libraryId,
    );

    final genres = genresJson.map((json) => JellyfinGenre.fromJson(json)).toList();
    _genreCache[cacheKey] = _CacheEntry(genres);

    return genres;
  }

  /// Get instant mix based on a track, album, or artist
  Future<List<JellyfinTrack>> getInstantMix({
    required String itemId,
    int limit = 200,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final tracksJson = await client.fetchInstantMix(
      session.credentials,
      itemId: itemId,
      limit: limit,
    );

    return tracksJson.map((json) => JellyfinTrack.fromJson(json)).toList();
  }

  /// Get playback info for an item (formats, bitrates, codecs)
  Future<Map<String, dynamic>> getPlaybackInfo(String itemId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchPlaybackInfo(
      session.credentials,
      itemId: itemId,
    );
  }

  /// Get most played tracks for a library
  Future<List<JellyfinTrack>> getMostPlayedTracks({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final tracksJson = await client.fetchMostPlayed(
      session.credentials,
      libraryId: libraryId,
      itemType: 'Audio',
      limit: limit,
    );

    return tracksJson.map((json) => JellyfinTrack.fromJson(
      json,
      serverUrl: session.serverUrl,
      token: session.credentials.accessToken,
      userId: session.credentials.userId,
    )).toList();
  }

  /// Get most played albums for a library
  Future<List<JellyfinAlbum>> getMostPlayedAlbums({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final albumsJson = await client.fetchMostPlayed(
      session.credentials,
      libraryId: libraryId,
      itemType: 'MusicAlbum',
      limit: limit,
    );

    return albumsJson.map((json) => JellyfinAlbum.fromJson(json)).toList();
  }

  /// Get most played artists for a library
  Future<List<JellyfinArtist>> getMostPlayedArtists({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final artistsJson = await client.fetchMostPlayed(
      session.credentials,
      libraryId: libraryId,
      itemType: 'MusicArtist',
      limit: limit,
    );

    return artistsJson.map((json) => JellyfinArtist.fromJson(json)).toList();
  }

  /// Get recently played tracks for a library
  Future<List<JellyfinTrack>> getRecentlyPlayedTracks({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchRecentlyPlayedTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
  }

  /// Get recently added tracks for a library
  Future<List<JellyfinTrack>> getRecentlyAddedTracks({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchRecentlyAddedTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
  }

  /// Get longest runtime tracks for a library
  Future<List<JellyfinTrack>> getLongestRuntimeTracks({
    required String libraryId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchLongestRuntimeTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
  }

  /// Fetch lyrics for a track
  /// Returns structured lyrics data if available, null otherwise
  Future<Map<String, dynamic>?> getLyrics(String itemId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchLyrics(
      credentials: session.credentials,
      itemId: itemId,
    );
  }

  void _clearCaches() {
    _albumCache.clear();
    _artistCache.clear();
    _playlistCache.clear();
    _recentCache.clear();
    _genreCache.clear();
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
