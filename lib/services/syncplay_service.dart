import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/syncplay_client.dart';
import '../models/syncplay_models.dart';
import 'syncplay_websocket.dart';

/// Playback command from server to sync playback across devices
class SyncPlayCommand {
  const SyncPlayCommand({
    required this.type,
    this.positionTicks,
    this.trackIndex,
    this.playlistItemId,
  });

  final SyncPlayCommandType type;
  final int? positionTicks;
  final int? trackIndex;
  final String? playlistItemId; // Which specific track to play

  Duration? get position => positionTicks != null
      ? Duration(microseconds: positionTicks! ~/ 10)
      : null;
}

enum SyncPlayCommandType {
  play,    // Unpause - start/resume playback
  pause,   // Pause playback
  stop,    // Stop playback
  seek,    // Seek to position
}

/// Core SyncPlay service that manages collaborative playlist functionality.
///
/// Responsibilities:
/// - Group creation, joining, and leaving
/// - Queue management (add, remove, reorder tracks)
/// - Playback control (play, pause, seek, skip)
/// - Real-time synchronization via WebSocket
/// - State management for the current session
class SyncPlayService extends ChangeNotifier {
  SyncPlayService({
    required String serverUrl,
    required String deviceId,
    required JellyfinCredentials credentials,
    required String userId,
    required String username,
    String? userImageTag,
  })  : _serverUrl = serverUrl,
        _deviceId = deviceId,
        _credentials = credentials,
        _userId = userId,
        _username = username,
        _userImageTag = userImageTag,
        _client = SyncPlayClient(
          serverUrl: serverUrl,
          deviceId: deviceId,
        );

  final String _serverUrl;
  final String _deviceId;
  final JellyfinCredentials _credentials;
  final String _userId;
  final String _username;
  final String? _userImageTag;
  final SyncPlayClient _client;

  SyncPlayWebSocket? _webSocket;
  StreamSubscription<SyncPlayMessage>? _messageSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _pingTimer;

  // State
  SyncPlaySession? _currentSession;
  List<SyncPlayGroup> _availableGroups = [];
  bool _isLoading = false;
  Object? _error;

  // For auto-rejoin on reconnect
  String? _lastGroupId;
  bool _wasCaption = false;
  bool _isRejoining = false;

  // Track attribution map (playlistItemId -> user info)
  final Map<String, _UserAttribution> _trackAttributions = {};

  // Getters
  SyncPlaySession? get currentSession => _currentSession;
  List<SyncPlayGroup> get availableGroups => _availableGroups;
  bool get isLoading => _isLoading;
  Object? get error => _error;
  bool get isInSession => _currentSession != null;
  bool get isCaptain => _currentSession?.isCaptain ?? false;
  SyncPlayRole get role => _currentSession?.role ?? SyncPlayRole.sailor;

  // Streams for reactive UI
  final _sessionController = StreamController<SyncPlaySession?>.broadcast();
  Stream<SyncPlaySession?> get sessionStream => _sessionController.stream;

  final _groupsController = StreamController<List<SyncPlayGroup>>.broadcast();
  Stream<List<SyncPlayGroup>> get groupsStream => _groupsController.stream;

  final _participantsController = StreamController<List<SyncPlayParticipant>>.broadcast();

  // Stream for playback commands (unpause, pause, seek, stop) from server
  final _playbackCommandController = StreamController<SyncPlayCommand>.broadcast();
  Stream<SyncPlayCommand> get playbackCommandStream => _playbackCommandController.stream;
  Stream<List<SyncPlayParticipant>> get participantsStream => _participantsController.stream;

  // ============ Group Management ============

