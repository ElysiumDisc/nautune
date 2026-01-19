import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/syncplay_models.dart';
import 'jellyfin_credentials.dart';
import 'jellyfin_exceptions.dart';
import 'jellyfin_track.dart';
import 'robust_http_client.dart';

/// Jellyfin SyncPlay API client
///
/// Handles all REST API calls for SyncPlay functionality.
/// WebSocket communication is handled separately by SyncPlayWebSocket.
class SyncPlayClient {
  SyncPlayClient({
    required this.serverUrl,
    required this.deviceId,
    http.Client? httpClient,
  }) : _robustClient = RobustHttpClient(
          client: httpClient,
          maxRetries: 3,
          baseTimeout: const Duration(seconds: 15),
          enableEtagCache: false, // SyncPlay needs fresh data
        );

  final String serverUrl;
  final String deviceId;
  final RobustHttpClient _robustClient;

  Uri _buildUri(String path, [Map<String, dynamic>? query]) {
    return Uri.parse(serverUrl).resolve(path).replace(
      queryParameters: query?.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  Map<String, String> _defaultHeaders([JellyfinCredentials? credentials]) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'X-Emby-Authorization':
          'MediaBrowser Client="Nautune", Device="${defaultTargetPlatform.name}", '
          'DeviceId="$deviceId", Version="5.0.0"',
    };

    if (credentials != null) {
      headers['X-MediaBrowser-Token'] = credentials.accessToken;
    }

    return headers;
  }

  // ============ Group Management ============

  /// Create a new SyncPlay group
  /// POST /SyncPlay/New
  Future<void> createGroup({
    required JellyfinCredentials credentials,
    required String groupName,
  }) async {
    final uri = _buildUri('/SyncPlay/New');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'GroupName': groupName,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to create SyncPlay group: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay group created: $groupName');
  }

  /// Get list of available SyncPlay groups
  /// GET /SyncPlay/List
  Future<List<SyncPlayGroup>> getGroups({
    required JellyfinCredentials credentials,
  }) async {
    final uri = _buildUri('/SyncPlay/List');
    final response = await _robustClient.get(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200) {
      throw JellyfinRequestException(
        'Failed to get SyncPlay groups: ${response.statusCode}',
      );
    }

    final data = jsonDecode(response.body) as List<dynamic>? ?? [];
    return data
        .whereType<Map<String, dynamic>>()
        .map(SyncPlayGroup.fromJson)
        .toList();
  }

