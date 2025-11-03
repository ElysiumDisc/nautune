import 'dart:convert';

import 'package:http/http.dart' as http;

import 'jellyfin_credentials.dart';
import 'jellyfin_exceptions.dart';
import 'jellyfin_album.dart';
import 'jellyfin_artist.dart';
import 'jellyfin_library.dart';
import 'jellyfin_playlist.dart';
import 'jellyfin_track.dart';
import 'jellyfin_user.dart';

/// Lightweight Jellyfin REST client to be expanded as features land.
class JellyfinClient {
  JellyfinClient({
    required this.serverUrl,
    http.Client? httpClient,
  })  : httpClient = httpClient ?? http.Client();

  final String serverUrl;
  final http.Client httpClient;

  Uri _buildUri(String path, [Map<String, dynamic>? query]) {
    return Uri.parse(serverUrl).resolve(path).replace(queryParameters: query);
  }

  Future<JellyfinCredentials> authenticate({
    required String username,
    required String password,
  }) async {
    final uri = _buildUri('/Users/AuthenticateByName');
    final response = await httpClient.post(
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
    final response = await httpClient.get(
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
    final response = await httpClient.get(
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
  }) async {
    final queryParams = {
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags,Genres,GenreItems',
    };
    
    if (genreIds != null) {
      queryParams['GenreIds'] = genreIds;
    }
    
    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);

    final response = await httpClient.get(
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
  }) async {
    final uri = _buildUri('/Artists', {
      'ParentId': libraryId,
      'Recursive': 'true',
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Fields': 'PrimaryImageAspectRatio,ImageTags',
    });

    final response = await httpClient.get(
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

  Future<List<JellyfinPlaylist>> fetchPlaylists({
    required JellyfinCredentials credentials,
    required String libraryId,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'Playlist',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'Fields': 'ChildCount,ImageTags',
    });

    final response = await httpClient.get(
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
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber',
      'EnableImageTypes': 'Primary,Thumb',
    });

    final response = await httpClient.get(
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
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber',
      'EnableImageTypes': 'Primary,Thumb',
    });

    final response = await httpClient.get(
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

    final response = await httpClient.get(
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
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber',
      'EnableImageTypes': 'Primary,Thumb',
    });

    final response = await httpClient.get(
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
          'Album,AlbumId,AlbumPrimaryImageTag,ParentThumbImageTag,Artists,RunTimeTicks,ImageTags,IndexNumber,ParentIndexNumber',
      'EnableImageTypes': 'Primary,Thumb',
    });

    final response = await httpClient.get(
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

    final response = await httpClient.get(
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
      'Fields': 'ImageTags',
    });

    final response = await httpClient.get(
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
        response = await httpClient.get(uri, headers: headers);
        break;
      case 'POST':
        response = await httpClient.post(
          uri,
          headers: headers,
          body: body != null ? jsonEncode(body) : null,
        );
        break;
      case 'DELETE':
        response = await httpClient.delete(uri, headers: headers);
        break;
      default:
        throw ArgumentError('Unsupported HTTP method: $method');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw JellyfinRequestException(
        'Request failed: ${response.statusCode} ${response.body}',
      );
    }

    if (response.body.isEmpty) {
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
    final response = await httpClient.get(
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
      'Fields': 'AudioInfo,ParentId',
    };

    final uri = _buildUri('/Items/$itemId/InstantMix', queryParams);
    final response = await httpClient.get(
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
    final response = await httpClient.post(
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
      'Fields': 'AudioInfo,ParentId',
    };

    final uri = _buildUri('/Users/${credentials.userId}/Items', queryParams);
    final response = await httpClient.get(
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
}