  /// Create a new SyncPlay group (becomes Captain)
  Future<void> createGroup(String name) async {
    _setLoading(true);
    _clearError();

    try {
      await _client.createGroup(
        credentials: _credentials,
        groupName: name,
      );

      // Fetch groups to find our new group (REST call, no WebSocket needed yet)
      await refreshGroups();

      // Find the group we just created and join it
      final group = _availableGroups.firstWhere(
        (g) => g.groupName == name,
        orElse: () => throw Exception('Failed to find created group'),
      );

      await _joinGroupInternal(group.groupId, isCaptain: true);

      debugPrint('✅ Created and joined SyncPlay group: $name');
    } catch (e) {
      _setError(e);
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  /// Join an existing SyncPlay group (becomes Sailor)
  Future<void> joinGroup(String groupId) async {
    _setLoading(true);
    _clearError();

    try {
      await _joinGroupInternal(groupId, isCaptain: false);
      debugPrint('✅ Joined SyncPlay group: $groupId');
    } catch (e) {
      _setError(e);
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _joinGroupInternal(String groupId, {required bool isCaptain}) async {
    // Store for auto-rejoin on reconnect
    _lastGroupId = groupId;
    _wasCaption = isCaptain;

    // Connect WebSocket FIRST to receive join broadcasts
    await _connectWebSocket();

    // Initialize session early so handlers work
    _currentSession = SyncPlaySession(
      group: SyncPlayGroup(
        groupId: groupId,
        groupName: 'Collaborative Playlist',
        participants: [],
        state: SyncPlayState.idle,
      ),
      queue: [],
      currentTrackIndex: -1,
      positionTicks: 0,
      role: isCaptain ? SyncPlayRole.captain : SyncPlayRole.sailor,
    );
    _notifySessionChanged();

    // NOW join the group (WebSocket already listening)
    await _client.joinGroup(
      credentials: _credentials,
      groupId: groupId,
    );

    // Fetch full group state after join
    await refreshGroups();

    // Update session with fetched group info
    final group = _availableGroups.firstWhere(
      (g) => g.groupId == groupId,
      orElse: () => _currentSession!.group,
    );

    _currentSession = _currentSession!.copyWith(
      group: group.copyWith(
        participants: [
          ...group.participants,
          // Check both userId and deviceId for multi-device support
          if (!group.participants.any((p) => p.userId == _userId && p.oderId == _deviceId))
            SyncPlayParticipant(
              oderId: _deviceId,
              userId: _userId,
              username: _username,
              userImageTag: _userImageTag,
              isGroupLeader: isCaptain,
            ),
        ],
      ),
    );
    _notifySessionChanged();
    _startPingTimer();
  }

  /// Leave the current SyncPlay group
  Future<void> leaveGroup() async {
    if (_currentSession == null) return;

    _setLoading(true);
    _clearError();

    try {
      await _client.leaveGroup(credentials: _credentials);
      await _disconnectWebSocket();

      // Clear auto-rejoin info - user explicitly left
      _lastGroupId = null;
      _wasCaption = false;

      _currentSession = null;
      _trackAttributions.clear();
      _notifySessionChanged();

      debugPrint('✅ Left SyncPlay group');
    } catch (e) {
      _setError(e);
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  /// Refresh available groups
  Future<void> refreshGroups() async {
    try {
      debugPrint('SyncPlayService: Fetching groups from client...');
      _availableGroups = await _client.getGroups(credentials: _credentials);
      debugPrint('SyncPlayService: Client returned ${_availableGroups.length} groups');

      // Enrich participant data with user details
      for (int i = 0; i < _availableGroups.length; i++) {
        final group = _availableGroups[i];
        final enrichedParticipants = await _enrichParticipants(group.participants);
        _availableGroups[i] = group.copyWith(participants: enrichedParticipants);
      }

      // Debug: log participant details
      for (final group in _availableGroups) {
        debugPrint('SyncPlay Group ${group.groupName}: ${group.participants.length} participants');
        for (final p in group.participants) {
          debugPrint('  - ${p.username} (${p.userId}) imageTag: ${p.userImageTag}, device: ${p.oderId}');
        }
      }

      _groupsController.add(_availableGroups);
    } catch (e) {
      debugPrint('Failed to refresh SyncPlay groups: $e');
    }
  }

  /// Enrich participants with full user details (username, imageTag)
  ///
  /// Note: Jellyfin's /SyncPlay/List returns participant usernames (not UUIDs),
  /// so we can't directly fetch user info. We handle this by:
  /// 1. For current user: use our known _userId and _userImageTag
  /// 2. For other users: the username is already correct, imageTag may be unavailable
  Future<List<SyncPlayParticipant>> _enrichParticipants(List<SyncPlayParticipant> participants) async {
    final enriched = <SyncPlayParticipant>[];

    debugPrint('SyncPlay: Enriching ${participants.length} participants');
    debugPrint('SyncPlay: Current user - username: $_username, userId: $_userId, imageTag: $_userImageTag');

    for (final p in participants) {
      debugPrint('SyncPlay: Checking participant - username: ${p.username}, userId: ${p.userId}');

      // Check if this is the current user (by matching username)
      // Jellyfin returns usernames, not user IDs, in the participants list
      final isCurrentUser = p.username == _username ||
                            p.userId == _username ||
                            p.userId == _userId;

      debugPrint('SyncPlay: Is current user? $isCurrentUser (p.username=${p.username} == _username=$_username ? ${p.username == _username})');

      if (isCurrentUser) {
        enriched.add(SyncPlayParticipant(
          oderId: _deviceId,
          userId: _userId,
          username: _username,
          userImageTag: _userImageTag,
          isGroupLeader: p.isGroupLeader,
        ));
        continue;
      }

      // For other users, keep as-is (username is correct from API, imageTag unavailable)
      enriched.add(p);
    }

    return enriched;
  }

  // ============ Queue Management ============

  /// Add tracks to the queue
  Future<void> addToQueue(List<JellyfinTrack> tracks, {SyncPlayQueueMode mode = SyncPlayQueueMode.queue}) async {
    if (_currentSession == null) return;

    try {
      final itemIds = tracks.map((t) => t.id).toList();

      // Store attribution for these tracks
      for (final track in tracks) {
        _trackAttributions[track.id] = _UserAttribution(
          userId: _userId,
          username: _username,
          imageTag: _userImageTag,
        );
      }

      await _client.queue(
        credentials: _credentials,
        itemIds: itemIds,
        mode: mode,
      );

      // Optimistically update local queue
      final wasEmpty = _currentSession!.queue.isEmpty;
      final newTracks = tracks.map((track) => SyncPlayTrack(
        track: track,
        addedByUserId: _userId,
        addedByUsername: _username,
        addedByImageTag: _userImageTag,
        playlistItemId: track.id, // Will be updated by server
      )).toList();

      _currentSession = _currentSession!.copyWith(
        queue: [..._currentSession!.queue, ...newTracks],
        // Set first track as current if queue was empty
        currentTrackIndex: wasEmpty ? 0 : _currentSession!.currentTrackIndex,
      );
      _notifySessionChanged();

      debugPrint('✅ Added ${tracks.length} tracks to SyncPlay queue');
    } catch (e) {
      debugPrint('Failed to add tracks to queue: $e');
      rethrow;
    }
  }

  /// Remove a track from the queue
  Future<void> removeFromQueue(String playlistItemId) async {
    if (_currentSession == null) return;

    try {
      await _client.removeFromPlaylist(
        credentials: _credentials,
        playlistItemIds: [playlistItemId],
      );

      // Optimistically update local queue
      _currentSession = _currentSession!.copyWith(
        queue: _currentSession!.queue
            .where((t) => t.playlistItemId != playlistItemId)
            .toList(),
      );
      _notifySessionChanged();

      debugPrint('✅ Removed track from SyncPlay queue');
    } catch (e) {
      debugPrint('Failed to remove track from queue: $e');
      rethrow;
    }
  }

  /// Reorder a track in the queue
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (_currentSession == null) return;

    final queue = _currentSession!.queue;
    if (oldIndex < 0 || oldIndex >= queue.length) return;
    if (newIndex < 0 || newIndex >= queue.length) return;

    try {
      final item = queue[oldIndex];

      await _client.movePlaylistItem(
        credentials: _credentials,
        playlistItemId: item.playlistItemId,
        newIndex: newIndex,
      );

      // Optimistically update local queue
      final newQueue = List<SyncPlayTrack>.from(queue);
      newQueue.removeAt(oldIndex);
      newQueue.insert(newIndex, item);

      _currentSession = _currentSession!.copyWith(queue: newQueue);
      _notifySessionChanged();

      debugPrint('✅ Reordered SyncPlay queue: $oldIndex -> $newIndex');
    } catch (e) {
      debugPrint('Failed to reorder queue: $e');
      rethrow;
    }
  }

  /// Set a completely new queue
  Future<void> setQueue(List<JellyfinTrack> tracks, {int startIndex = 0}) async {
    if (_currentSession == null) return;

    try {
      final itemIds = tracks.map((t) => t.id).toList();

      // Store attributions
      for (final track in tracks) {
        _trackAttributions[track.id] = _UserAttribution(
          userId: _userId,
          username: _username,
          imageTag: _userImageTag,
        );
      }

      await _client.setNewQueue(
        credentials: _credentials,
        itemIds: itemIds,
        startIndex: startIndex,
      );

      // Optimistically update local queue
      final newTracks = tracks.map((track) => SyncPlayTrack(
        track: track,
        addedByUserId: _userId,
        addedByUsername: _username,
        addedByImageTag: _userImageTag,
        playlistItemId: track.id,
      )).toList();

      _currentSession = _currentSession!.copyWith(
        queue: newTracks,
        currentTrackIndex: startIndex,
      );
      _notifySessionChanged();

      debugPrint('✅ Set new SyncPlay queue with ${tracks.length} tracks');
    } catch (e) {
      debugPrint('Failed to set queue: $e');
      rethrow;
    }
  }

  // ============ Playback Control ============

  /// Play / Unpause
  Future<void> play() async {
    if (_currentSession == null) return;

    try {
      await _client.unpause(credentials: _credentials);
      _currentSession = _currentSession!.copyWith(isPaused: false);
      _notifySessionChanged();
    } catch (e) {
      debugPrint('Failed to play: $e');
      rethrow;
    }
  }

  /// Pause
  Future<void> pause() async {
    if (_currentSession == null) return;

    try {
      await _client.pause(credentials: _credentials);
      _currentSession = _currentSession!.copyWith(isPaused: true);
      _notifySessionChanged();
    } catch (e) {
      debugPrint('Failed to pause: $e');
      rethrow;
    }
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    if (_currentSession == null) return;

    try {
      final positionTicks = position.inMicroseconds * 10;
      await _client.seek(
        credentials: _credentials,
        positionTicks: positionTicks,
      );
      _currentSession = _currentSession!.copyWith(positionTicks: positionTicks);
      _notifySessionChanged();
    } catch (e) {
      debugPrint('Failed to seek: $e');
      rethrow;
    }
  }

  /// Skip to next track
  Future<void> nextTrack() async {
    if (_currentSession == null) return;

    try {
      // Optimistically update local state
      final currentIndex = _currentSession!.currentTrackIndex;
      final nextIndex = currentIndex + 1;
      if (nextIndex < _currentSession!.queue.length) {
        _currentSession = _currentSession!.copyWith(
          currentTrackIndex: nextIndex,
          positionTicks: 0,
          lastSyncTime: DateTime.now(),
        );
        _notifySessionChanged();
      }

      await _client.nextItem(credentials: _credentials);
    } catch (e) {
      debugPrint('Failed to skip to next: $e');
      rethrow;
    }
  }

  /// Skip to previous track
  Future<void> previousTrack() async {
    if (_currentSession == null) return;

    try {
      // Optimistically update local state
      final currentIndex = _currentSession!.currentTrackIndex;
      final prevIndex = currentIndex - 1;
      if (prevIndex >= 0) {
        _currentSession = _currentSession!.copyWith(
          currentTrackIndex: prevIndex,
          positionTicks: 0,
          lastSyncTime: DateTime.now(),
        );
        _notifySessionChanged();
      }

      await _client.previousItem(credentials: _credentials);
    } catch (e) {
      debugPrint('Failed to skip to previous: $e');
      rethrow;
    }
  }

  /// Set specific track as current
  Future<void> setCurrentTrack(String playlistItemId) async {
    if (_currentSession == null) return;

    try {
      // Optimistically update local state immediately for responsive UI
      final index = _currentSession!.queue.indexWhere(
        (t) => t.playlistItemId == playlistItemId,
      );
      if (index >= 0) {
        _currentSession = _currentSession!.copyWith(
          currentTrackIndex: index,
          positionTicks: 0,
          lastSyncTime: DateTime.now(),
        );
        _notifySessionChanged();
      }

      await _client.setPlaylistItem(
        credentials: _credentials,
        playlistItemId: playlistItemId,
      );
    } catch (e) {
      debugPrint('Failed to set current track: $e');
      rethrow;
    }
  }

  // ============ Sync State ============

  /// Signal ready state
  Future<void> signalReady(bool isReady) async {
    if (_currentSession == null) return;

    try {
      final current = _currentSession!.currentTrack;
      await _client.setReady(
        credentials: _credentials,
        isReady: isReady,
        positionTicks: _currentSession!.positionTicks,
        playlistItemId: current?.playlistItemId,
        isPlaying: !_currentSession!.isPaused,
      );
    } catch (e) {
      debugPrint('Failed to signal ready: $e');
    }
  }

  /// Report buffering state
  Future<void> reportBuffering(bool isBuffering) async {
    if (_currentSession == null) return;

    try {
      final current = _currentSession!.currentTrack;
      await _client.setBuffering(
        credentials: _credentials,
        isBuffering: isBuffering,
        positionTicks: _currentSession!.positionTicks,
        playlistItemId: current?.playlistItemId,
        isPlaying: !_currentSession!.isPaused,
      );
    } catch (e) {
      debugPrint('Failed to report buffering: $e');
    }
  }

  // ============ WebSocket Management ============

  bool _wasConnected = false;

  Future<void> _connectWebSocket() async {
    await _disconnectWebSocket();

    _webSocket = SyncPlayWebSocket(
      serverUrl: _serverUrl,
      credentials: _credentials,
      deviceId: _deviceId,
    );

    _messageSubscription = _webSocket!.messageStream.listen(_handleWebSocketMessage);
    _connectionSubscription = _webSocket!.connectionStateStream.listen((connected) {
      if (!connected && _currentSession != null) {
        debugPrint('SyncPlay WebSocket disconnected, will retry...');
        _wasConnected = false;
      } else if (connected && !_wasConnected && _lastGroupId != null) {
        // WebSocket reconnected and we have a group to rejoin
        debugPrint('SyncPlay WebSocket reconnected, attempting auto-rejoin...');
        _wasConnected = true;
        _attemptAutoRejoin();
      } else if (connected) {
        _wasConnected = true;
      }
    });

    await _webSocket!.connect();
    _wasConnected = true;
  }

  int _rejoinAttempts = 0;
  static const int _maxRejoinAttempts = 5;

  /// Attempt to rejoin the last group after WebSocket reconnection
  Future<void> _attemptAutoRejoin() async {
    final groupIdToRejoin = _lastGroupId;
    final wasCaptain = _wasCaption;

    if (_isRejoining || groupIdToRejoin == null) return;

    _isRejoining = true;
    try {
      debugPrint('Auto-rejoining group: $groupIdToRejoin (captain: $wasCaptain) attempt ${_rejoinAttempts + 1}');

      // Try to rejoin the group
      await _client.joinGroup(
        credentials: _credentials,
        groupId: groupIdToRejoin,
      );

      // Check if we were cancelled during the await
      if (_lastGroupId == null) {
        debugPrint('Auto-rejoin cancelled - lastGroupId cleared');
        return;
      }

      // Restore session state with stored captain status
      if (_currentSession == null) {
        _currentSession = SyncPlaySession(
          group: SyncPlayGroup(
            groupId: groupIdToRejoin,
            groupName: 'Collaborative Playlist',
            participants: [
              SyncPlayParticipant(
                oderId: _deviceId,
                userId: _userId,
                username: _username,
                userImageTag: _userImageTag,
                isGroupLeader: wasCaptain,
              ),
            ],
            state: SyncPlayState.idle,
          ),
          queue: [],
          currentTrackIndex: -1,
          positionTicks: 0,
          role: wasCaptain ? SyncPlayRole.captain : SyncPlayRole.sailor,
        );
        _notifySessionChanged();
      }

      _rejoinAttempts = 0; // Reset on success
      debugPrint('✅ Auto-rejoined SyncPlay group successfully');
    } catch (e) {
      debugPrint('Failed to auto-rejoin SyncPlay group: $e');
      _rejoinAttempts++;

      if (_rejoinAttempts < _maxRejoinAttempts && _lastGroupId != null) {
        // Retry with exponential backoff
        final delay = Duration(seconds: 1 << _rejoinAttempts);
        debugPrint('Will retry rejoin in ${delay.inSeconds}s (attempt ${_rejoinAttempts + 1}/$_maxRejoinAttempts)');
        _isRejoining = false;
        Future.delayed(delay, () {
          if (_lastGroupId != null && !_isRejoining) {
            _attemptAutoRejoin();
          }
        });
        return;
      } else {
        // Max attempts reached or group cleared - group likely no longer exists
        debugPrint('Max rejoin attempts reached or group cleared, giving up');
        _lastGroupId = null;
        _wasCaption = false;
        _rejoinAttempts = 0;
        _currentSession = null;
        _trackAttributions.clear();
        _notifySessionChanged();
      }
    } finally {
      if (_rejoinAttempts == 0 || _rejoinAttempts >= _maxRejoinAttempts) {
        _isRejoining = false;
      }
    }
  }

  Future<void> _disconnectWebSocket() async {
    _stopPingTimer();
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _webSocket?.dispose();
    _webSocket = null;
  }

  void _handleWebSocketMessage(SyncPlayMessage message) {
    debugPrint('SyncPlay message: ${message.type} (groupId: ${message.groupId})');

    switch (message.type) {
      // Group update types
      case SyncPlayMessageType.groupStateUpdate:
        _handleGroupStateUpdate(message);
        break;

      case SyncPlayMessageType.userJoined:
        _handleUserJoined(message);
        break;

      case SyncPlayMessageType.userLeft:
        _handleUserLeft(message);
        break;

      case SyncPlayMessageType.groupJoined:
        _handleGroupJoined(message);
        break;

      case SyncPlayMessageType.groupLeft:
        _handleGroupLeft(message);
        break;

      case SyncPlayMessageType.playQueueUpdate:
        _handleQueueUpdate(message);
        break;

      case SyncPlayMessageType.notInGroup:
        debugPrint('SyncPlay: Not in group error');
        break;

      case SyncPlayMessageType.groupDoesNotExist:
        debugPrint('SyncPlay: Group does not exist');
        _handleGroupLeft(message); // Treat as leaving
        break;

      case SyncPlayMessageType.libraryAccessDenied:
        debugPrint('SyncPlay: Library access denied');
        _handleGroupLeft(message); // Treat as leaving
        break;

      // Playback commands
      case SyncPlayMessageType.unpause:
        _handleUnpause(message);
        break;

      case SyncPlayMessageType.pause:
        _handlePause(message);
        break;

      case SyncPlayMessageType.stop:
        _handleStop(message);
        break;

      case SyncPlayMessageType.seek:
        _handleSeek(message);
        break;

      default:
        debugPrint('SyncPlay: Unhandled message type: ${message.type}');
        break;
    }
  }

  void _handleGroupStateUpdate(SyncPlayMessage message) {
    final group = message.groupState;
    if (group == null) return;

    // Store previous pause state BEFORE updating (for detecting state changes)
    final wasPaused = _currentSession?.isPaused ?? true;

    // If session not initialized yet, initialize it from this message
    if (_currentSession == null) {
      debugPrint('SyncPlay: Initializing session from group state update');
      _currentSession = SyncPlaySession(
        group: group,
        queue: [],
        currentTrackIndex: -1,
        positionTicks: message.positionTicks ?? 0,
        role: _wasCaption ? SyncPlayRole.captain : SyncPlayRole.sailor,
      );
      _notifySessionChanged();
      // Continue to process the rest of the message
    }

    // Preserve our local participants list if server didn't send any
    // (server often sends state updates without participant info)
    final participants = group.participants.isNotEmpty
        ? group.participants
        : _currentSession!.group.participants;

    // Also ensure we're in the participants list (we might have been dropped)
    // Check both userId and deviceId for multi-device support
    final selfInList = participants.any((p) => p.userId == _userId && p.oderId == _deviceId);
    final updatedParticipants = selfInList
        ? participants
        : [
            ...participants,
            SyncPlayParticipant(
              oderId: _deviceId,
              userId: _userId,
              username: _username,
              userImageTag: _userImageTag,
              isGroupLeader: _currentSession!.isCaptain,
            ),
          ];

    // Check if the message contains queue data (sent on join)
    final playQueue = message.playQueue;
    List<SyncPlayTrack>? updatedQueue;
    int? updatedTrackIndex;

    if (playQueue != null) {
      // Try both 'Playlist' (per OpenAPI spec) and 'Items' (legacy/alternate)
      final playlist = playQueue['Playlist'] as List<dynamic>? ??
                       playQueue['Items'] as List<dynamic>?;
      if (playlist != null && playlist.isNotEmpty) {
        updatedTrackIndex = playQueue['PlayingItemIndex'] as int?;

        // Check if items have full track data or just IDs
        final firstItem = playlist.first;
        if (firstItem is Map && firstItem.containsKey('Item')) {
          // Full track data available
          updatedQueue = playlist
              .whereType<Map<String, dynamic>>()
              .map((item) => SyncPlayTrack.fromJson(
                    item,
                    serverUrl: _serverUrl,
                    token: _credentials.accessToken,
                    userId: _userId,
                  ))
              .toList();
          debugPrint('✅ Synced ${updatedQueue.length} full tracks from state update');
        } else {
          // Only IDs - use async fetch
          debugPrint('SyncPlay StateUpdate - got item IDs only, will fetch full data');
          _updateQueueFromIds(playlist, updatedTrackIndex);
        }
      }
    }

    // Preserve groupId and groupName if server sends empty/null ones
    // (server often sends state updates without group identity info)
    // Check for empty, all zeros (null GUID), or shorter than valid UUID
    final isInvalidGroupId = group.groupId.isEmpty ||
        group.groupId == '00000000000000000000000000000000' ||
        group.groupId == '00000000-0000-0000-0000-000000000000' ||
        group.groupId.length < 32;
    final preservedGroupId = isInvalidGroupId
        ? _currentSession!.group.groupId
        : group.groupId;
    final preservedGroupName = group.groupName.isNotEmpty && group.groupName != 'Collaborative Playlist'
        ? group.groupName
        : _currentSession!.group.groupName;

    _currentSession = _currentSession!.copyWith(
      group: group.copyWith(
        groupId: preservedGroupId,
        groupName: preservedGroupName,
        participants: updatedParticipants,
      ),
      isPaused: message.isPaused,
      positionTicks: message.positionTicks ?? _currentSession!.positionTicks,
      currentTrackIndex: updatedTrackIndex ?? message.playingItemIndex ?? _currentSession!.currentTrackIndex,
      queue: updatedQueue ?? _currentSession!.queue,
      lastSyncTime: DateTime.now(),
    );
    _notifySessionChanged();

    // Emit playback command if pause state changed (for sailors receiving groupStateUpdate)
    final nowPaused = _currentSession!.isPaused;
    if (wasPaused != nowPaused) {
      debugPrint('SyncPlay: isPaused changed from $wasPaused to $nowPaused');

      if (nowPaused) {
        // Changed to paused
        _playbackCommandController.add(SyncPlayCommand(
          type: SyncPlayCommandType.pause,
          positionTicks: _currentSession!.positionTicks,
        ));
      } else {
        // Changed to playing
        _playbackCommandController.add(SyncPlayCommand(
          type: SyncPlayCommandType.play,
          positionTicks: _currentSession!.positionTicks,
          trackIndex: _currentSession!.currentTrackIndex,
        ));
      }
    }
  }

  void _handleUserJoined(SyncPlayMessage message) {
    debugPrint('SyncPlay: User joined - userId: ${message.joinedUserId}');

    if (_currentSession == null) return;

    final userId = message.joinedUserId;
    if (userId != null && userId != _userId) {
      // Jellyfin only sends user ID, create minimal participant
      // and refresh group to get full details
      final participant = SyncPlayParticipant(
        oderId: '',
        userId: userId,
        username: userId, // Will be updated after refresh
        isGroupLeader: false,
      );

      // Add if not already in list
      if (!_currentSession!.group.participants.any((p) => p.userId == userId)) {
        final participants = [..._currentSession!.group.participants, participant];
        _currentSession = _currentSession!.copyWith(
          group: _currentSession!.group.copyWith(participants: participants),
        );
        _notifySessionChanged();
        _participantsController.add(participants);
      }

      // Refresh to get full participant info including imageTag
      final currentGroupId = _currentSession?.group.groupId;
      refreshGroups().then((_) {
        // Find our group and update participants with full data (including imageTag)
        if (_currentSession != null && currentGroupId != null) {
          final updatedGroup = _availableGroups.firstWhere(
            (g) => g.groupId == currentGroupId,
            orElse: () => _currentSession!.group,
          );

          if (updatedGroup.participants.isNotEmpty) {
            _currentSession = _currentSession?.copyWith(
              group: _currentSession!.group.copyWith(
                participants: updatedGroup.participants,
              ),
            );
            _notifySessionChanged();
            debugPrint('SyncPlay: Updated participants with full profile data');
          }
        }
      });
    }
  }

  void _handleUserLeft(SyncPlayMessage message) {
    debugPrint('SyncPlay: User left - userId: ${message.joinedUserId}');

    if (_currentSession == null) return;

    final userId = message.joinedUserId;
    if (userId != null) {
      final participants = _currentSession!.group.participants
          .where((p) => p.userId != userId)
          .toList();
      _currentSession = _currentSession!.copyWith(
        group: _currentSession!.group.copyWith(participants: participants),
      );
      _notifySessionChanged();
      _participantsController.add(participants);
    }
  }

  void _handleUnpause(SyncPlayMessage message) {
    if (_currentSession == null) return;

    debugPrint('SyncPlay: Unpause command received');
    final positionTicks = message.positionTicks ?? _currentSession!.positionTicks;
    final playlistItemId = message.playlistItemId;

    // If server sent a playlist item ID, update our current track index
    int trackIndex = _currentSession!.currentTrackIndex;
    if (playlistItemId != null) {
      final idx = _currentSession!.queue.indexWhere(
        (t) => t.playlistItemId == playlistItemId,
      );
      if (idx >= 0) {
        trackIndex = idx;
        debugPrint('SyncPlay: Unpause for track index $idx (playlistItemId: $playlistItemId)');
      }
    }

    _currentSession = _currentSession!.copyWith(
      isPaused: false,
      positionTicks: positionTicks,
      currentTrackIndex: trackIndex,
      lastSyncTime: DateTime.now(),
    );
    _notifySessionChanged();

    // Emit playback command for audio player to react
    _playbackCommandController.add(SyncPlayCommand(
      type: SyncPlayCommandType.play,
      positionTicks: positionTicks,
      trackIndex: trackIndex,
      playlistItemId: playlistItemId,
    ));
  }

  void _handlePause(SyncPlayMessage message) {
    if (_currentSession == null) return;

    debugPrint('SyncPlay: Pause command received');
    final positionTicks = message.positionTicks ?? _currentSession!.positionTicks;
    _currentSession = _currentSession!.copyWith(
      isPaused: true,
      positionTicks: positionTicks,
      lastSyncTime: DateTime.now(),
    );
    _notifySessionChanged();

    // Emit playback command for audio player to react
    _playbackCommandController.add(SyncPlayCommand(
      type: SyncPlayCommandType.pause,
      positionTicks: positionTicks,
    ));
  }

  void _handleStop(SyncPlayMessage message) {
    if (_currentSession == null) return;

    debugPrint('SyncPlay: Stop command received');
    _currentSession = _currentSession!.copyWith(
      isPaused: true,
      positionTicks: 0,
      currentTrackIndex: -1,
      lastSyncTime: DateTime.now(),
    );
    _notifySessionChanged();

    // Emit playback command for audio player to react
    _playbackCommandController.add(const SyncPlayCommand(
      type: SyncPlayCommandType.stop,
    ));
  }

  void _handleSeek(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final positionTicks = message.positionTicks;
    debugPrint('SyncPlay: Seek command received - position: $positionTicks');
    if (positionTicks != null) {
      _currentSession = _currentSession!.copyWith(
        positionTicks: positionTicks,
        lastSyncTime: DateTime.now(),
      );
      _notifySessionChanged();

      // Emit playback command for audio player to react
      _playbackCommandController.add(SyncPlayCommand(
        type: SyncPlayCommandType.seek,
        positionTicks: positionTicks,
      ));
    }
  }

  void _handleQueueUpdate(SyncPlayMessage message) {
    if (_currentSession == null) return;

    // Debug: log the raw message structure
    debugPrint('SyncPlay Queue Update - raw data keys: ${message.data.keys.toList()}');
    final nestedData = message.nestedData;
    debugPrint('SyncPlay Queue Update - nestedData keys: ${nestedData?.keys.toList()}');

    // Check if the message contains full queue data
    final playQueue = message.playQueue;
    debugPrint('SyncPlay Queue Update - playQueue keys: ${playQueue?.keys.toList()}');

    if (playQueue != null) {
      // Try both 'Playlist' (per OpenAPI spec) and 'Items' (legacy/alternate)
      final playlist = playQueue['Playlist'] as List<dynamic>? ??
                       playQueue['Items'] as List<dynamic>?;
      debugPrint('SyncPlay Queue Update - playlist count: ${playlist?.length}');

      if (playlist != null && playlist.isNotEmpty) {
        debugPrint('SyncPlay Queue Update - first item: ${playlist.first}');
        final trackIndex = playQueue['PlayingItemIndex'] as int?;

        // Check if items have full track data or just IDs
        final firstItem = playlist.first;
        if (firstItem is Map && firstItem.containsKey('Item')) {
          // Full track data available
          final updatedQueue = playlist
              .whereType<Map<String, dynamic>>()
              .map((item) => SyncPlayTrack.fromJson(
                    item,
                    serverUrl: _serverUrl,
                    token: _credentials.accessToken,
                    userId: _userId,
                  ))
              .toList();

          _currentSession = _currentSession!.copyWith(
            queue: updatedQueue,
            currentTrackIndex: trackIndex ?? _currentSession!.currentTrackIndex,
          );
          debugPrint('✅ Queue updated with ${updatedQueue.length} full tracks (index: $trackIndex)');
        } else {
          // Only IDs - need to fetch track details or merge with existing queue
          debugPrint('SyncPlay Queue Update - got item IDs only, fetching full data...');
          _updateQueueFromIds(playlist, trackIndex);
        }
      } else {
        // Empty playlist - clear the queue
        debugPrint('SyncPlay Queue Update - playlist is empty, clearing queue');
        _currentSession = _currentSession!.copyWith(
          queue: [],
          currentTrackIndex: -1,
        );
      }
    } else {
      debugPrint('⚠️ playQueue is null');
    }
    _notifySessionChanged();
  }

  /// Update queue when we only receive item IDs (not full track data)
  Future<void> _updateQueueFromIds(List<dynamic> playlist, int? trackIndex) async {
    // Extract item IDs and playlist item IDs
    final queueItems = <_QueueItemRef>[];
    for (final item in playlist) {
      if (item is Map) {
        final itemId = item['ItemId'] as String?;
        final playlistItemId = item['PlaylistItemId'] as String?;
        if (itemId != null && playlistItemId != null) {
          queueItems.add(_QueueItemRef(itemId: itemId, playlistItemId: playlistItemId));
        }
      }
    }

    if (queueItems.isEmpty) {
      debugPrint('SyncPlay: No valid queue items found');
      return;
    }

    // Try to reuse existing track data from current queue
    final existingTracks = <String, SyncPlayTrack>{};
    for (final track in _currentSession?.queue ?? <SyncPlayTrack>[]) {
      existingTracks[track.track.id] = track;
    }

    // Build new queue, reusing existing track data where possible
    final newQueue = <SyncPlayTrack>[];
    final missingIds = <String>[];

    for (final queueItem in queueItems) {
      final existing = existingTracks[queueItem.itemId];
      if (existing != null) {
        // Reuse existing track data but update playlistItemId
        newQueue.add(SyncPlayTrack(
          track: existing.track,
          addedByUserId: existing.addedByUserId,
          addedByUsername: existing.addedByUsername,
          addedByImageTag: existing.addedByImageTag,
          playlistItemId: queueItem.playlistItemId,
        ));
      } else {
        missingIds.add(queueItem.itemId);
        // Add placeholder that will be updated
        newQueue.add(SyncPlayTrack(
          track: JellyfinTrack(
            id: queueItem.itemId,
            name: 'Loading...',
            artists: const [],
            album: '',
            runTimeTicks: 0,
          ),
          addedByUserId: '',
          addedByUsername: '',
          playlistItemId: queueItem.playlistItemId,
        ));
      }
    }

    // Update session with what we have
    _currentSession = _currentSession!.copyWith(
      queue: newQueue,
      currentTrackIndex: trackIndex ?? _currentSession!.currentTrackIndex,
    );
    _notifySessionChanged();
    debugPrint('✅ Queue updated with ${newQueue.length} items (${missingIds.length} need fetching)');

    // Fetch missing track data if any
    if (missingIds.isNotEmpty) {
      _fetchMissingTrackData(missingIds);
    }
  }

  /// Fetch full track data for items we don't have cached
  Future<void> _fetchMissingTrackData(List<String> itemIds) async {
    try {
      for (final itemId in itemIds) {
        final track = await _client.getItem(
          credentials: _credentials,
          itemId: itemId,
        );
        if (track != null && _currentSession != null) {
          // Update the queue with fetched track data
          final updatedQueue = _currentSession!.queue.map((t) {
            if (t.track.id == itemId) {
              return SyncPlayTrack(
                track: track,
                addedByUserId: t.addedByUserId,
                addedByUsername: t.addedByUsername,
                addedByImageTag: t.addedByImageTag,
                playlistItemId: t.playlistItemId,
              );
            }
            return t;
          }).toList();

          _currentSession = _currentSession!.copyWith(queue: updatedQueue);
          _notifySessionChanged();
        }
      }
      debugPrint('✅ Fetched ${itemIds.length} missing track(s)');
    } catch (e) {
      debugPrint('Failed to fetch track data: $e');
    }
  }

  void _handleGroupLeft(SyncPlayMessage message) {
    // We were removed from the group - check why
    final reason = message.data['Reason'] as String?;
    debugPrint('GroupLeft received, reason: $reason');

    // If captain explicitly stopped the group, don't try to rejoin
    if (reason == 'GroupDestroyed' || reason == 'LibraryAccessDenied') {
      debugPrint('Group was destroyed or access denied, clearing session');
      _lastGroupId = null;
      _wasCaption = false;
      _currentSession = null;
      _trackAttributions.clear();
      _notifySessionChanged();
      return;
    }

    // Otherwise try to rejoin (network issue, temporary disconnect, etc.)
    if (_lastGroupId != null && !_isRejoining) {
      debugPrint('GroupLeft received, attempting auto-rejoin...');
      _rejoinAttempts = 0; // Reset attempts for fresh rejoin cycle
      _attemptAutoRejoin();
    } else if (!_isRejoining) {
      // No stored session - clear
      _currentSession = null;
      _trackAttributions.clear();
      _notifySessionChanged();
    }
    // If already rejoining, let that process continue
  }

  void _handleGroupJoined(SyncPlayMessage message) {
    debugPrint('SyncPlay: Group joined confirmation received');

    // The groupJoined message often contains full group state
    final groupState = message.groupState;
    if (groupState != null) {
      // If session not initialized yet, initialize it from this message
      if (_currentSession == null) {
        debugPrint('SyncPlay: Initializing session from groupJoined message');
        _currentSession = SyncPlaySession(
          group: groupState,
          queue: [],
          currentTrackIndex: -1,
          positionTicks: message.positionTicks ?? 0,
          role: _wasCaption ? SyncPlayRole.captain : SyncPlayRole.sailor,
        );
      } else {
        _currentSession = _currentSession!.copyWith(
          group: groupState,
        );
      }
      _notifySessionChanged();
    }

    // Check if the message contains queue data
    final playQueue = message.playQueue;
    if (playQueue != null && _currentSession != null) {
      // Try both 'Playlist' (per OpenAPI spec) and 'Items' (legacy/alternate)
      final playlist = playQueue['Playlist'] as List<dynamic>? ??
                       playQueue['Items'] as List<dynamic>?;
      if (playlist != null && playlist.isNotEmpty) {
        final trackIndex = playQueue['PlayingItemIndex'] as int?;

        // Check if items have full track data or just IDs
        final firstItem = playlist.first;
        if (firstItem is Map && firstItem.containsKey('Item')) {
          // Full track data available
          final updatedQueue = playlist
              .whereType<Map<String, dynamic>>()
              .map((item) => SyncPlayTrack.fromJson(
                    item,
                    serverUrl: _serverUrl,
                    token: _credentials.accessToken,
                    userId: _userId,
                  ))
              .toList();

          _currentSession = _currentSession!.copyWith(
            queue: updatedQueue,
            currentTrackIndex: trackIndex ?? _currentSession!.currentTrackIndex,
          );
          debugPrint('✅ Synced ${updatedQueue.length} full tracks from groupJoined');
          _notifySessionChanged();
        } else {
          // Only IDs - fetch full data
          debugPrint('SyncPlay GroupJoined - got item IDs only, fetching full data...');
          _updateQueueFromIds(playlist, trackIndex);
        }
      }
    }
  }

  // ============ Ping Timer ============

  void _startPingTimer() {
    _stopPingTimer();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _sendPing();
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  Future<void> _sendPing() async {
    if (_currentSession == null) return;

    try {
      await _client.ping(
        credentials: _credentials,
        ping: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('Failed to send SyncPlay ping: $e');
    }
  }

  // ============ Helper Methods ============

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(Object error) {
    _error = error;
    notifyListeners();
  }

  void _clearError() {
    _error = null;
  }

  void _notifySessionChanged() {
    _sessionController.add(_currentSession);
    if (_currentSession != null) {
      _participantsController.add(_currentSession!.group.participants);
    }
    notifyListeners();
  }

  /// Get user attribution for a track
  String? getTrackAddedBy(String playlistItemId) {
    // First check session queue
    final session = _currentSession;
    if (session != null) {
      for (final track in session.queue) {
        if (track.playlistItemId == playlistItemId) {
          return track.addedByUsername;
        }
      }
    }

    // Fall back to local attribution cache
    return _trackAttributions[playlistItemId]?.username;
  }

  /// Get the share link for the current session
  String? getShareLink() {
    final session = _currentSession;
    if (session == null) return null;

    return 'nautune://syncplay/join/${session.group.groupId}';
  }

  /// Get share URL (for web/universal links)
  String? getShareUrl() {
    final session = _currentSession;
    if (session == null) return null;

    return 'https://nautune.app/syncplay/${session.group.groupId}';
  }

  @override
  void dispose() {
    _disconnectWebSocket();
    _sessionController.close();
    _groupsController.close();
    _participantsController.close();
    _playbackCommandController.close();
    _client.close();
    super.dispose();
  }
}

/// Internal class to track user attribution for tracks
class _UserAttribution {
  const _UserAttribution({
    required this.userId,
    required this.username,
    this.imageTag,
  });

  final String userId;
  final String username;
  final String? imageTag;
}

/// Internal class to hold queue item references (itemId + playlistItemId)
class _QueueItemRef {
  const _QueueItemRef({
    required this.itemId,
    required this.playlistItemId,
  });

  final String itemId;
  final String playlistItemId;
}
