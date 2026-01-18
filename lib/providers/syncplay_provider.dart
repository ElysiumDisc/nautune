import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_session.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/syncplay_models.dart';
import '../services/audio_cache_service.dart';
import '../services/audio_player_service.dart';
import '../services/syncplay_service.dart';
import 'session_provider.dart';

/// Provider for SyncPlay state management in the UI layer.
///
/// Responsibilities:
/// - Exposes SyncPlay session state to widgets
/// - Handles session initialization and cleanup
/// - Provides convenient methods for UI actions
/// - Manages loading and error states
/// - Triggers actual audio playback for Captain
/// - Pre-caches tracks for waveform/FFT/lyrics
class SyncPlayProvider extends ChangeNotifier {
  SyncPlayProvider({
    required SessionProvider sessionProvider,
    required JellyfinService jellyfinService,
    required AudioPlayerService audioPlayerService,
  }) : _sessionProvider = sessionProvider,
       _jellyfinService = jellyfinService,
       _audioPlayerService = audioPlayerService {
    _sessionProvider.addListener(_onSessionChanged);
    _initializeIfNeeded();
  }

  final SessionProvider _sessionProvider;
  final JellyfinService _jellyfinService;
  final AudioPlayerService _audioPlayerService;
  final AudioCacheService _audioCacheService = AudioCacheService.instance;
  SyncPlayService? _syncPlayService;
  StreamSubscription<SyncPlaySession?>? _sessionSubscription;
  StreamSubscription<List<SyncPlayParticipant>>? _participantsSubscription;

  // State
  SyncPlaySession? _currentSession;
  List<SyncPlayGroup> _availableGroups = [];
  bool _isLoading = false;
  bool _isCreating = false;
  bool _isJoining = false;
  Object? _error;

  // Getters
  SyncPlaySession? get currentSession => _currentSession;
  List<SyncPlayGroup> get availableGroups => _availableGroups;
  bool get isLoading => _isLoading;
  bool get isCreating => _isCreating;
  bool get isJoining => _isJoining;
  Object? get error => _error;

  // Session state getters
  bool get isInSession => _currentSession != null;
  bool get isCaptain => _currentSession?.isCaptain ?? false;
  bool get isSailor => _currentSession != null && !_currentSession!.isCaptain;
  SyncPlayRole get role => _currentSession?.role ?? SyncPlayRole.sailor;

  // Group info getters
  String? get groupName => _currentSession?.group.groupName;
  String? get groupId => _currentSession?.group.groupId;
  List<SyncPlayParticipant> get participants =>
      _currentSession?.group.participants ?? [];
  int get participantCount => participants.length;

  // Queue getters
  List<SyncPlayTrack> get queue => _currentSession?.queue ?? [];
  SyncPlayTrack? get currentTrack => _currentSession?.currentTrack;
  int get currentTrackIndex => _currentSession?.currentTrackIndex ?? -1;
  List<SyncPlayTrack> get upNext => _currentSession?.upNext ?? [];

  // Playback state getters
  bool get isPaused => _currentSession?.isPaused ?? true;
  bool get isPlaying => !isPaused;
  Duration get position => _currentSession?.position ?? Duration.zero;
  bool get isBuffering => _currentSession?.isBuffering ?? false;

  // Share info getters
  String? get shareLink => _syncPlayService?.getShareLink();
  String? get shareUrl => _syncPlayService?.getShareUrl();

  void _onSessionChanged() {
    final session = _sessionProvider.session;
    if (session == null) {
      // User logged out
      _cleanup();
    } else {
      // Session changed - reinitialize if needed
      _initializeIfNeeded();
    }
  }

  String? _userImageTag;
  bool _isInitializing = false;

  void _initializeIfNeeded() {
    final session = _sessionProvider.session;
    if (session == null || session.isDemo) {
      _cleanup();
      return;
    }

    // Create service if not exists or session changed
    if (_syncPlayService == null && !_isInitializing) {
      _createServiceAsync(session);
    }
  }

