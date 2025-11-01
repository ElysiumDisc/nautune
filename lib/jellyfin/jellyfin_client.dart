import 'dart:convert';

import 'package:http/http.dart' as http;

import 'jellyfin_credentials.dart';
import 'jellyfin_exceptions.dart';
import 'jellyfin_album.dart';
import 'jellyfin_library.dart';
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
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items', {
      'ParentId': libraryId,
      'IncludeItemTypes': 'MusicAlbum',
      'Recursive': 'true',
      'SortBy': 'SortName',
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,Artists,AlbumArtists,ImageTags',
    });

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
}
