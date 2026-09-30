import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'jellyfin_auth_header.dart';
import 'jellyfin_credentials.dart';
import 'jellyfin_exceptions.dart';
import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_library.dart';
import 'jellyfin_playlist.dart';
import 'jellyfin_track.dart';
import 'jellyfin_user.dart';
import 'order_by_ids.dart';
import 'paged_fetch.dart';
import 'robust_http_client.dart';
import 'server_uri.dart';

/// Lightweight Jellyfin REST client with robust HTTP handling.
/// Features: connection pooling, retry with backoff, ETag caching.
class JellyfinClient {
  JellyfinClient({
    required this.serverUrl,
    required this.deviceId,
    http.Client? httpClient,
  }) : _robustClient = RobustHttpClient(
         client: httpClient,
         maxRetries: 3,
         baseTimeout: const Duration(seconds: 15),
         enableEtagCache: true,
       );

  final String serverUrl;
  final String deviceId;
  final RobustHttpClient _robustClient;

  // For backward compatibility - returns the underlying client (not a new one)
  http.Client get httpClient => _robustClient.client;

  /// Safely decode a JSON map response, throwing a descriptive error on failure.
  Map<String, dynamic> _decodeJsonMap(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw Exception(
        'Invalid JSON response (status ${response.statusCode}): '
        '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    }
  }

  /// Bodies above this size are decoded on a background isolate so large
  /// pages (500 tracks with MediaStreams, whole playlists) don't jank the UI.
  static const int _isolateDecodeThreshold = 256 * 1024;

  /// [_decodeJsonMap], off the UI isolate for large bodies.
  Future<Map<String, dynamic>> _decodeJsonMapAsync(http.Response response) async {
    final body = response.body;
    if (body.length < _isolateDecodeThreshold) return _decodeJsonMap(response);
    try {
      return await compute(_decodeMapInIsolate, body);
    } on FormatException {
      throw Exception(
        'Invalid JSON response (status ${response.statusCode}): '
        '${body.substring(0, 200)}',
      );
    }
  }

  /// Safely decode a JSON list response, throwing a descriptive error on failure.
  List<dynamic> _decodeJsonList(http.Response response) {
    try {
      return jsonDecode(response.body) as List<dynamic>;
    } on FormatException {
      throw Exception(
        'Invalid JSON response (status ${response.statusCode}): '
        '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    }
  }

  /// Builds a URL under [serverUrl], preserving any reverse-proxy base path.
  /// Null query values are dropped; other values are stringified.
  Uri _buildUri(String path, [Map<String, dynamic>? query]) {
    final stringQuery = query == null
        ? null
        : <String, String>{
            for (final e in query.entries)
              if (e.value != null) e.key: e.value.toString(),
          };
    return buildServerUri(serverUrl, path, stringQuery);
  }

  /// Check server health before heavy operations
  Future<ServerHealth> checkServerHealth() async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = _buildUri('/System/Info/Public');
      final response = await _robustClient.get(uri, useCache: false);
      stopwatch.stop();
      
      if (response.statusCode == 200) {
        final data = _decodeJsonMap(response);
        return ServerHealth(
          isHealthy: true,
          latencyMs: stopwatch.elapsedMilliseconds,
          serverName: data['ServerName'] as String?,
          version: data['Version'] as String?,
        );
      }
      return ServerHealth(
        isHealthy: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: 'Server returned ${response.statusCode}',
      );
    } catch (e) {
      stopwatch.stop();
      return ServerHealth(
        isHealthy: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  /// Cheap single-attempt reachability probe (no retries, short timeout)
  /// against the anonymous `GET /System/Info/Public`.
  Future<bool> isReachable({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      final response = await _robustClient.client
          .get(
            _buildUri('/System/Info/Public'),
            headers: const {'Accept': 'application/json'},
          )
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<JellyfinCredentials> authenticate({
    required String username,
    required String password,
  }) async {
    final uri = _buildUri('/Users/AuthenticateByName');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(),
      body: jsonEncode({'Username': username, 'Pw': password}),
    );

    if (response.statusCode != 200) {
      throw JellyfinAuthException(
        'Authentication failed: ${response.statusCode}',
      );
    }

    final data = _decodeJsonMap(response);
    final accessToken = data['AccessToken'] as String?;
    final user = data['User'] as Map<String, dynamic>?;

    if (accessToken == null || user == null) {
      throw JellyfinAuthException('Malformed authentication response.');
    }

    return JellyfinCredentials(
      accessToken: accessToken,
      userId: user['Id'] as String? ?? '',
    );
  }

  Future<List<JellyfinUser>> fetchUsers(JellyfinCredentials credentials) async {
    final uri = _buildUri('/Users');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch users: ${response.statusCode}',
      );
    }

    final data = _decodeJsonList(response);
    return data
        .whereType<Map<String, dynamic>>()
        .map(JellyfinUser.fromJson)
        .toList();
  }

  /// Fetches the current user's profile info including profile image tag.
  Future<JellyfinUser> fetchCurrentUser(JellyfinCredentials credentials) async {
    final uri = _buildUri('/Users/${credentials.userId}');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch user profile: ${response.statusCode}',
      );
    }

    final data = _decodeJsonMap(response);
    return JellyfinUser.fromJson(data);
  }

  /// Builds the URL for a user's profile image.
  ///
  /// Uses the spec-documented `GET /UserImage?userId=…&tag=…` (present in the
  /// 10.11.9 and 12.1.0 OpenAPI specs — see docs/jellyfin-openapi-12.1.json;
  /// the old `/Users/{id}/Images/Primary` alias is absent from both).
  String? getUserImageUrl(String userId, String? imageTag) {
    if (imageTag == null) return null;
    return buildServerUrl(serverUrl, '/UserImage', {
      'userId': userId,
      'tag': imageTag,
    });
  }

  /// Fetches the user's library list (a.k.a. "views"). Uses the
  /// spec-documented `/UserViews?userId=...` endpoint (10.9+) — the
  /// older `/Users/{id}/Views` alias was undocumented and was retired here
  /// during the v8.9.5 cleanup. Verified against the 12.1.0 spec in
  /// docs/jellyfin-openapi-12.1.json.
  Future<List<JellyfinLibrary>> fetchLibraries(
    JellyfinCredentials credentials,
  ) async {
    final uri = _buildUri('/UserViews', {
      'userId': credentials.userId,
    });
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch libraries: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinLibrary.fromJson)
        .toList();
  }