  Future<void> _createServiceAsync(JellyfinSession session) async {
    _isInitializing = true;

    // Fetch the user's profile image tag
    try {
      final user = await _jellyfinService.getCurrentUser();
      _userImageTag = user.primaryImageTag;
    } catch (e) {
      debugPrint('Failed to fetch user profile for image: $e');
    }

    _syncPlayService = SyncPlayService(
      serverUrl: session.serverUrl,
      deviceId: session.deviceId,
      credentials: session.credentials,
      userId: session.credentials.userId,
      username: session.username,
      userImageTag: _userImageTag,
    );

    // Listen to session changes
    _sessionSubscription = _syncPlayService!.sessionStream.listen((syncSession) {
      _currentSession = syncSession;
      notifyListeners();
    });

    // Listen to service loading state
    _syncPlayService!.addListener(_onServiceChanged);

    _isInitializing = false;
  }

  void _onServiceChanged() {
    _isLoading = _syncPlayService?.isLoading ?? false;
    _error = _syncPlayService?.error;
    _availableGroups = _syncPlayService?.availableGroups ?? [];
    notifyListeners();
  }

  void _cleanup() {
    _sessionSubscription?.cancel();
    _sessionSubscription = null;
    _participantsSubscription?.cancel();
    _participantsSubscription = null;
    _syncPlayService?.removeListener(_onServiceChanged);
    _syncPlayService?.dispose();
    _syncPlayService = null;
    _currentSession = null;
    _availableGroups = [];
    _isLoading = false;
    _isCreating = false;
    _isJoining = false;
    _error = null;
    notifyListeners();
  }

  // ============ Group Management ============

  /// Create a new collaborative playlist (becomes Captain)
  Future<void> createCollabPlaylist(String name) async {
    if (_syncPlayService == null) return;

    _isCreating = true;
    _error = null;
    notifyListeners();

    try {
      await _syncPlayService!.createGroup(name);
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      _isCreating = false;
      notifyListeners();
    }
  }

  /// Join an existing collaborative playlist (becomes Sailor)
  Future<void> joinCollabPlaylist(String groupId) async {
    if (_syncPlayService == null) return;

    _isJoining = true;
    _error = null;
    notifyListeners();

    try {
      await _syncPlayService!.joinGroup(groupId);
    } catch (e) {
      _error = e;
      rethrow;
    } finally {
      _isJoining = false;
      notifyListeners();
    }
  }

