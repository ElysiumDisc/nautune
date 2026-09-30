import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_auth_header.dart';
import 'jellyfin_client.dart';
import 'jellyfin_genre.dart';
import 'jellyfin_library.dart';
import 'jellyfin_playlist.dart';
import 'jellyfin_session.dart';
import 'jellyfin_track.dart';
import 'jellyfin_user.dart';
import 'order_by_ids.dart';
import 'paged_fetch.dart';
import 'server_uri.dart';

/// High-level façade for Nautune to talk to Jellyfin.
class JellyfinService {
  JellyfinService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  Duration _cacheTtl = const Duration(minutes: 2);

  /// Maximum number of entries per cache map to prevent memory bloat
  static const int _maxCacheSize = 500;

  /// Timeout for unpaged bulk GETs (whole playlists, all favorites). The
  /// default 15 s covers the full response body, which large payloads on a
  /// slow link can exceed.
  static const Duration _bulkTimeout = Duration(seconds: 45);

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
  final Map<String, Future<List<JellyfinLibrary>>> _libraryRequests = {};
  final Map<String, Future<List<JellyfinGenre>>> _genreRequests = {};
  final Map<String, Future<List<JellyfinTrack>>> _allTracksRequests = {};

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
    _clearInFlight();
    _installTokenResolver();

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
    _clearInFlight();
    _installTokenResolver();
  }

  void clearSession() {
    _client = null;
    _session = null;
    _clearCaches();
    _clearInFlight();
    _installTokenResolver();
  }

  /// Lets tracks restored from storage (which never persist the access
  /// token) build stream/artwork URLs with the active session's token, but
  /// only for the same server and user.
  void _installTokenResolver() {
    JellyfinTrack.sessionTokenResolver = (serverUrl, userId) {
      final session = _session;
      if (session == null || serverUrl == null) return null;
      if (!isSameServerUrl(serverUrl, session.serverUrl)) return null;
      if (userId != null && userId != session.credentials.userId) return null;
      final token = session.credentials.accessToken;
      return token.isEmpty ? null : token;
    };
  }

  /// Revokes [session]'s access token on its server
  /// (`POST /Sessions/Logout`), best effort with a short timeout. Safe to
  /// call after [clearSession] (it uses its own client for [session]).
  /// [delay] lets a just-fired stop report go out with the token first.
  Future<bool> revokeSessionToken(
    JellyfinSession session, {
    Duration delay = Duration.zero,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (session.isDemo || session.serverUrl.startsWith('demo://')) {
      return false;
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final client = JellyfinClient(
      serverUrl: session.serverUrl,
      httpClient: _httpClient,
      deviceId: session.deviceId,
    );
    return client.logout(session.credentials, timeout: timeout);
  }

  /// Cache / in-flight key for the first page of albums or artists.
  @visibleForTesting
  static String firstPageCacheKey(
    String libraryId,
    String sortBy,
    String sortOrder,
    int limit,
  ) =>
      '$libraryId-$sortBy-$sortOrder#$limit';

  /// Whether a result fetched for [session] may still be cached (the
  /// session wasn't replaced or cleared while the request was in flight).
  bool _isCurrent(JellyfinSession session) => identical(_session, session);

  /// Removes [key] from [inFlight] only if it still maps to [request] (a
  /// newer session may have registered its own request under that key).
  static void _releaseInFlight<T>(
    Map<String, Future<T>> inFlight,
    String key,
    Future<T> request,
  ) {
    if (identical(inFlight[key], request)) inFlight.remove(key);
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

  /// Cheap reachability probe for the connected server (single attempt,
  /// short timeout). Returns false when not connected.
  Future<bool> isServerReachable() async {
    final client = _client;
    if (client == null) return false;
    return client.isReachable();
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

  /// Gets the URL for the current user's profile image via the
  /// spec-documented `GET /UserImage?userId=…`.
  String? getUserProfileImageUrl() {
    final client = _client;
    final session = _session;
    if (client == null || session == null) return null;
    return buildServerUrl(session.serverUrl, '/UserImage', {
      'userId': session.credentials.userId,
    });
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
    int? limit,
  }) async {
    if (query.trim().isEmpty) {
      return (albums: <JellyfinAlbum>[], artists: <JellyfinArtist>[], tracks: <JellyfinTrack>[]);
    }

    debugPrint('🔍 Batch searching: "$query"');
    final stopwatch = Stopwatch()..start();

    final results = await Future.wait([
      searchAlbums(libraryId: libraryId, query: query, limit: limit),
      searchArtists(libraryId: libraryId, query: query, limit: limit),
      searchTracks(libraryId: libraryId, query: query, limit: limit),
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

    const cacheKey = 'libraries';
    final inFlight = _libraryRequests[cacheKey];
    if (inFlight != null) {
      debugPrint('📦 Reusing in-flight libraries request');
      return inFlight;
    }

    final request = client.fetchLibraries(session.credentials);
    _libraryRequests[cacheKey] = request;

    try {
      return await request;
    } finally {
      _releaseInFlight(_libraryRequests, cacheKey, request);
    }
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

    // Only the first page is cached. The key includes [limit]: callers ask
    // for different first-page sizes (50 for the library, 500 for CarPlay's
    // index) and must never get a page of another size back.
    final cacheKey = firstPageCacheKey(libraryId, sortBy, sortOrder, limit);
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
      if (startIndex == 0 && _isCurrent(session)) {
        _addToCacheWithEviction(_albumCache, _albumCacheOrder, cacheKey, albums);
      }

      return albums;
    } finally {
      // Clean up in-flight tracking
      if (startIndex == 0) {
        _releaseInFlight(_albumRequests, cacheKey, request);
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

    // First page only; keyed by [limit] too (see [loadAlbums]).
    final cacheKey = firstPageCacheKey(libraryId, sortBy, sortOrder, limit);
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
      if (startIndex == 0 && _isCurrent(session)) {
        _addToCacheWithEviction(_artistCache, _artistCacheOrder, cacheKey, artists);
      }

      return artists;
    } finally {
      // Clean up in-flight tracking
      if (startIndex == 0) {
        _releaseInFlight(_artistRequests, cacheKey, request);
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
      if (_isCurrent(session)) {
        _addToCacheWithEviction(
            _playlistCache, _playlistCacheOrder, cacheKey, playlists);
      }
      return playlists;
    } finally {
      _releaseInFlight(_playlistRequests, cacheKey, request);
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
    if (_isCurrent(session)) {
      _addToCacheWithEviction(_recentCache, _recentCacheOrder, cacheKey, recent);
    }
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
    if (_isCurrent(session)) {
      _addToCacheWithEviction(_recentCache, _recentCacheOrder, cacheKey, recent);
    }
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
    if (_isCurrent(session)) {
      _addToCacheWithEviction(_albumCache, _albumCacheOrder, cacheKey, recent);
    }
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
    int? limit,
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
      limit: limit,
    );
  }

  Future<List<JellyfinArtist>> searchArtists({
    required String libraryId,
    required String query,
    int? limit,
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
      limit: limit,
    );
  }
  
  Future<List<JellyfinTrack>> searchTracks({
    required String libraryId,
    required String query,
    int? limit,
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
      limit: limit,
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
    // Bucket the requested size so the same artwork shown at slightly
    // different sizes/DPRs maps to one URL (one server resize, one
    // cached_network_image disk entry) instead of one per pixel width.
    final params = <String, String>{
      'quality': '$quality',
      'maxWidth': '${bucketImageDimension(maxWidth)}',
      'format': format,
    };
    if (maxHeight != null) {
      params['maxHeight'] = '${bucketImageDimension(maxHeight)}';
    }
    if (tag != null) {
      params['tag'] = tag;
    }
    // Token is sent via imageHeaders(), not the URL.
    return buildServerUrl(
      session.serverUrl,
      '/Items/$itemId/Images/$imageType',
      params,
    );
  }

  /// Image URL with the access token embedded as a query parameter, so
  /// system image loaders that can't supply our auth headers (CarPlay's
  /// `CPListItem.image`, lock-screen artwork, OS share sheets) can fetch it.
  /// Returns null if no session.
  String? buildSelfContainedImageUrl({
    required String itemId,
    String? tag,
    String imageType = 'Primary',
    int maxWidth = 400,
  }) {
    final session = _session;
    if (session == null) return null;
    final params = <String, String>{
      'quality': '90',
      'maxWidth': '$maxWidth',
      kJellyfinApiKeyQueryParam: session.credentials.accessToken,
    };
    if (tag != null) params['tag'] = tag;
    return buildServerUrl(
      session.serverUrl,
      '/Items/$itemId/Images/$imageType',
      params,
    );
  }

  Map<String, String> imageHeaders() {
    final session = _session;
    if (session == null) {
      throw StateError('Session not initialized');
    }
    return nautuneAuthHeaders(
      deviceId: session.deviceId,
      token: session.credentials.accessToken,
    );
  }

  /// Validates and normalizes a server URL.
  /// Keeps any reverse-proxy base path (e.g. `https://host/jellyfin`) and only
  /// strips trailing slashes. Throws ArgumentError if the URL is invalid.
  String _normalizeServerUrl(String rawUrl) {
    final trimmed = normalizeServerBaseUrl(rawUrl);
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

    _clearPlaylistCache();
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
    
    // `POST /Playlists/{playlistId}` (UpdatePlaylistDto): null/omitted
    // fields keep their value. The old `POST /Items/{id}` (UpdateItem) takes
    // a full BaseItemDto and would reset other metadata to defaults.
    await client.request(
      method: 'POST',
      path: '/Playlists/$playlistId',
      credentials: session.credentials,
      body: {
        'Name': newName,
      },
    );

    _clearPlaylistCache();
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
    
    _clearPlaylistCache();
  }

  /// `POST /Playlists/{playlistId}/Items`. [position] (0-based insert
  /// index; omitted = append) exists since 12.0; 10.11 ignores it and appends.
  Future<void> addItemsToPlaylist({
    required String playlistId,
    required List<String> itemIds,
    int? position,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    // Chunked so a large selection can't exceed request-line limits (414).
    // Each chunk is inserted after the previous one when [position] is set.
    try {
      var offset = 0;
      for (final chunk in chunkIds(itemIds)) {
        await client.request(
          method: 'POST',
          path: '/Playlists/$playlistId/Items',
          credentials: session.credentials,
          queryParams: {
            'ids': chunk.join(','),
            'userId': session.credentials.userId,
            if (position != null) 'position': position + offset,
          },
        );
        offset += chunk.length;
      }
    } finally {
      _clearPlaylistCache();
    }
  }

  /// `DELETE /Playlists/{playlistId}/Items?entryIds=…`. Entry ids are the
  /// items' `PlaylistItemId`s; on 10.11 and 12.1 that equals the item id
  /// (`N` format), so passing track ids works — every entry of that item
  /// is removed.
  Future<void> removeItemsFromPlaylist({
    required String playlistId,
    required List<String> entryIds,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');
    
    try {
      for (final chunk in chunkIds(entryIds)) {
        await client.request(
          method: 'DELETE',
          path: '/Playlists/$playlistId/Items',
          credentials: session.credentials,
          queryParams: {
            'entryIds': chunk.join(','),
          },
        );
      }
    } finally {
      _clearPlaylistCache();
    }
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

    _clearPlaylistCache();
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
      timeout: _bulkTimeout,
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

  /// Album tracks in disc/track order (same query and fallbacks as
  /// [loadAlbumTracks]). Used by CarPlay, add-to-playlist and the online
  /// repository, which play/insert the list as returned.
  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) {
    return loadAlbumTracks(albumId: albumId);
  }

  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    final session = _session;
    if (session == null) throw Exception('Not connected');

    // Reuse existing _client instead of creating a new JellyfinClient per call
    final activeClient = _client;
    if (activeClient == null) throw Exception('Client not initialized');

    // Spec-documented favorites endpoint (Jellyfin 10.9+):
    // `/UserFavoriteItems/{itemId}` with `userId` as a query parameter.
    // Both POST and DELETE return the updated `UserItemDataDto`.
    final favoritePath = '/UserFavoriteItems/$itemId';
    final favoriteQuery = {'userId': session.credentials.userId};

    bool? confirmed;
    try {
      final response = await activeClient.request(
        method: shouldBeFavorite ? 'POST' : 'DELETE',
        path: favoritePath,
        credentials: session.credentials,
        queryParams: favoriteQuery,
      );
      final serverFavorite = response['IsFavorite'];
      if (serverFavorite is bool && serverFavorite != shouldBeFavorite) {
        confirmed = serverFavorite;
        throw Exception(
          'Failed to ${shouldBeFavorite ? 'favorite' : 'unfavorite'}: '
          'server reports IsFavorite=$serverFavorite',
        );
      }
      confirmed = shouldBeFavorite;
    } finally {
      // Patch (or, when the outcome is unknown, drop) only the cached
      // entries containing this item, instead of every cache: the library
      // sample behind smart playlists is several MB and ~10 requests.
      if (_isCurrent(session)) _applyFavoriteToCaches(itemId, confirmed);
    }
  }

  /// Updates cached tracks/albums for [itemId] to [isFavorite]; when null
  /// (request failed, state unknown) removes the cache entries holding it.
  void _applyFavoriteToCaches(String itemId, bool? isFavorite) {
    for (final key in _recentCache.keys.toList()) {
      final entry = _recentCache[key]!;
      if (!entry.value.any((t) => t.id == itemId)) continue;
      if (isFavorite == null) {
        _recentCache.remove(key);
        _recentCacheOrder.remove(key);
      } else {
        _recentCache[key] = entry.withValue([
          for (final t in entry.value)
            t.id == itemId ? t.copyWith(isFavorite: isFavorite) : t,
        ]);
      }
    }
    for (final key in _albumCache.keys.toList()) {
      final entry = _albumCache[key]!;
      if (!entry.value.any((a) => a.id == itemId)) continue;
      if (isFavorite == null) {
        _albumCache.remove(key);
        _albumCacheOrder.remove(key);
      } else {
        _albumCache[key] = entry.withValue([
          for (final a in entry.value)
            a.id == itemId ? _albumWithFavorite(a, isFavorite) : a,
        ]);
      }
    }
  }

  static JellyfinAlbum _albumWithFavorite(JellyfinAlbum a, bool isFavorite) =>
      JellyfinAlbum(
        id: a.id,
        name: a.name,
        artists: a.artists,
        artistIds: a.artistIds,
        productionYear: a.productionYear,
        primaryImageTag: a.primaryImageTag,
        isFavorite: isFavorite,
        genres: a.genres,
        playCount: a.playCount,
        sortName: a.sortName,
      );

  Future<List<JellyfinAlbum>> getFavoriteAlbums() async {
    final session = _session;
    if (session == null) return [];
    final activeClient = _client;
    if (activeClient == null) return [];

    final response = await activeClient.request(
      method: 'GET',
      path: '/Items',
      credentials: session.credentials,
      timeout: _bulkTimeout,
      queryParams: {
        'userId': session.credentials.userId,
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
    final activeClient = _client;
    if (activeClient == null) return [];

    final response = await activeClient.request(
      method: 'GET',
      path: '/Items',
      credentials: session.credentials,
      timeout: _bulkTimeout,
      queryParams: {
        'userId': session.credentials.userId,
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

      final inFlight = _genreRequests[cacheKey];
      if (inFlight != null) {
        debugPrint('📦 Reusing in-flight genres request for $cacheKey');
        return inFlight;
      }
    }

    final request = (() async {
      final genresJson = await client.fetchGenres(
        session.credentials,
        parentId: libraryId,
      );
      return genresJson.map((json) => JellyfinGenre.fromJson(json)).toList();
    })();
    
    _genreRequests[cacheKey] = request;

    try {
      final genres = await request;
      if (_isCurrent(session)) {
        _addToCacheWithEviction(_genreCache, _genreCacheOrder, cacheKey, genres);
      }
      return genres;
    } finally {
      _releaseInFlight(_genreRequests, cacheKey, request);
    }
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
  ///
  /// Pages a stable order (PlayCount desc, SortName asc), stops at
  /// `TotalRecordCount` or on a short page, and drops duplicates.
  Future<List<JellyfinTrack>> getAllPlayedTracks({
    required String libraryId,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final allTracks = await collectStablePages<JellyfinTrack>(
      idOf: (t) => t.id,
      pageSize: 500,
      fetchPage: ({required int startIndex, required int limit}) async {
        final page = await client.fetchItemsPage(
          session.credentials,
          query: {
            'userId': session.credentials.userId,
            'ParentId': libraryId,
            'IncludeItemTypes': 'Audio',
            'Recursive': 'true',
            'Filters': 'IsPlayed',
            'SortBy': 'PlayCount,SortName',
            'SortOrder': 'Descending,Ascending',
            'StartIndex': '$startIndex',
            'Limit': '$limit',
            'Fields': 'MediaStreams,Genres,Tags',
            'EnableImageTypes': 'Primary,Thumb',
            'EnableUserData': 'true',
          },
          timeout: const Duration(seconds: 45),
          errorLabel: 'played tracks',
        );
        return (
          items: page.items
              .map((json) => JellyfinTrack.fromJson(
                    json,
                    serverUrl: session.serverUrl,
                    token: session.credentials.accessToken,
                    userId: session.credentials.userId,
                  ))
              .toList(),
          totalRecordCount: page.totalRecordCount,
        );
      },
    );

    debugPrint('Stats: Fetched ${allTracks.length} played tracks');
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

  /// Get up to [limit] tracks from the library (random sample, with genres
  /// and tags) for smart playlists.
  ///
  /// This is ~10 requests / several MB for a large library, and every smart
  /// playlist action calls it, so the result is cached for the library cache
  /// TTL and concurrent calls share one in-flight fetch.
  Future<List<JellyfinTrack>> getAllTracks({
    required String libraryId,
    int limit = 5000,
    bool forceRefresh = false,
  }) async {
    final client = _client;
    if (client == null) throw StateError('Not connected');
    final session = _session;
    if (session == null) throw StateError('No session');

    final cacheKey = 'all_tracks_$libraryId#$limit';
    if (!forceRefresh) {
      final cached = _recentCache[cacheKey];
      if (cached != null && !cached.isExpired(_cacheTtl)) {
        return List<JellyfinTrack>.of(cached.value);
      }
      final inFlight = _allTracksRequests[cacheKey];
      if (inFlight != null) return List<JellyfinTrack>.of(await inFlight);
    }

    final request = client.fetchAllTracks(
      credentials: session.credentials,
      libraryId: libraryId,
      limit: limit,
    );
    _allTracksRequests[cacheKey] = request;
    try {
      final tracks = await request;
      // Don't cache into a session that was replaced mid-fetch.
      if (identical(_session, session)) {
        _addToCacheWithEviction(_recentCache, _recentCacheOrder, cacheKey, tracks);
      }
      return List<JellyfinTrack>.of(tracks);
    } finally {
      if (identical(_allTracksRequests[cacheKey], request)) {
        _allTracksRequests.remove(cacheKey);
      }
    }
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

  void _clearPlaylistCache() {
    _playlistCache.clear();
    _playlistCacheOrder.clear();
  }

  /// Forget in-flight request futures so a new session never reuses a
  /// request issued with the previous session's server/token.
  void _clearInFlight() {
    _albumRequests.clear();
    _artistRequests.clear();
    _playlistRequests.clear();
    _libraryRequests.clear();
    _genreRequests.clear();
    _allTracksRequests.clear();
  }

  void _clearCaches() {
    _albumCache.clear();
    _artistCache.clear();
    _clearPlaylistCache();
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

    // Evict oldest entries if at capacity (use .first instead of removeAt(0) for Sets)
    while (cache.length >= _maxCacheSize && cacheOrder.isNotEmpty) {
      final oldest = cacheOrder.first;
      cacheOrder.remove(oldest);
      cache.remove(oldest);
    }

    // Add new entry
    cache[key] = _CacheEntry(value);
    cacheOrder.add(key);
  }
}

/// Size buckets for image requests (px). Steps of ~1.25–1.5x keep the
/// over-fetch small while collapsing near-identical sizes to one URL.
const List<int> kImageSizeBuckets = [
  64, 96, 128, 160, 200, 256, 320, 400, 480, 600, 720, 800, 960, 1200,
  1440, 1600, 2000,
];

/// Rounds [px] up to the next [kImageSizeBuckets] entry (clamped to the
/// largest). Non-positive values map to the smallest bucket.
int bucketImageDimension(int px) {
  for (final bucket in kImageSizeBuckets) {
    if (px <= bucket) return bucket;
  }
  return kImageSizeBuckets.last;
}

class _CacheEntry<T> {
  _CacheEntry(this.value) : timestamp = DateTime.now();
  _CacheEntry._(this.value, this.timestamp);

  final T value;
  final DateTime timestamp;

  /// Same age, new value (in-place patch that doesn't extend the TTL).
  _CacheEntry<T> withValue(T newValue) => _CacheEntry._(newValue, timestamp);

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }
}