  /// Join an existing SyncPlay group
  /// POST /SyncPlay/Join
  Future<void> joinGroup({
    required JellyfinCredentials credentials,
    required String groupId,
  }) async {
    final uri = _buildUri('/SyncPlay/Join');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'GroupId': groupId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to join SyncPlay group: ${response.statusCode}',
      );
    }

    debugPrint('✅ Joined SyncPlay group: $groupId');
  }

  /// Leave the current SyncPlay group
  /// POST /SyncPlay/Leave
  Future<void> leaveGroup({
    required JellyfinCredentials credentials,
  }) async {
    final uri = _buildUri('/SyncPlay/Leave');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to leave SyncPlay group: ${response.statusCode}',
      );
    }

    debugPrint('✅ Left SyncPlay group');
  }

  // ============ Queue Management ============

  /// Add items to the SyncPlay queue
  /// POST /SyncPlay/Queue
  Future<void> queue({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
    SyncPlayQueueMode mode = SyncPlayQueueMode.queue,
  }) async {
    final uri = _buildUri('/SyncPlay/Queue');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'ItemIds': itemIds,
        'Mode': _queueModeToString(mode),
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to add items to SyncPlay queue: ${response.statusCode}',
      );
    }

    debugPrint('✅ Added ${itemIds.length} items to SyncPlay queue');
  }

  /// Remove items from the SyncPlay queue
  /// POST /SyncPlay/RemoveFromPlaylist
  Future<void> removeFromPlaylist({
    required JellyfinCredentials credentials,
    required List<String> playlistItemIds,
    bool clearPlayingItem = false,
    bool clearPlaylist = false,
  }) async {
    final uri = _buildUri('/SyncPlay/RemoveFromPlaylist');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'PlaylistItemIds': playlistItemIds,
        'ClearPlayingItem': clearPlayingItem,
        'ClearPlaylist': clearPlaylist,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to remove items from SyncPlay queue: ${response.statusCode}',
      );
    }

    debugPrint('✅ Removed ${playlistItemIds.length} items from SyncPlay queue');
  }

  /// Move a playlist item to a new position
  /// POST /SyncPlay/MovePlaylistItem
  Future<void> movePlaylistItem({
    required JellyfinCredentials credentials,
    required String playlistItemId,
    required int newIndex,
  }) async {
    final uri = _buildUri('/SyncPlay/MovePlaylistItem');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'PlaylistItemId': playlistItemId,
        'NewIndex': newIndex,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to move SyncPlay queue item: ${response.statusCode}',
      );
    }

    debugPrint('✅ Moved SyncPlay queue item to index $newIndex');
  }

  /// Set a completely new queue
  /// POST /SyncPlay/SetNewQueue
  Future<void> setNewQueue({
    required JellyfinCredentials credentials,
    required List<String> itemIds,
    int startIndex = 0,
    int startPositionTicks = 0,
  }) async {
    final uri = _buildUri('/SyncPlay/SetNewQueue');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'PlayingQueue': itemIds,
        'PlayingItemPosition': startIndex,
        'StartPositionTicks': startPositionTicks,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set new SyncPlay queue: ${response.statusCode}',
      );
    }

    debugPrint('✅ Set new SyncPlay queue with ${itemIds.length} items');
  }

  /// Set the current playing item index
  /// POST /SyncPlay/SetPlaylistItem
  Future<void> setPlaylistItem({
    required JellyfinCredentials credentials,
    required String playlistItemId,
  }) async {
    final uri = _buildUri('/SyncPlay/SetPlaylistItem');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'PlaylistItemId': playlistItemId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set SyncPlay playlist item: ${response.statusCode}',
      );
    }

    debugPrint('✅ Set SyncPlay playlist item: $playlistItemId');
  }

  // ============ Playback Control ============

  /// Pause playback
  /// POST /SyncPlay/Pause
  Future<void> pause({
    required JellyfinCredentials credentials,
  }) async {
    final uri = _buildUri('/SyncPlay/Pause');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to pause SyncPlay: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay paused');
  }

  /// Resume/unpause playback
  /// POST /SyncPlay/Unpause
  Future<void> unpause({
    required JellyfinCredentials credentials,
  }) async {
    final uri = _buildUri('/SyncPlay/Unpause');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to unpause SyncPlay: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay unpaused');
  }

  /// Stop playback
  /// POST /SyncPlay/Stop
  Future<void> stop({
    required JellyfinCredentials credentials,
  }) async {
    final uri = _buildUri('/SyncPlay/Stop');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to stop SyncPlay: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay stopped');
  }

  /// Seek to a specific position
  /// POST /SyncPlay/Seek
  Future<void> seek({
    required JellyfinCredentials credentials,
    required int positionTicks,
  }) async {
    final uri = _buildUri('/SyncPlay/Seek');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'PositionTicks': positionTicks,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to seek SyncPlay: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay seek to $positionTicks ticks');
  }

  /// Go to next item
  /// POST /SyncPlay/NextItem
  Future<void> nextItem({
    required JellyfinCredentials credentials,
    String? playlistItemId,
  }) async {
    final uri = _buildUri('/SyncPlay/NextItem');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        if (playlistItemId != null) 'PlaylistItemId': playlistItemId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to skip to next SyncPlay item: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay skipped to next item');
  }

  /// Go to previous item
  /// POST /SyncPlay/PreviousItem
  Future<void> previousItem({
    required JellyfinCredentials credentials,
    String? playlistItemId,
  }) async {
    final uri = _buildUri('/SyncPlay/PreviousItem');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        if (playlistItemId != null) 'PlaylistItemId': playlistItemId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to skip to previous SyncPlay item: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay skipped to previous item');
  }

  // ============ Sync State ============

  /// Signal ready state
  /// POST /SyncPlay/Ready
  Future<void> setReady({
    required JellyfinCredentials credentials,
    required bool isReady,
    int positionTicks = 0,
    String? playlistItemId,
    bool isPlaying = false,
  }) async {
    final uri = _buildUri('/SyncPlay/Ready');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'IsPlaying': isPlaying,
        'PositionTicks': positionTicks,
        'When': DateTime.now().toUtc().toIso8601String(),
        if (playlistItemId != null) 'PlaylistItemId': playlistItemId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set SyncPlay ready state: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay ready state: $isReady');
  }

  /// Report buffering state
  /// POST /SyncPlay/Buffering
  Future<void> setBuffering({
    required JellyfinCredentials credentials,
    required bool isBuffering,
    int positionTicks = 0,
    String? playlistItemId,
    bool isPlaying = false,
  }) async {
    final uri = _buildUri('/SyncPlay/Buffering');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'IsPlaying': isPlaying,
        'PositionTicks': positionTicks,
        'When': DateTime.now().toUtc().toIso8601String(),
        if (playlistItemId != null) 'PlaylistItemId': playlistItemId,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set SyncPlay buffering state: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay buffering state: $isBuffering');
  }

  /// Ping to keep connection alive and sync time
  /// POST /SyncPlay/Ping
  Future<void> ping({
    required JellyfinCredentials credentials,
    required int ping,
  }) async {
    final uri = _buildUri('/SyncPlay/Ping');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'Ping': ping,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to ping SyncPlay: ${response.statusCode}',
      );
    }
  }

  // ============ Shuffle & Repeat ============

  /// Set shuffle mode
  /// POST /SyncPlay/SetShuffleMode
  Future<void> setShuffleMode({
    required JellyfinCredentials credentials,
    required bool shuffle,
  }) async {
    final uri = _buildUri('/SyncPlay/SetShuffleMode');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'Mode': shuffle ? 'Shuffle' : 'Sorted',
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set SyncPlay shuffle mode: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay shuffle mode: $shuffle');
  }

  /// Set repeat mode
  /// POST /SyncPlay/SetRepeatMode
  Future<void> setRepeatMode({
    required JellyfinCredentials credentials,
    required String mode, // RepeatNone, RepeatAll, RepeatOne
  }) async {
    final uri = _buildUri('/SyncPlay/SetRepeatMode');
    final response = await _robustClient.post(
      uri,
      headers: _defaultHeaders(credentials),
      body: jsonEncode({
        'Mode': mode,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw JellyfinRequestException(
        'Failed to set SyncPlay repeat mode: ${response.statusCode}',
      );
    }

    debugPrint('✅ SyncPlay repeat mode: $mode');
  }

  // ============ Item Fetching ============

  /// Get a single item by ID
  /// GET /Users/{userId}/Items/{itemId}
  Future<JellyfinTrack?> getItem({
    required JellyfinCredentials credentials,
    required String itemId,
  }) async {
    final uri = _buildUri('/Users/${credentials.userId}/Items/$itemId');
    try {
      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return JellyfinTrack.fromJson(
          json,
          serverUrl: serverUrl,
          token: credentials.accessToken,
          userId: credentials.userId,
        );
      }
    } catch (e) {
      debugPrint('Failed to fetch item $itemId: $e');
    }
    return null;
  }

  /// Get public user info by user ID
  /// GET /Users/{userId}
  Future<Map<String, dynamic>?> getUserInfo({
    required JellyfinCredentials credentials,
    required String userId,
  }) async {
    final uri = _buildUri('/Users/$userId');
    try {
      final response = await _robustClient.get(
        uri,
        headers: _defaultHeaders(credentials),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('Failed to fetch user info for $userId: $e');
    }
    return null;
  }

  // ============ Helpers ============

  String _queueModeToString(SyncPlayQueueMode mode) {
    switch (mode) {
      case SyncPlayQueueMode.queue:
        return 'Queue';
      case SyncPlayQueueMode.queueNext:
        return 'QueueNext';
      case SyncPlayQueueMode.setCurrentItem:
        return 'SetCurrentItem';
    }
  }

  /// Close the HTTP client
  void close() {
    _robustClient.close();
  }
}