  /// Leave the current collaborative playlist
  Future<void> leaveCollabPlaylist() async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.leaveGroup();
    } catch (e) {
      _error = e;
      rethrow;
    }
  }

  /// Refresh available groups
  Future<void> refreshGroups() async {
    if (_syncPlayService == null) {
      debugPrint('SyncPlayProvider: Cannot refresh groups, service is null');
      return;
    }

    try {
      debugPrint('SyncPlayProvider: Refreshing groups...');
      await _syncPlayService!.refreshGroups();
      _availableGroups = _syncPlayService!.availableGroups;
      debugPrint('SyncPlayProvider: Refreshed groups, found ${_availableGroups.length} groups');
      for (final group in _availableGroups) {
        debugPrint(' - Group: ${group.groupName} (${group.groupId})');
      }
      notifyListeners();
    } catch (e) {
      debugPrint('SyncPlayProvider: Failed to refresh groups: $e');
    }
  }

  // ============ Queue Management ============

  /// Add tracks to the queue
  Future<void> addToQueue(List<JellyfinTrack> tracks) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.addToQueue(tracks);
      // Pre-cache tracks in background for waveform/FFT/lyrics
      _preCacheTracks(tracks);
    } catch (e) {
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  /// Add a single track to the queue
  Future<void> addTrackToQueue(JellyfinTrack track) async {
    return addToQueue([track]);
  }

  /// Add tracks to play next
  Future<void> addToQueueNext(List<JellyfinTrack> tracks) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.addToQueue(tracks, mode: SyncPlayQueueMode.queueNext);
      // Pre-cache tracks in background for waveform/FFT/lyrics
      _preCacheTracks(tracks);
    } catch (e) {
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  /// Pre-cache tracks in background for waveform, FFT visualizer, and lyrics
  void _preCacheTracks(List<JellyfinTrack> tracks) {
    for (final track in tracks) {
      // Fire and forget - cache in background
      _audioCacheService.cacheTrack(track).then((_) {
        debugPrint('✅ Pre-cached collab track: ${track.name}');
      }).catchError((e) {
        debugPrint('⚠️ Failed to pre-cache collab track: $e');
      });
    }
  }

  /// Remove a track from the queue
  Future<void> removeFromQueue(String playlistItemId) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.removeFromQueue(playlistItemId);
    } catch (e) {
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  /// Reorder a track in the queue
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.reorderQueue(oldIndex, newIndex);
    } catch (e) {
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  /// Set a completely new queue
  Future<void> setQueue(List<JellyfinTrack> tracks, {int startIndex = 0}) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.setQueue(tracks, startIndex: startIndex);
    } catch (e) {
      _error = e;
      notifyListeners();
      rethrow;
    }
  }

  // ============ Playback Control ============
  // All methods send commands to SyncPlay server.
  // Captain's device also controls local audio playback.

  /// Play / Resume
  Future<void> play() async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.play();
      // Captain controls local audio
      if (isCaptain) {
        await _audioPlayerService.resume();
      }
    } catch (e) {
      debugPrint('Failed to play: $e');
    }
  }

  /// Pause
  Future<void> pause() async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.pause();
      // Captain controls local audio
      if (isCaptain) {
        await _audioPlayerService.pause();
      }
    } catch (e) {
      debugPrint('Failed to pause: $e');
    }
  }

  /// Toggle play/pause
  Future<void> togglePlayPause() async {
    if (isPaused) {
      await play();
    } else {
      await pause();
    }
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.seek(position);
      // Captain controls local audio
      if (isCaptain) {
        await _audioPlayerService.seek(position);
      }
    } catch (e) {
      debugPrint('Failed to seek: $e');
    }
  }

  /// Skip to next track
  Future<void> nextTrack() async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.nextTrack();
      // Captain controls local audio
      if (isCaptain) {
        await _audioPlayerService.next();
      }
    } catch (e) {
      debugPrint('Failed to skip: $e');
    }
  }

  /// Skip to previous track
  Future<void> previousTrack() async {
    if (_syncPlayService == null) return;

    try {
      await _syncPlayService!.previousTrack();
      // Captain controls local audio
      if (isCaptain) {
        await _audioPlayerService.previous();
      }
    } catch (e) {
      debugPrint('Failed to go back: $e');
    }
  }

  /// Play specific track in queue
  /// Sends command to SyncPlay server AND plays locally if Captain
  Future<void> playTrackAtIndex(int index) async {
    if (_syncPlayService == null || index < 0 || index >= queue.length) return;

    try {
      final syncTrack = queue[index];
      await _syncPlayService!.setCurrentTrack(syncTrack.playlistItemId);

      // Captain actually plays audio locally
      if (isCaptain) {
        final jellyfinTrack = syncTrack.track;
        // Build queue of JellyfinTracks for the audio player
        final playerQueue = queue.map((t) => t.track).toList();
        await _audioPlayerService.playTrack(
          jellyfinTrack,
          queueContext: playerQueue,
          reorderQueue: false,
        );
      }
    } catch (e) {
      debugPrint('Failed to set track: $e');
    }
  }

  // ============ Sync State ============

  /// Signal ready state
  Future<void> signalReady() async {
    await _syncPlayService?.signalReady(true);
  }

  /// Report buffering state
  Future<void> reportBuffering(bool isBuffering) async {
    await _syncPlayService?.reportBuffering(isBuffering);
  }

  // ============ Helpers ============

  /// Get user attribution for a track
  String? getTrackAddedBy(String playlistItemId) {
    return _syncPlayService?.getTrackAddedBy(playlistItemId);
  }

  /// Check if we can add tracks to the session
  bool get canAddTracks => isInSession;

  /// Check if we can control playback (Captain only for some controls)
  bool get canControlPlayback => isInSession;

  /// Clear any error
  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionProvider.removeListener(_onSessionChanged);
    _cleanup();
    super.dispose();
  }
}
