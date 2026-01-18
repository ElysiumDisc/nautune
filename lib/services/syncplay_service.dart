import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/syncplay_client.dart';
import '../models/syncplay_models.dart';
import 'syncplay_websocket.dart';

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

      // After creating, we automatically join as leader
      await _connectWebSocket();

      // Fetch groups to find our new group
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

    await _client.joinGroup(
      credentials: _credentials,
      groupId: groupId,
    );

    // Refresh groups to get current participants after joining
    await refreshGroups();

    await _connectWebSocket();

    // Initialize session state
    final group = _availableGroups.firstWhere(
      (g) => g.groupId == groupId,
      orElse: () => SyncPlayGroup(
        groupId: groupId,
        groupName: 'Collaborative Playlist',
        participants: [],
        state: SyncPlayState.idle,
      ),
    );

    _currentSession = SyncPlaySession(
      group: group.copyWith(
        participants: [
          ...group.participants,
          SyncPlayParticipant(
            oderId: _deviceId,
            userId: _userId,
            username: _username,
            userImageTag: _userImageTag,
            isGroupLeader: isCaptain,
          ),
        ],
      ),
      queue: [],
      currentTrackIndex: -1,
      positionTicks: 0,
      role: isCaptain ? SyncPlayRole.captain : SyncPlayRole.sailor,
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
      _groupsController.add(_availableGroups);
    } catch (e) {
      debugPrint('Failed to refresh SyncPlay groups: $e');
    }
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

  /// Attempt to rejoin the last group after WebSocket reconnection
  Future<void> _attemptAutoRejoin() async {
    if (_isRejoining || _lastGroupId == null) return;

    _isRejoining = true;
    try {
      debugPrint('Auto-rejoining group: $_lastGroupId (captain: $_wasCaption)');

      // Try to rejoin the group
      await _client.joinGroup(
        credentials: _credentials,
        groupId: _lastGroupId!,
      );

      // Restore session state with stored captain status
      if (_currentSession == null) {
        _currentSession = SyncPlaySession(
          group: SyncPlayGroup(
            groupId: _lastGroupId!,
            groupName: 'Collaborative Playlist',
            participants: [
              SyncPlayParticipant(
                oderId: _deviceId,
                userId: _userId,
                username: _username,
                userImageTag: _userImageTag,
                isGroupLeader: _wasCaption,
              ),
            ],
            state: SyncPlayState.idle,
          ),
          queue: [],
          currentTrackIndex: -1,
          positionTicks: 0,
          role: _wasCaption ? SyncPlayRole.captain : SyncPlayRole.sailor,
        );
        _notifySessionChanged();
      }

      debugPrint('✅ Auto-rejoined SyncPlay group successfully');
    } catch (e) {
      debugPrint('Failed to auto-rejoin SyncPlay group: $e');
      // Group may no longer exist - clear stored info
      _lastGroupId = null;
      _wasCaption = false;
    } finally {
      _isRejoining = false;
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
    debugPrint('SyncPlay message: ${message.type}');

    switch (message.type) {
      case SyncPlayMessageType.groupStateUpdate:
        _handleGroupStateUpdate(message);
        break;

      case SyncPlayMessageType.userJoined:
        _handleUserJoined(message);
        break;

      case SyncPlayMessageType.userLeft:
        _handleUserLeft(message);
        break;

      case SyncPlayMessageType.playPause:
        _handlePlayPause(message);
        break;

      case SyncPlayMessageType.seek:
        _handleSeek(message);
        break;

      case SyncPlayMessageType.queueUpdate:
        _handleQueueUpdate(message);
        break;

      case SyncPlayMessageType.setPlaylistItem:
        _handleSetPlaylistItem(message);
        break;

      case SyncPlayMessageType.groupLeft:
        _handleGroupLeft(message);
        break;

      default:
        break;
    }
  }

  void _handleGroupStateUpdate(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final group = message.groupState;
    if (group != null) {
      // Preserve our local participants list if server didn't send any
      // (server often sends state updates without participant info)
      final participants = group.participants.isNotEmpty
          ? group.participants
          : _currentSession!.group.participants;

      // Also ensure we're in the participants list (we might have been dropped)
      final selfInList = participants.any((p) => p.userId == _userId);
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

      _currentSession = _currentSession!.copyWith(
        group: group.copyWith(participants: updatedParticipants),
        isPaused: message.isPaused,
        positionTicks: message.positionTicks ?? _currentSession!.positionTicks,
        currentTrackIndex: message.playingItemIndex ?? _currentSession!.currentTrackIndex,
        lastSyncTime: DateTime.now(),
      );
      _notifySessionChanged();
    }
  }

  void _handleUserJoined(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final participant = message.participant;
    if (participant != null) {
      final participants = [..._currentSession!.group.participants, participant];
      _currentSession = _currentSession!.copyWith(
        group: _currentSession!.group.copyWith(participants: participants),
      );
      _notifySessionChanged();
      _participantsController.add(participants);
    }
  }

  void _handleUserLeft(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final participant = message.participant;
    if (participant != null) {
      final participants = _currentSession!.group.participants
          .where((p) => p.userId != participant.userId)
          .toList();
      _currentSession = _currentSession!.copyWith(
        group: _currentSession!.group.copyWith(participants: participants),
      );
      _notifySessionChanged();
      _participantsController.add(participants);
    }
  }

  void _handlePlayPause(SyncPlayMessage message) {
    if (_currentSession == null) return;

    _currentSession = _currentSession!.copyWith(
      isPaused: message.isPaused,
      positionTicks: message.positionTicks ?? _currentSession!.positionTicks,
      lastSyncTime: DateTime.now(),
    );
    _notifySessionChanged();
  }

  void _handleSeek(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final positionTicks = message.positionTicks;
    if (positionTicks != null) {
      _currentSession = _currentSession!.copyWith(
        positionTicks: positionTicks,
        lastSyncTime: DateTime.now(),
      );
      _notifySessionChanged();
    }
  }

  void _handleQueueUpdate(SyncPlayMessage message) {
    // Queue updates come as full state - refresh from server would be ideal
    // For now, rely on optimistic updates
    _notifySessionChanged();
  }

  void _handleSetPlaylistItem(SyncPlayMessage message) {
    if (_currentSession == null) return;

    final playlistItemId = message.playlistItemId;
    final playingIndex = message.playingItemIndex;

    if (playingIndex != null) {
      _currentSession = _currentSession!.copyWith(
        currentTrackIndex: playingIndex,
        positionTicks: 0,
        lastSyncTime: DateTime.now(),
      );
      _notifySessionChanged();
    } else if (playlistItemId != null) {
      // Find index by playlist item ID
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
    }
  }

  void _handleGroupLeft(SyncPlayMessage message) {
    // We were removed from the group - try to rejoin if we have stored session
    if (_lastGroupId != null && !_isRejoining) {
      debugPrint('GroupLeft received, attempting auto-rejoin...');
      _attemptAutoRejoin();
    } else {
      // No stored session or already rejoining - just clear
      _currentSession = null;
      _trackAttributions.clear();
      _notifySessionChanged();
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
