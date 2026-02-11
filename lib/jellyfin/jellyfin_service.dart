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
  Duration _cacheTtl = const Duration(minutes: 2);

  /// Maximum number of entries per cache map to prevent memory bloat
  static const int _maxCacheSize = 100;

  JellyfinClient? _client;
  JellyfinSession? _session;
  final Map<String, _CacheEntry<List<JellyfinAlbum>>> _albumCache = {};
  final Map<String, _CacheEntry<List<JellyfinArtist>>> _artistCache = {};
  final Map<String, _CacheEntry<List<JellyfinPlaylist>>> _playlistCache = {};
  final Map<String, _CacheEntry<List<JellyfinTrack>>> _recentCache = {};
  final Map<String, _CacheEntry<List<JellyfinGenre>>> _genreCache = {};

  // Track insertion order for LRU eviction
  final List<String> _albumCacheOrder = [];
  final List<String> _artistCacheOrder = [];
  final List<String> _playlistCacheOrder = [];
  final List<String> _recentCacheOrder = [];
  final List<String> _genreCacheOrder = [];

  // In-flight request deduplication - prevents duplicate network calls
  final Map<String, Future<List<JellyfinAlbum>>> _albumRequests = {};
  final Map<String, Future<List<JellyfinArtist>>> _artistRequests = {};
  final Map<String, Future<List<JellyfinPlaylist>>> _playlistRequests = {};

  JellyfinSession? get session => _session;
  JellyfinClient? get jellyfinClient => _client;

  String? get baseUrl => _session?.serverUrl;
  String? get token => _session?.credentials.accessToken;
  Duration get cacheTtl => _cacheTtl;

  /// Set cache TTL duration
  void setCacheTtl(Duration ttl) {
    _cacheTtl = ttl;
    debugPrint('📦 Cache TTL set to ${ttl.inMinutes} minutes');
  }

  Future<JellyfinSession> connect({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final normalizedUrl = _normalizeServerUrl(serverUrl);
    final client = JellyfinClient(
      serverUrl: normalizedUrl,
      httpClient: _httpClient,
      deviceId: deviceId,
    );
    final credentials = await client.authenticate(
      username: username,
      password: password,
    );

    final session = JellyfinSession(
      serverUrl: normalizedUrl,
      username: username,
      credentials: credentials,
      deviceId: deviceId,
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
      deviceId: session.deviceId,
    );
    _session = session;
    _clearCaches();
  }

  void clearSession() {
    _client = null;
    _session = null;
    _clearCaches();
  }

  /// Check server health - useful before heavy operations
  Future<ServerHealth> checkServerHealth() async {
    final client = _client;
    if (client == null) {
      return ServerHealth(
        isHealthy: false,
        latencyMs: 0,
        error: 'Not connected',
      );
    }
    return client.checkServerHealth();
  }

  /// Fetches the current user's profile info including profile image.
  Future<JellyfinUser> getCurrentUser() async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Not connected');
    }
    return client.fetchCurrentUser(session.credentials);
  }

  /// Gets the URL for the current user's profile image.
  String? getUserProfileImageUrl() {
    final client = _client;
    final session = _session;
    if (client == null || session == null) return null;
    // We need to fetch the user first to get the image tag
    // For now, return a URL that might work if user has an image
    return '${session.serverUrl}/Users/${session.credentials.userId}/Images/Primary';
  }

  /// Batch load albums, artists, and genres in parallel
  /// Returns a record with all three lists
  Future<({List<JellyfinAlbum> albums, List<JellyfinArtist> artists, List<JellyfinGenre> genres})> 
  loadLibraryContentBatch({
    required String libraryId,
    bool forceRefresh = false,
    int limit = 50,
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before loading library content.');
    }

    debugPrint('🚀 Batch loading library content...');
    final stopwatch = Stopwatch()..start();

    // Run all three requests in parallel
    final results = await Future.wait([
      loadAlbums(libraryId: libraryId, forceRefresh: forceRefresh, limit: limit),
      loadArtists(libraryId: libraryId, forceRefresh: forceRefresh, limit: limit),
      loadGenres(libraryId: libraryId, forceRefresh: forceRefresh),
    ]);

    stopwatch.stop();
    debugPrint('✅ Batch load complete in ${stopwatch.elapsedMilliseconds}ms');

    return (
      albums: results[0] as List<JellyfinAlbum>,
      artists: results[1] as List<JellyfinArtist>,
      genres: results[2] as List<JellyfinGenre>,
    );
  }

  /// Batch search albums, artists, and tracks in parallel
  Future<({List<JellyfinAlbum> albums, List<JellyfinArtist> artists, List<JellyfinTrack> tracks})>
  searchAllBatch({
    required String libraryId,
    required String query,
  }) async {
    if (query.trim().isEmpty) {
      return (albums: <JellyfinAlbum>[], artists: <JellyfinArtist>[], tracks: <JellyfinTrack>[]);
    }

    debugPrint('🔍 Batch searching: "$query"');
    final stopwatch = Stopwatch()..start();

    final results = await Future.wait([
      searchAlbums(libraryId: libraryId, query: query),
      searchArtists(libraryId: libraryId, query: query),
      searchTracks(libraryId: libraryId, query: query),
    ]);

    stopwatch.stop();
    debugPrint('✅ Batch search complete in ${stopwatch.elapsedMilliseconds}ms');

    return (
      albums: results[0] as List<JellyfinAlbum>,
      artists: results[1] as List<JellyfinArtist>,
      tracks: results[2] as List<JellyfinTrack>,
    );
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
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting albums.');
    }

    // Only use cache for first page with default sorting and when not forcing refresh
    final cacheKey = '$libraryId-$sortBy-$sortOrder';
    if (!forceRefresh && startIndex == 0) {
      final cached = _albumCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }

      // Check for in-flight request to avoid duplicate network calls
      final inFlight = _albumRequests[cacheKey];
      if (inFlight != null) {
        debugPrint('📦 Reusing in-flight albums request for $cacheKey');
        return inFlight;
      }
    }

    // Create the request and track it
    final request = client.fetchAlbums(
      credentials: session.credentials,
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );

    // Track in-flight request for first page only
    if (startIndex == 0) {
      _albumRequests[cacheKey] = request;
    }

    try {
      final albums = await request;

      // Only cache first page
      if (startIndex == 0) {
        _addToCacheWithEviction(_albumCache, _albumCacheOrder, cacheKey, albums);
      }

      return albums;
    } finally {
      // Clean up in-flight tracking
      if (startIndex == 0) {
        _albumRequests.remove(cacheKey);
      }
    }
  }

  Future<List<JellyfinArtist>> loadArtists({
    required String libraryId,
    bool forceRefresh = false,
    int startIndex = 0,
    int limit = 50,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) {
      throw StateError('Authenticate before requesting artists.');
    }

    // Only use cache for first page with default sorting and when not forcing refresh
    final cacheKey = '$libraryId-$sortBy-$sortOrder';
    if (!forceRefresh && startIndex == 0) {
      final cached = _artistCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return cached.value;
      }

      // Check for in-flight request to avoid duplicate network calls
      final inFlight = _artistRequests[cacheKey];
      if (inFlight != null) {
        debugPrint('📦 Reusing in-flight artists request for $cacheKey');
        return inFlight;
      }
    }

    // Create the request and track it
    final request = client.fetchArtists(
      credentials: session.credentials,
      libraryId: libraryId,
      startIndex: startIndex,
      limit: limit,
      sortBy: sortBy,
      sortOrder: sortOrder,
    );

    // Track in-flight request for first page only
    if (startIndex == 0) {
      _artistRequests[cacheKey] = request;
    }

    try {
      final artists = await request;

      // Only cache first page
      if (startIndex == 0) {
        _addToCacheWithEviction(_artistCache, _artistCacheOrder, cacheKey, artists);
      }

      return artists;
    } finally {
      // Clean up in-flight tracking
      if (startIndex == 0) {
        _artistRequests.remove(cacheKey);
      }
    }
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

      // Check for in-flight request to avoid duplicate network calls
      final inFlight = _playlistRequests[cacheKey];
      if (inFlight != null) {
        debugPrint('📦 Reusing in-flight playlists request for $cacheKey');
        return inFlight;
      }
    }

    final request = client.fetchPlaylists(
      credentials: session.credentials,
      libraryId: libraryId,
    );

    _playlistRequests[cacheKey] = request;

    try {
      final playlists = await request;
      _addToCacheWithEviction(_playlistCache, _playlistCacheOrder, cacheKey, playlists);
      return playlists;
    } finally {
      _playlistRequests.remove(cacheKey);
    }
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
    _addToCacheWithEviction(_recentCache, _recentCacheOrder, cacheKey, recent);
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
    _addToCacheWithEviction(_recentCache, _recentCacheOrder, cacheKey, recent);
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
    _addToCacheWithEviction(_albumCache, _albumCacheOrder, cacheKey, recent);
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
    // params['api_key'] = session.credentials.accessToken; // REMOVED: Token should be sent via header

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

  /// Validates and normalizes a server URL
  /// Throws ArgumentError if the URL is invalid
  String _normalizeServerUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Server URL cannot be empty');
    }

    // Validate URL format
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      throw ArgumentError('Invalid URL format');
    }

    // Must have http or https scheme
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('URL must start with http:// or https://');
    }

    // Must have a host
    if (!uri.hasAuthority || uri.host.isEmpty) {
      throw ArgumentError('URL must include a server address');
    }

    // Remove trailing slash if present
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

  Future<void> movePlaylistItem({
    required String playlistId,
    required String itemId,
    required int newIndex,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    await client.movePlaylistItem(
      credentials: session.credentials,
      playlistId: playlistId,
      itemId: itemId,
      newIndex: newIndex,
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
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
        'enableImageTypes': 'Primary,Thumb',
        'enableUserData': 'true',
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
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
        'enableImageTypes': 'Primary,Thumb',
        'enableUserData': 'true',
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
      deviceId: session.deviceId,
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
      deviceId: session.deviceId,
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
      deviceId: session.deviceId,
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
            'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
        'enableImageTypes': 'Primary,Thumb',
        'enableUserData': 'true',
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
    _addToCacheWithEviction(_genreCache, _genreCacheOrder, cacheKey, genres);

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

    return tracksJson.map((json) => JellyfinTrack.fromJson(
      json,
      serverUrl: session.serverUrl,
      token: session.credentials.accessToken,
      userId: session.credentials.userId,
    )).toList();
  }

  /// Get random tracks by artist (for artist instant mix)
  Future<List<JellyfinTrack>> getArtistMix({
    required String artistId,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final tracksJson = await client.fetchTracksByArtist(
      session.credentials,
      artistId: artistId,
      limit: limit,
    );

    return tracksJson.map((json) => JellyfinTrack.fromJson(
      json,
      serverUrl: session.serverUrl,
      token: session.credentials.accessToken,
      userId: session.credentials.userId,
    )).toList();
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

  /// Fetches ALL played tracks by paginating through the API.
  /// Used for accurate stats (top artists, genres, etc.) that need the full picture.
  Future<List<JellyfinTrack>> getAllPlayedTracks({
    required String libraryId,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    // First get the total count so we know how many pages to fetch
    final totalCount = await client.fetchPlayedItemCount(
      session.credentials,
      libraryId: libraryId,
    );

    if (totalCount == 0) return [];

    const pageSize = 500;
    final allTracks = <JellyfinTrack>[];

    for (int offset = 0; offset < totalCount; offset += pageSize) {
      final tracksJson = await client.fetchMostPlayed(
        session.credentials,
        libraryId: libraryId,
        itemType: 'Audio',
        limit: pageSize,
        startIndex: offset,
        filterPlayed: true,
      );

      if (tracksJson.isEmpty) break; // No more results

      allTracks.addAll(tracksJson.map((json) => JellyfinTrack.fromJson(
        json,
        serverUrl: session.serverUrl,
        token: session.credentials.accessToken,
        userId: session.credentials.userId,
      )));
    }

    debugPrint('Stats: Fetched ${allTracks.length} played tracks (total on server: $totalCount)');
    return allTracks;
  }

  /// Get least played tracks for discovery
  Future<List<JellyfinTrack>> getLeastPlayedTracks({
    required String libraryId,
    int maxPlayCount = 3,
    int limit = 50,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final tracksJson = await client.fetchLeastPlayed(
      session.credentials,
      libraryId: libraryId,
      itemType: 'Audio',
      maxPlayCount: maxPlayCount,
      limit: limit,
    );

    return tracksJson.map((json) => JellyfinTrack.fromJson(
      json,
      serverUrl: session.serverUrl,
      token: session.credentials.accessToken,
      userId: session.credentials.userId,
    )).toList();
  }

  /// Get a single track by ID
  Future<JellyfinTrack?> getTrack(String trackId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final json = await client.fetchItem(
      session.credentials,
      itemId: trackId,
    );

    if (json == null) return null;

    return JellyfinTrack.fromJson(
      json,
      serverUrl: session.serverUrl,
      token: session.credentials.accessToken,
      userId: session.credentials.userId,
    );
  }

  /// Get a single artist by ID
  Future<JellyfinArtist> getArtist(String artistId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final json = await client.fetchItem(
      session.credentials,
      itemId: artistId,
    );

    if (json == null) throw StateError('Artist not found');
    return JellyfinArtist.fromJson(json);
  }

  /// Get a single album by ID
  Future<JellyfinAlbum> getAlbum(String albumId) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final json = await client.fetchItem(
      session.credentials,
      itemId: albumId,
    );

    if (json == null) throw StateError('Album not found');
    return JellyfinAlbum.fromJson(json);
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

  /// Get all tracks from the library with genre information for smart playlists
  /// Returns a shuffled list of tracks with their genres
  Future<List<JellyfinTrack>> getAllTracks({
    required String libraryId,
    int limit = 5000,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    return await client.fetchAllTracks(
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
    _albumCacheOrder.clear();
    _artistCacheOrder.clear();
    _playlistCacheOrder.clear();
    _recentCacheOrder.clear();
    _genreCacheOrder.clear();
  }

  /// Add entry to a cache map with LRU eviction
  void _addToCacheWithEviction<T>(
    Map<String, _CacheEntry<T>> cache,
    List<String> cacheOrder,
    String key,
    T value,
  ) {
    // If already in cache, update and move to end (most recently used)
    if (cache.containsKey(key)) {
      cacheOrder.remove(key);
      cacheOrder.add(key);
      cache[key] = _CacheEntry(value);
      return;
    }

    // Evict oldest entries if at capacity
    while (cache.length >= _maxCacheSize && cacheOrder.isNotEmpty) {
      final oldest = cacheOrder.removeAt(0);
      cache.remove(oldest);
    }

    // Add new entry
    cache[key] = _CacheEntry(value);
    cacheOrder.add(key);
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