  /// Browse methods use the spec-documented `GET /Items?userId=…` (the
  /// legacy `/Users/{userId}/Items` alias is absent from the 10.11.9 and
  /// 12.1.0 OpenAPI specs; see docs/jellyfin-openapi-12.1.json).
  Future<List<JellyfinAlbum>> fetchAlbums({
    required JellyfinCredentials credentials,
    required String libraryId,
    String? genreIds,
    int startIndex = 0,
    int limit = 50,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    final queryParams = {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags,Genres,GenreItems',
      'StartIndex': startIndex.toString(),
      'Limit': limit.toString(),
    };
    
    if (genreIds != null) {
      queryParams['GenreIds'] = genreIds;
    }
    
    final uri = _buildUri('/Items', queryParams);

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch albums: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinAlbum.fromJson)
        .toList();
  }

  Future<List<JellyfinArtist>> fetchArtists({
    required JellyfinCredentials credentials,
    required String libraryId,
    int startIndex = 0,
    int limit = 50,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
  }) async {
    // `GET /Artists` is marked deprecated in 12.x ("Use GetPersons"), but it
    // still works for the whole 12.x cycle (deprecations last a full major
    // cycle) and there is no drop-in replacement that also works on 10.11:
    // `/Persons` has no sortBy/sortOrder (the Artists tab sorts) and on
    // 10.11 queries the People table (actors, composers…), not MusicArtist
    // items. Revisit once 10.11 support is dropped.
    // `userId` makes the server attach UserData (IsFavorite, PlayCount).
    final uri = _buildUri('/Artists', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'Fields': 'PrimaryImageAspectRatio,ImageTags,Overview,Genres,ChildCount,SongCount,ProviderIds',
      'StartIndex': startIndex.toString(),
      'Limit': limit.toString(),
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch artists: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinArtist.fromJson)
        .toList();
  }

