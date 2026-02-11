import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';
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

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return JellyfinUser.fromJson(data);
  }

  /// Builds the URL for a user's profile image.
  String? getUserImageUrl(String userId, String? imageTag) {
    if (imageTag == null) return null;
    return '$serverUrl/Users/$userId/Images/Primary?tag=$imageTag';
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

  Future<void> movePlaylistItem({
    required JellyfinCredentials credentials,
    required String playlistId,
    required String itemId,
    required int newIndex,
  }) async {
    final uri = _buildUri('/Playlists/$playlistId/Items/$itemId/Move/$newIndex', {
      'UserId': credentials.userId,
    });

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

    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'Ids': ids.join(','),
      'Fields': 'RunTimeTicks,Albums,Album,Artists,ImageTags,AlbumPrimaryImageTag,ParentThumbImageTag,IndexNumber,ParentIndexNumber,UserData,MediaStreams,Tags',
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
      'X-Emby-Authorization': 'MediaBrowser Client="Nautune", Device="${defaultTargetPlatform.name}", '
          'DeviceId="$deviceId", Version="${AppVersion.current}"',
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
      'ParentId': ?parentId,
      'SearchTerm': ?searchTerm,
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

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    final items = data?['Items'] as List<dynamic>? ?? const [];

    return items.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetches random tracks by artist ID (for artist instant mix)
  Future<List<Map<String, dynamic>>> fetchTracksByArtist(
    JellyfinCredentials credentials, {
    required String artistId,
    int limit = 50,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
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
    int startIndex = 0,
    bool filterPlayed = false,
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': itemType,
      'SortBy': 'PlayCount',
      'SortOrder': 'Descending',
      'Recursive': 'true',
      'StartIndex': startIndex.toString(),
      'Limit': limit.toString(),
      if (filterPlayed) 'Filters': 'IsPlayed',
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,UserData,Genres,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
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

  /// Returns the total number of played items in the library.
  Future<int> fetchPlayedItemCount(
    JellyfinCredentials credentials, {
    required String libraryId,
    String itemType = 'Audio',
  }) async {
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'ParentId': libraryId,
      'IncludeItemTypes': itemType,
      'SortBy': 'PlayCount',
      'SortOrder': 'Descending',
      'Recursive': 'true',
      'Limit': '0',
      'Filters': 'IsPlayed',
      'EnableUserData': 'true',
    };

    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) return 0;

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
    return (data?['TotalRecordCount'] as int?) ?? 0;
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

    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch least played: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>?;
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
    final queryParams = <String, String>{
      'UserId': credentials.userId,
      'Fields': 'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,UserData,Genres,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    };

    final uri = _buildUri('/Users/${credentials.userId}/Items/$itemId', queryParams);
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

    return jsonDecode(response.body) as Map<String, dynamic>?;
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

  /// Fetch all tracks from a library with genre information for smart playlists
  Future<List<JellyfinTrack>> fetchAllTracks({
    required JellyfinCredentials credentials,
    required String libraryId,
    int limit = 5000,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'SortBy': 'Random',
      'Limit': '$limit',
      'Fields':
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber,MediaStreams,Genres,Tags',
      'EnableImageTypes': 'Primary,Thumb',
      'EnableUserData': 'true',
    });

    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch all tracks: ${response.statusCode}',
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
        return jsonDecode(response.body) as Map<String, dynamic>?;
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
        return jsonDecode(response.body) as Map<String, dynamic>?;
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
  /// Uses: GET /Users/{userId}/Items with EnableUserData=true
  /// Returns map of itemId -> UserItemData
  Future<Map<String, Map<String, dynamic>>> getBatchUserItemData({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return {};

    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'Ids': itemIds.join(','),
      'EnableUserData': 'true',
      'Fields': 'UserData',
    });

    try {
      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final items = data?['Items'] as List<dynamic>? ?? [];

        final result = <String, Map<String, dynamic>>{};
        for (final item in items) {
          if (item is Map<String, dynamic>) {
            final id = item['Id'] as String?;
            final userData = item['UserData'] as Map<String, dynamic>?;
            if (id != null && userData != null) {
              result[id] = userData;
            }
          }
        }
        return result;
      } else {
        debugPrint('⚠️ Failed to get batch user data: ${response.statusCode}');
        return {};
      }
    } catch (e) {
      debugPrint('❌ Error getting batch user data: $e');
      return {};
    }
  }

  /// Get full item data for multiple items at once (batch) - includes track metadata
  /// Uses: GET /Users/{userId}/Items with all fields needed for analytics
  /// Returns map of itemId -> Full item data (name, artists, genres, duration, userData, etc.)
  Future<Map<String, Map<String, dynamic>>> getBatchItemsWithFullData({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return {};

    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'Ids': itemIds.join(','),
      'EnableUserData': 'true',
      'Fields': 'UserData,Artists,Genres,RunTimeTicks,Album,AlbumId,Tags',
    });

    try {
      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>?;
        final items = data?['Items'] as List<dynamic>? ?? [];

        final result = <String, Map<String, dynamic>>{};
        for (final item in items) {
          if (item is Map<String, dynamic>) {
            final id = item['Id'] as String?;
            if (id != null) {
              // Return the full item data, not just userData
              result[id] = item;
            }
          }
        }
        return result;
      } else {
        debugPrint('⚠️ Failed to get batch user data: ${response.statusCode}');
        return {};
      }
    } catch (e) {
      debugPrint('❌ Error getting batch user data: $e');
      return {};
    }
  }

  // ============ Sessions API (Helm Mode) ============

  /// Fetch all active sessions from the server.
  /// GET /Sessions
  Future<List<Map<String, dynamic>>> fetchSessions(
    JellyfinCredentials credentials,
  ) async {
    final uri = _buildUri('/Sessions');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
      useCache: false,
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Unable to fetch sessions: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as List<dynamic>? ?? [];
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// Send a playstate command to a remote session.
  /// POST /Sessions/{sessionId}/Playing/{command}
  /// Commands: PlayPause, Pause, Unpause, NextTrack, PreviousTrack, Seek
  Future<void> sendPlaystateCommand(
    JellyfinCredentials credentials, {
    required String sessionId,
    required String command,
    int? seekPositionTicks,
  }) async {
    final queryParams = <String, String>{};
    if (seekPositionTicks != null) {
      queryParams['SeekPositionTicks'] = seekPositionTicks.toString();
    }

    final uri = _buildUri(
      '/Sessions/$sessionId/Playing/$command',
      queryParams.isNotEmpty ? queryParams : null,
    );
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to send playstate command "$command": ${response.statusCode}',
      );
    }
  }

  /// Send a play command to a remote session (play specific items).
  /// POST /Sessions/{sessionId}/Playing
  Future<void> sendPlayCommand(
    JellyfinCredentials credentials, {
    required String sessionId,
    required List<String> itemIds,
    String playCommand = 'PlayNow',
    int? startIndex,
  }) async {
    final queryParams = <String, String>{
      'ItemIds': itemIds.join(','),
      'PlayCommand': playCommand,
    };
    if (startIndex != null) {
      queryParams['StartIndex'] = startIndex.toString();
    }

    final uri = _buildUri('/Sessions/$sessionId/Playing', queryParams);
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to send play command: ${response.statusCode}',
      );
    }
  }

  /// Report session capabilities to the server.
  /// POST /Sessions/Capabilities/Full
  /// This tells the server that this client supports remote control,
  /// enabling Helm Mode commands to be pushed via WebSocket.
  Future<void> reportCapabilities(JellyfinCredentials credentials) async {
    final uri = _buildUri('/Sessions/Capabilities/Full');
    final body = jsonEncode({
      'PlayableMediaTypes': ['Audio'],
      'SupportedCommands': [
        'PlayState',
        'Play',
        'Seek',
        'NextTrack',
        'PreviousTrack',
        'SetVolume',
        'Mute',
        'Unmute',
        'ToggleMute',
      ],
      'SupportsMediaControl': true,
      'SupportsPersistentIdentifier': true,
    });

    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: body,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to report capabilities: ${response.statusCode}',
      );
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
