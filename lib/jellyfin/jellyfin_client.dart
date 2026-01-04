import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'jellyfin_credentials.dart';
import 'jellyfin_exceptions.dart';
import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_library.dart';
import 'jellyfin_playlist.dart';
import 'jellyfin_track.dart';
import 'jellyfin_user.dart';
import 'robust_http_client.dart';

/// Lightweight Jellyfin REST client with robust HTTP handling.
/// Features: connection pooling, retry with backoff, ETag caching.
class JellyfinClient {
  JellyfinClient({
    required this.serverUrl,
    http.Client? httpClient,
  }) : _robustClient = RobustHttpClient(
         client: httpClient,
         maxRetries: 3,
         baseTimeout: const Duration(seconds: 15),
         enableEtagCache: true,
       );

  final String serverUrl;
  final RobustHttpClient _robustClient;
  
  // For backward compatibility
  http.Client get httpClient => http.Client();

  Uri _buildUri(String path, [Map<String, dynamic>? query]) {
    return Uri.parse(serverUrl).resolve(path).replace(queryParameters: query);
  }

  /// Check server health before heavy operations
  Future<ServerHealth> checkServerHealth() async {
    final stopwatch = Stopwatch()..start();
    try {
      final uri = _buildUri('/System/Info/Public');
      final response = await _robustClient.get(uri, useCache: false);
      stopwatch.stop();
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
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

    final data = jsonDecode(response.body) as Map<String, dynamic>;
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

    final data = jsonDecode(response.body) as List<dynamic>;
    return data
        .whereType<Map<String, dynamic>>()
        .map(JellyfinUser.fromJson)
        .toList();
  }

  Future<List<JellyfinLibrary>> fetchLibraries(
    JellyfinCredentials credentials,
  ) async {
    final uri = _buildUri('/Users/${credentials.userId}/Views');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch libraries: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinLibrary.fromJson)
        .toList();
  }

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
    
    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch albums: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Artists', {
      'ParentId': libraryId,
      'Recursive': 'true',
      'SortBy': sortBy,
      'SortOrder': sortOrder,
      'Fields': 'PrimaryImageAspectRatio,ImageTags,Overview,Genres,ChildCount,SongCount',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
      'IncludeItemTypes': 'Playlist',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'Fields': 'ChildCount,ImageTags',
    };
    
    // Only filter by library if specified (optional)
    if (libraryId != null) {
      queryParams['ParentId'] = libraryId;
    }
    
    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch playlists: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items
        .whereType<Map<String, dynamic>>()
        .map(JellyfinPlaylist.fromJson)
        .toList();
  }

  Future<List<JellyfinTrack>> fetchTracksByIds({
    required JellyfinCredentials credentials,
    required List<String> ids,
  }) async {
    if (ids.isEmpty) {
      return const [];
    }

    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'Ids': ids.join(','),
      'Fields': 'RunTimeTicks,Albums,Album,Artists,ImageTags,AlbumPrimaryImageTag,ParentThumbImageTag,IndexNumber,ParentIndexNumber,UserData,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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

  Future<List<JellyfinTrack>> fetchRecentTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 20,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DatePlayed',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Filters': 'IsPlayed',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': albumId,
      'IncludeItemTypes': 'Audio',
      'Recursive': recursive ? 'true' : 'false',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'SortOrder': 'Ascending',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'AlbumIds': albumId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'SortOrder': 'Ascending',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SearchTerm': query,
      'SortBy': 'SortName',
      'Fields':
          'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicArtist',
      'Recursive': 'true',
      'SearchTerm': query,
      'SortBy': 'SortName',
      'Fields': 'ImageTags,Overview,Genres,ChildCount,SongCount',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SearchTerm': query,
      'SortBy': 'Album,ParentIndexNumber,IndexNumber,SortName',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Emby-Authorization': 'MediaBrowser Client="Nautune", Device="Linux", '
          'DeviceId="nautune-dev", Version="0.1.0"',
    };

    if (credentials != null) {
      headers['X-MediaBrowser-Token'] = credentials.accessToken;
    }

    return headers;
  }

  // Generic HTTP methods for playlist management
  Future<Map<String, dynamic>> request({
    required String method,
    required String path,
    required JellyfinCredentials credentials,
    Map<String, dynamic>? queryParams,
    Map<String, dynamic>? body,
  }) async {
    final uri = _buildUri(path, queryParams?.map((k, v) => MapEntry(k, v.toString())));
    
    http.Response response;
    final headers = _defaultHeaders(credentials);
    
    switch (method.toUpperCase()) {
      case 'GET':
        response = await _robustClient.get(uri, headers: headers);
        break;
      case 'POST':
        response = await _robustClient.post(
          uri,
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        );
        break;
      case 'DELETE':
        response = await _robustClient.delete(uri, headers: headers);
        break;
      default:
        throw ArgumentError('Unsupported HTTP method: $method');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      debugPrint('❌ Jellyfin API error: ${response.statusCode}');
      debugPrint('❌ Response body: ${response.body}');
      throw JellyfinRequestException(
        'Request failed: ${response.statusCode} ${response.body}',
      );
    }

    debugPrint('✅ Jellyfin API success: ${response.statusCode}');
    
    if (response.body.isEmpty) {
      debugPrint('ℹ️  Empty response body');
      return {};
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
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
      if (parentId != null) 'ParentId': parentId,
      if (searchTerm != null) 'SearchTerm': searchTerm,
      if (limit != null) 'Limit': limit.toString(),
      'Recursive': 'true',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetches playback info for an item
  Future<Map<String, dynamic>> fetchPlaybackInfo(
    JellyfinCredentials credentials, {
    required String itemId,
  }) async {
    final uri = _buildUri('/Items/$itemId/PlaybackInfo');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'UserId': credentials.userId,
        'DeviceProfile': {
          'MaxStreamingBitrate': 140000000,
        },
      }),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch playback info: ${response.statusCode}',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Fetches most played items (tracks, albums, or artists)
  Future<List<Map<String, dynamic>>> fetchMostPlayed(
    JellyfinCredentials credentials, {
    required String libraryId,
    String itemType = 'Audio', // 'Audio', 'MusicAlbum', 'MusicArtist'
    int limit = 50,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': itemType,
      'SortBy': 'PlayCount',
      'SortOrder': 'Descending',
      'Recursive': 'true',
      'Limit': limit.toString(),
      'Filters': 'IsPlayed',
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
      'EnableImageTypes': 'Primary,Thumb',
    };

    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch most played: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  Future<List<JellyfinTrack>> fetchRecentlyAddedTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 50,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'Runtime',
      'SortOrder': 'Descending',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams',
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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

  /// Fetch lyrics for a track
  /// Returns a map with 'Lyrics' (List<Map>) containing lyric lines
  /// Each line has 'Start' (timestamp in ticks) and 'Text'
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
      debugPrint('⚠️ Failed to fetch lyrics: ${response.statusCode}');
      return null;
    }

    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>?;
      return data;
    } catch (e) {
      debugPrint('⚠️ Failed to parse lyrics: $e');
      return null;
    }
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