  Future<List<JellyfinAlbum>> fetchAlbumsByArtist({
    required JellyfinCredentials credentials,
    required String artistId,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ArtistIds': artistId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'ProductionYear,SortName',
      'SortOrder': 'Descending',
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags,Genres,GenreItems',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch albums by artist: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinAlbum.fromJson)
        .toList();
  }

  Future<List<JellyfinPlaylist>> fetchPlaylists({
    required JellyfinCredentials credentials,
    String? libraryId,
  }) async {
    final queryParams = <String, String>{
      'userId': credentials.userId,
      'IncludeItemTypes': 'Playlist',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'Fields': 'ChildCount,ImageTags,DateCreated',
    };
    
    // Only filter by library if specified (optional)
    if (libraryId != null) {
      queryParams['ParentId'] = libraryId;
    }
    
    final uri = _buildUri('/Items', queryParams);

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch playlists: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinPlaylist.fromJson)
        .toList();
  }

  /// `POST /Playlists/{playlistId}/Items/{itemId}/Move/{newIndex}`.
  /// [itemId] is the entry's `PlaylistItemId` (on 10.11 and 12.1 that is the
  /// item id in `N` format). The endpoint takes no query parameters; the
  /// calling user comes from the token.
  Future<void> movePlaylistItem({
    required JellyfinCredentials credentials,
    required String playlistId,
    required String itemId,
    required int newIndex,
  }) async {
    final uri = _buildUri('/Playlists/$playlistId/Items/$itemId/Move/$newIndex');

    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to move playlist item: ${response.statusCode}',
      );
    }
  }

  Future<List<JellyfinTrack>> fetchTracksByIds({
    required JellyfinCredentials credentials,
    required List<String> ids,
  }) async {
    if (ids.isEmpty) {
      return const [];
    }

    // Large id lists (a remote "Play" of an artist expands to thousands of
    // track ids) would exceed request-line limits (414): fetch in chunks.
    final tracks = <JellyfinTrack>[];
    for (final chunk in chunkIds(ids.toSet().toList())) {
      final uri = _buildUri('/Items', {
        'userId': credentials.userId,
        'Ids': chunk.join(','),
        'Fields': 'RunTimeTicks,Albums,Album,Artists,ImageTags,AlbumPrimaryImageTag,ParentThumbImageTag,IndexNumber,ParentIndexNumber,UserData,MediaStreams,Tags,ProviderIds',
        'IncludeItemTypes': 'Audio',
      });

      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode != 200) {
        throw JellyfinRequestException(
          'Unable to fetch tracks: ${response.statusCode}',
        );
      }

      final data =
          response.body.isNotEmpty ? await _decodeJsonMapAsync(response) : null;
      final items = data?['Items'] as List<dynamic>? ?? const [];

      tracks.addAll(items
          .whereType<Map<String, dynamic>>()
          .map((json) => JellyfinTrack.fromJson(
                json,
                serverUrl: serverUrl,
                token: credentials.accessToken,
                userId: credentials.userId,
              )));
    }
    // Jellyfin returns Ids results in its own order; callers (queue restore,
    // "On This Day") rely on the requested order.
    return orderByIds(ids, tracks, (t) => t.id);
  }

  Future<List<JellyfinTrack>> fetchRecentTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 20,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch recent tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Future<List<JellyfinTrack>> fetchRecentlyPlayedTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 20,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DatePlayed',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Filters': 'IsPlayed',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch recently played tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Future<List<JellyfinAlbum>> fetchRecentlyAddedAlbums({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 20,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields': 'Artists,DateCreated,ProductionYear',
      'EnableImageTypes': 'Primary',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch recently added albums: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinAlbum.fromJson(json))
        .toList();
  }

  Future<List<JellyfinTrack>> fetchAlbumTracks({
    required JellyfinCredentials credentials,
    required String albumId,
    bool recursive = true,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': albumId,
      'IncludeItemTypes': 'Audio',
      'Recursive': recursive ? 'true' : 'false',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'SortOrder': 'Ascending',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch album tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Future<List<JellyfinTrack>> fetchAlbumTracksByAlbumIds({
    required JellyfinCredentials credentials,
    required String albumId,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'AlbumIds': albumId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'SortOrder': 'Ascending',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch album tracks via AlbumIds: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Future<List<JellyfinAlbum>> searchAlbums({
    required JellyfinCredentials credentials,
    required String libraryId,
    required String query,
    int? limit,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SearchTerm': query,
      if (limit != null) 'Limit': '$limit',
      'SortBy': 'SortName',
      'Fields':
          'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags,Tags',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to search albums: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinAlbum.fromJson)
        .toList();
  }

  Future<List<JellyfinArtist>> searchArtists({
    required JellyfinCredentials credentials,
    required String libraryId,
    required String query,
    int? limit,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicArtist',
      'Recursive': 'true',
      'SearchTerm': query,
      if (limit != null) 'Limit': '$limit',
      'SortBy': 'SortName',
      'Fields': 'ImageTags,Overview,Genres,ChildCount,SongCount,ProviderIds',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to search artists: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinArtist.fromJson)
        .toList();
  }
  
  Future<List<JellyfinTrack>> searchTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    required String query,
    int? limit,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SearchTerm': query,
      if (limit != null) 'Limit': '$limit',
      'SortBy': 'Album,ParentIndexNumber,IndexNumber,SortName',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags,ProviderIds',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to search tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Map<String, String> _defaultHeaders([JellyfinCredentials? credentials]) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      ...nautuneAuthHeaders(
        deviceId: deviceId,
        token: credentials?.accessToken,
      ),
    };
  }

  // Generic HTTP methods for playlist management
  Future<Map<String, dynamic>> request({
    required String method,
    required String path,
    required JellyfinCredentials credentials,
    Map<String, dynamic>? queryParams,
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    final uri = _buildUri(path, queryParams?.map((k, v) => MapEntry(k, v.toString())));
    
    http.Response response;
    final headers = _defaultHeaders(credentials);
    
    switch (method.toUpperCase()) {
      case 'GET':
        response =
            await _robustClient.get(uri, headers: headers, timeout: timeout);
        break;
      case 'POST':
        response = await _robustClient.post(
          uri,
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
          timeout: timeout,
        );
        break;
      case 'DELETE':
        response = await _robustClient.delete(
          uri,
          headers: headers,
          timeout: timeout,
        );
        break;
      default:
        throw ArgumentError('Unsupported HTTP method: $method');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('❌ Jellyfin API error: ${response.statusCode}');
      // Note: Response body not logged to avoid leaking sensitive data
      throw JellyfinRequestException(
        'Request failed with status ${response.statusCode}',
      );
    }

    debugPrint('✅ Jellyfin API success: ${response.statusCode}');
    
    if (response.body.isEmpty) {
      debugPrint('ℹ️  Empty response body');
      return {};
    }

    return _decodeJsonMapAsync(response);
  }

  /// Revokes [credentials]' access token on the server
  /// (`POST /Sessions/Logout`). Best effort: a single attempt with a short
  /// timeout; failures are swallowed (the local logout proceeds anyway).
  /// Returns whether the server confirmed the logout.
  Future<bool> logout(
    JellyfinCredentials credentials, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (credentials.accessToken.isEmpty) return false;
    try {
      final response = await _robustClient.client
          .post(
            _buildUri('/Sessions/Logout'),
            headers: _defaultHeaders(credentials),
          )
          .timeout(timeout);
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (e) {
      debugPrint('Jellyfin logout (token revoke) failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Fetches genres for a library
  Future<List<Map<String, dynamic>>> fetchGenres(
    JellyfinCredentials credentials, {
    String? parentId,
    String? searchTerm,
    int? limit,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': ?parentId,
      'SearchTerm': ?searchTerm,
      if (limit != null) 'Limit': limit.toString(),
    };

    final uri = _buildUri('/Genres', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch genres: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Gets instant mix based on an item (track, album, or artist)
  Future<List<Map<String, dynamic>>> fetchInstantMix(
    JellyfinCredentials credentials, {
    required String itemId,
    int limit = 200,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'Limit': limit.toString(),
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
    };

    final uri = _buildUri('/Items/$itemId/InstantMix', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch instant mix: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetches random tracks by artist ID (for artist instant mix)
  Future<List<Map<String, dynamic>>> fetchTracksByArtist(
    JellyfinCredentials credentials, {
    required String artistId,
    int limit = 50,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ArtistIds': artistId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'Random',
      'Limit': '$limit',
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch tracks by artist: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetches most played items (tracks, albums, or artists)
  Future<List<Map<String, dynamic>>> fetchMostPlayed(
    JellyfinCredentials credentials, {
    required String libraryId,
    String itemType = 'Audio', // 'Audio', 'MusicAlbum', 'MusicArtist'
    int limit = 50,
    int startIndex = 0,
    bool filterPlayed = false,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': itemType,
      // SortName tie-breaker keeps StartIndex pages from overlapping when
      // many items share a play count.
      'SortBy': 'PlayCount,SortName',
      'SortOrder': 'Descending,Ascending',
      'Recursive': 'true',
      'StartIndex': startIndex.toString(),
      'Limit': limit.toString(),
      if (filterPlayed) 'Filters': 'IsPlayed',
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,UserData,Genres,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    };

    final uri = _buildUri('/Items', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch most played: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch least played (discovery) items from Jellyfin
  Future<List<Map<String, dynamic>>> fetchLeastPlayed(
    JellyfinCredentials credentials, {
    required String libraryId,
    String itemType = 'Audio',
    int maxPlayCount = 3,
    int limit = 50,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': itemType,
      'SortBy': 'Random', // Randomize to discover different tracks each time
      'Recursive': 'true',
      'Limit': limit.toString(),
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,UserData,Genres,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    };

    final uri = _buildUri('/Items', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch least played: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    // Filter by play count client-side (Jellyfin doesn't have a MaxPlayCount filter)
    return items.whereType<Map<String, dynamic>>().where((item) {
      final userData = item['UserData'] as Map<String, dynamic>?;
      final playCount = userData?['PlayCount'] as int? ?? 0;
      return playCount < maxPlayCount;
    }).toList();
  }

  /// Fetch a single item by ID
  Future<Map<String, dynamic>?> fetchItem(
    JellyfinCredentials credentials, {
    required String itemId,
  }) async {
    // `GET /Items/{itemId}` only takes `userId`; it always returns every
    // field (incl. MediaStreams, Genres, ItemCounts) plus UserData.
    final uri = _buildUri('/Items/$itemId', {'userId': credentials.userId});
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch item: ${response.statusCode}',
      );
    }

    return response.body.isNotEmpty ? _decodeJsonMap(response) : null;
  }

  Future<List<JellyfinTrack>> fetchRecentlyAddedTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 50,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch recently added tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  Future<List<JellyfinTrack>> fetchLongestRuntimeTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 50,
  }) async {
    final uri = _buildUri('/Items', {
      'userId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'Runtime',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch longest runtime tracks: ${response.statusCode}',
      );
    }

    final data = response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map((json) => JellyfinTrack.fromJson(
              json,
              serverUrl: serverUrl,
              token: credentials.accessToken,
              userId: credentials.userId,
            ))
        .toList();
  }

  /// Fetch up to [limit] tracks from a library, in random order, with genre
  /// and tag information for smart playlists.
  ///
  /// `SortBy=Random` is re-shuffled on every request, so it can't be paged
  /// with `StartIndex` (pages overlap and items get skipped); see
  /// [collectRandomSample] for how pages are combined.
  Future<List<JellyfinTrack>> fetchAllTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 5000,
  }) {
    return collectRandomSample<JellyfinTrack>(
      limit: limit,
      idOf: (t) => t.id,
      fetchPage: ({
        required int startIndex,
        required int limit,
        required bool random,
      }) async {
        final page = await fetchItemsPage(
          credentials,
          query: {
            'userId': credentials.userId,
            'ParentId': libraryId,
            'IncludeItemTypes': 'Audio',
            'Recursive': 'true',
            // Stable order: SortName with DateCreated as tie-breaker.
            'SortBy': random ? 'Random' : 'SortName,DateCreated',
            'SortOrder': 'Ascending',
            'Limit': '$limit',
            'StartIndex': '$startIndex',
            'Fields': 'MediaStreams,Genres,Tags',
            'EnableImageTypes': 'Primary,Thumb',
            'EnableUserData': 'true',
          },
          timeout: _bulkTimeout,
          errorLabel: 'all tracks',
        );
        return (
          items: page.items.map(_trackFromJson(credentials)).toList(),
          totalRecordCount: page.totalRecordCount,
        );
      },
    );
  }

  /// Timeout for bulk pages (up to 500 items with MediaStreams). The default
  /// 15 s covers the whole response body, which a slow server or cellular
  /// link can exceed for large pages.
  static const Duration _bulkTimeout = Duration(seconds: 45);

  JellyfinTrack Function(Map<String, dynamic>) _trackFromJson(
    JellyfinCredentials credentials,
  ) {
    return (json) => JellyfinTrack.fromJson(
          json,
          serverUrl: serverUrl,
          token: credentials.accessToken,
          userId: credentials.userId,
        );
  }

  /// `GET /Items` returning one page plus `TotalRecordCount`.
  Future<JellyfinPage<Map<String, dynamic>>> fetchItemsPage(
    JellyfinCredentials credentials, {
    required Map<String, String> query,
    Duration? timeout,
    String errorLabel = 'items',
  }) async {
    final response = await _robustClient.get(
      _buildUri('/Items', query),
      headers: _defaultHeaders(credentials),
      timeout: timeout,
    );
    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch $errorLabel: ${response.statusCode}',
      );
    }
    final data =
        response.body.isNotEmpty ? await _decodeJsonMapAsync(response) : null;
    final items = (data?['Items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final total = data?['TotalRecordCount'];
    return (items: items, totalRecordCount: total is int ? total : null);
  }

  /// Fetch lyrics for a track
  /// Returns a map with 'Lyrics' (List<Map>) containing lyric lines
  /// Each line has 'Start' (timestamp in ticks) and 'Text'.
  /// Returns null when the track has no lyrics (404); throws on other
  /// failures (network, 5xx, auth).
  Future<Map<String, dynamic>?> fetchLyrics({
    required JellyfinCredentials credentials,
    required String itemId,
  }) async {
    final uri = _buildUri('/Audio/$itemId/Lyrics');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode == 404) {
      // No lyrics available for this track
      return null;
    }

    if (response.statusCode != 200) {
      // Not "no lyrics": a server/auth problem. Throw so callers don't
      // remember this track as having no lyrics.
      throw JellyfinRequestException(
        'Unable to fetch lyrics: ${response.statusCode}',
      );
    }

    try {
      return response.body.isNotEmpty ? _decodeJsonMap(response) : null;
    } catch (e) {
      debugPrint('⚠️ Failed to parse lyrics: $e');
      return null;
    }
  }
  
  // ============ User Play Data API ============

  /// Mark an item as played with optional date
  /// Uses: POST /UserPlayedItems/{itemId}?datePlayed={timestamp}
  /// Returns UserItemDataDto with updated PlayCount/LastPlayedDate
  Future<Map<String, dynamic>?> markPlayed({
    required JellyfinCredentials credentials,
    required String itemId,
    DateTime? datePlayed,
  }) async {
    final queryParams = <String, String>{};
    if (datePlayed != null) {
      queryParams['datePlayed'] = datePlayed.toUtc().toIso8601String();
    }

    final uri = _buildUri('/UserPlayedItems/$itemId', queryParams);

    try {
      final response = await _robustClient.post(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Marked item $itemId as played');
        return response.body.isNotEmpty ? _decodeJsonMap(response) : null;
      } else {
        debugPrint('⚠️ Failed to mark played: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error marking played: $e');
      return null;
    }
  }

  /// Mark an item as unplayed
  /// Uses: DELETE /UserPlayedItems/{itemId}
  Future<bool> markUnplayed({
    required JellyfinCredentials credentials,
    required String itemId,
  }) async {
    final uri = _buildUri('/UserPlayedItems/$itemId');

    try {
      final response = await _robustClient.delete(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Marked item $itemId as unplayed');
        return true;
      } else {
        debugPrint('⚠️ Failed to mark unplayed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Error marking unplayed: $e');
      return false;
    }
  }

  /// Get user data for a specific item (PlayCount, LastPlayedDate, IsFavorite, etc.)
  /// Uses: GET /UserItems/{itemId}/UserData
  Future<Map<String, dynamic>?> getUserItemData({
    required JellyfinCredentials credentials,
    required String itemId,
  }) async {
    final uri = _buildUri('/UserItems/$itemId/UserData');

    try {
      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        return response.body.isNotEmpty ? _decodeJsonMap(response) : null;
      } else if (response.statusCode == 404) {
        return null; // Item not found
      } else {
        debugPrint('⚠️ Failed to get user item data: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ Error getting user item data: $e');
      return null;
    }
  }

  /// Get user data for multiple items at once (batch)
  /// Uses: GET /Items?userId=… with EnableUserData=true
  /// Returns map of itemId -> UserItemData
  Future<Map<String, Map<String, dynamic>>> getBatchUserItemData({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return {};

    final result = <String, Map<String, dynamic>>{};
    for (final chunk in chunkIds(itemIds.toSet().toList())) {
      final uri = _buildUri('/Items', {
        'userId': credentials.userId,
        'Ids': chunk.join(','),
        'EnableUserData': 'true',
        'Fields': 'UserData',
      });

      try {
        final response = await _robustClient.get(
          uri,
          headers: _defaultHeaders(credentials),
        );

        if (response.statusCode == 200) {
          final data = response.body.isNotEmpty
              ? await _decodeJsonMapAsync(response)
              : null;
          final items = data?['Items'] as List<dynamic>? ?? [];

          for (final item in items) {
            if (item is Map<String, dynamic>) {
              final id = item['Id'] as String?;
              final userData = item['UserData'] as Map<String, dynamic>?;
              if (id != null && userData != null) {
                result[id] = userData;
              }
            }
          }
        } else {
          debugPrint('⚠️ Failed to get batch user data: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('❌ Error getting batch user data: $e');
      }
    }
    return result;
  }

  /// Get full item data for multiple items at once (batch) - includes track metadata
  /// Uses: GET /Items?userId=… with all fields needed for analytics
  /// Returns map of itemId -> Full item data (name, artists, genres, duration, userData, etc.)
  Future<Map<String, Map<String, dynamic>>> getBatchItemsWithFullData({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return {};

    final result = <String, Map<String, dynamic>>{};
    for (final chunk in chunkIds(itemIds.toSet().toList())) {
      final uri = _buildUri('/Items', {
        'userId': credentials.userId,
        'Ids': chunk.join(','),
        'EnableUserData': 'true',
        'Fields': 'UserData,Artists,Genres,RunTimeTicks,Album,AlbumId,Tags',
      });

      try {
        final response = await _robustClient.get(
          uri,
          headers: _defaultHeaders(credentials),
        );

        if (response.statusCode == 200) {
          final data = response.body.isNotEmpty
              ? await _decodeJsonMapAsync(response)
              : null;
          final items = data?['Items'] as List<dynamic>? ?? [];

          for (final item in items) {
            if (item is Map<String, dynamic>) {
              final id = item['Id'] as String?;
              if (id != null) {
                // Return the full item data, not just userData
                result[id] = item;
              }
            }
          }
        } else {
          debugPrint('⚠️ Failed to get batch user data: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('❌ Error getting batch user data: $e');
      }
    }
    return result;
  }

  /// Clear the HTTP cache (ETag/Last-Modified)
  void clearHttpCache() {
    _robustClient.clearCache();
  }

  /// Close the HTTP client
  void close() {
    _robustClient.close();
  }
}

Map<String, dynamic> _decodeMapInIsolate(String body) =>
    jsonDecode(body) as Map<String, dynamic>;

/// Server health check result
class ServerHealth {
  final bool isHealthy;
  final int latencyMs;
  final String? serverName;
  final String? version;
  final String? error;

  ServerHealth({
    required this.isHealthy,
    required this.latencyMs,
    this.serverName,
    this.version,
    this.error,
  });

  bool get isSlow => latencyMs > 2000;
  
  @override
  String toString() => isHealthy 
    ? 'ServerHealth(healthy, ${latencyMs}ms, $serverName v$version)'
    : 'ServerHealth(unhealthy, ${latencyMs}ms, error: $error)';
}
