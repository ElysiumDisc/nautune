import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, sin;
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import 'audio_handler.dart';
import 'download_service.dart';
import 'playback_reporting_service.dart';
import 'playback_state_store.dart';
import '../models/playback_state.dart';

enum RepeatMode {
  off,      // No repeat
  all,      // Repeat queue
  one,      // Repeat current track
}

class AudioPlayerService {
  static const int _visualizerBarCount = 24;
  static const int _maxCachedTracks = 5; // Cache up to 5 upcoming tracks for streaming
  
  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _nextPlayer = AudioPlayer();
  final PlaybackStateStore _stateStore = PlaybackStateStore();
  DownloadService? _downloadService;
  PlaybackReportingService? _reportingService;
  NautuneAudioHandler? _audioHandler;
  JellyfinService? _jellyfinService;
  double _volume = 1.0;
  bool _isShuffleEnabled = false;
  bool _hasRestored = false;
  PlaybackState? _pendingState;
  
  // Stream caching for better performance
  final Map<String, String> _cachedStreamUrls = {};
  Timer? _cacheCleanupTimer;
  
  // Crossfade support
  AudioPlayer? _crossfadePlayer;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  Timer? _crossfadeTimer;
  bool _isCrossfading = false;
  String? _currentAlbumId;
  String? _nextTrackAlbumId;
  
  JellyfinTrack? _currentTrack;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  Timer? _positionSaveTimer;
  bool _isTransitioning = false;
  Duration _lastPosition = Duration.zero;
  bool _lastPlayingState = false;
  RepeatMode _repeatMode = RepeatMode.off;
  final StreamController<double> _volumeController = StreamController<double>.broadcast();
  final StreamController<bool> _shuffleController = StreamController<bool>.broadcast();
  final StreamController<List<double>> _visualizerController = StreamController<List<double>>.broadcast();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  void setDownloadService(DownloadService service) {
    _downloadService = service;
  }

  void setReportingService(PlaybackReportingService service) {
    _reportingService = service;
    _reportingService!.attachPositionProvider(() => _lastPosition);
  }

  void setCrossfadeEnabled(bool enabled) {
    _crossfadeEnabled = enabled;
    if (!enabled) {
      _cancelCrossfade();
    }
  }

  void setCrossfadeDuration(int seconds) {
    _crossfadeDurationSeconds = seconds.clamp(0, 10);
  }

  void _cancelCrossfade() {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _isCrossfading = false;
    _crossfadePlayer?.dispose();
    _crossfadePlayer = null;
  }

  void setJellyfinService(JellyfinService service) {
    _jellyfinService = service;
    if (_pendingState != null && !_hasRestored) {
      unawaited(applyStoredState(_pendingState!));
    }
  }
  
  // Streams
  final StreamController<JellyfinTrack?> _currentTrackController = StreamController<JellyfinTrack?>.broadcast();
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController = StreamController<Duration?>.broadcast();
  final StreamController<List<JellyfinTrack>> _queueController = StreamController<List<JellyfinTrack>>.broadcast();
  final StreamController<RepeatMode> _repeatModeController = StreamController<RepeatMode>.broadcast();
  
  Stream<JellyfinTrack?> get currentTrackStream => _currentTrackController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<List<JellyfinTrack>> get queueStream => _queueController.stream;
  Stream<RepeatMode> get repeatModeStream => _repeatModeController.stream;
  Stream<double> get volumeStream => _volumeController.stream;
  Stream<bool> get shuffleStream => _shuffleController.stream;
  Stream<List<double>> get visualizerStream => _visualizerController.stream;
  
  JellyfinTrack? get currentTrack => _currentTrack;
  bool get isPlaying => _player.state == PlayerState.playing;
  Duration get currentPosition => _lastPosition;
  AudioPlayer get player => _player;
  List<JellyfinTrack> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  RepeatMode get repeatMode => _repeatMode;
  double get volume => _volume;
  bool get shuffleEnabled => _isShuffleEnabled;
  
  /// Updates the current track (e.g., for favorite status changes)
  void updateCurrentTrack(JellyfinTrack track) {
    debugPrint('🔄 AudioService: Updating current track to: ${track.name}, isFavorite=${track.isFavorite}');
    _currentTrack = track;
    _currentTrackController.add(track);
    debugPrint('📡 AudioService: Broadcasted track update to stream');
    
    // Also update in queue if present
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      _queue[_currentIndex] = track;
      _queueController.add(List.from(_queue));
      debugPrint('🔄 AudioService: Updated track in queue at index $_currentIndex');
    }

    unawaited(_stateStore.savePlaybackSnapshot(
      currentTrack: track,
      queue: _queue,
      currentQueueIndex: _currentIndex,
    ));
  }
  
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0) as double;
    _volume = clamped;
    _volumeController.add(_volume);
    await Future.wait([
      _player.setVolume(_volume),
      _nextPlayer.setVolume(_volume),
    ]);
    unawaited(_stateStore.savePlaybackSnapshot(volume: _volume));
  }
  
  AudioPlayerService() {
    _initAudioSession();
    _setupListeners();
    _initAudioHandler();
    _player.setVolume(_volume);
    _nextPlayer.setVolume(_volume);
    _volumeController.add(_volume);
    _emitIdleVisualizer();
    _startCacheCleanup();
  }

  String get _deviceId => 'nautune-${Platform.operatingSystem}';
  
  Future<void> _initAudioHandler() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    
    try {
      _audioHandler = await audio_service.AudioService.init(
        builder: () => NautuneAudioHandler(
          player: _player,
          onPlay: () => resume(),
          onPause: () => pause(),
          onStop: () => stop(),
          onSkipToNext: () => skipToNext(),
          onSkipToPrevious: () => skipToPrevious(),
          onSeek: (position) => seek(position),
        ),
        config: const audio_service.AudioServiceConfig(
          androidNotificationChannelId: 'com.elysiumdisc.nautune.channel.audio',
          androidNotificationChannelName: 'Nautune Audio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      print('✅ Audio service initialized for lock screen controls');
    } catch (e) {
      print('⚠️ Audio service initialization failed: $e');
    }
  }
  
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      
      // Handle audio interruptions (phone calls, other media apps)
      await _interruptionSubscription?.cancel();
      _interruptionSubscription = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          if (event.type == AudioInterruptionType.pause ||
              event.type == AudioInterruptionType.duck ||
              event.type == AudioInterruptionType.unknown) {
            unawaited(pause());
          }
        } else {
          if (event.type == AudioInterruptionType.pause && !isPlaying) {
            unawaited(resume());
          }
        }
      });

      // Pause when headphones are unplugged / audio becomes noisy
      await _becomingNoisySubscription?.cancel();
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        unawaited(pause());
      });
    } catch (e) {
      print('Audio session setup failed: $e');
    }
  }
  
  void _setupListeners() {
    // Position updates
    _player.onPositionChanged.listen((position) {
      _positionController.add(position);
      _lastPosition = position;
      if (_player.state == PlayerState.playing) {
        _emitVisualizerFrame(position);
      }
      // Check if we should start crossfade
      _checkCrossfadeTrigger(position);
    });

    // Duration updates
    _player.onDurationChanged.listen((duration) {
      _durationController.add(duration);
    });
    
    // State changes
    _player.onPlayerStateChanged.listen((state) {
      final isPlaying = state == PlayerState.playing;
      _playingController.add(isPlaying);
      
      // Report state change to Jellyfin
      if (_lastPlayingState != isPlaying && _currentTrack != null) {
        _lastPlayingState = isPlaying;
        if (_reportingService != null) {
          _reportingService!.reportPlaybackProgress(
            _currentTrack!,
            _lastPosition,
            !isPlaying, // isPaused
          );
        }
      }
      
      if (isPlaying) {
        _startPositionSaving();
        unawaited(_stateStore.savePlaybackSnapshot(isPlaying: true));
      } else {
        _stopPositionSaving();
        _saveCurrentPosition();
        _emitIdleVisualizer();
        unawaited(_stateStore.savePlaybackSnapshot(isPlaying: false));
      }
    });
    
    // Track completion - gapless transition
    _player.onPlayerComplete.listen((_) async {
      if (!_isTransitioning) {
        await _gaplessTransition();
      }
    });
  }
  
  Future<void> _gaplessTransition() async {
    // Handle repeat one mode
    if (_repeatMode == RepeatMode.one && _currentTrack != null) {
      debugPrint('🔁 Repeating current track');
      // Replay the track from beginning
      await playTrack(
        _currentTrack!,
        queueContext: _queue,
        fromShuffle: _isShuffleEnabled,
      );
      return;
    }
    
    // Move to next track
    if (_currentIndex + 1 < _queue.length) {
      _isTransitioning = true;
      
      // Swap players for gapless playback
      final temp = _player;
      // Note: This is a simplified approach. For true gapless,
      // we'd need platform-specific implementations or just_audio package
      
      _currentIndex++;
      _currentTrack = _queue[_currentIndex];
      _currentTrackController.add(_currentTrack);
      
      // Preload next track if available
      if (_currentIndex + 1 < _queue.length) {
        await _preloadNextTrack();
      }
      
      _isTransitioning = false;
      _saveCurrentPosition();
    } else {
      // Queue finished - handle repeat all mode
      if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        debugPrint('🔁 Repeating queue from beginning');
        _currentIndex = 0;
        await playTrack(
          _queue[0],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        );
      } else {
        // Stop playback
        await stop();
      }
    }
  }
  
  Future<void> _preloadNextTrack() async {
    if (_currentIndex + 1 >= _queue.length) return;
    
    final nextTrack = _queue[_currentIndex + 1];
    final url = nextTrack.directDownloadUrl();
    
    if (url != null) {
      try {
        await _nextPlayer.setSource(UrlSource(url));
        await _nextPlayer.setVolume(_volume);
      } catch (e) {
        // Preload failed, will try regular load on track change
      }
    }
  }
  
  Future<void> hydrateFromPersistence(PlaybackState? state) async {
    if (state == null) {
      return;
    }
    _pendingState = state;
    await _attemptRestoreFromPending();
  }

  Future<void> applyStoredState(PlaybackState state) async {
    _pendingState = state;
    await _attemptRestoreFromPending(force: true);
  }

  Future<void> _attemptRestoreFromPending({bool force = false}) async {
    if (_hasRestored && !force) return;
    final state = _pendingState ?? await _stateStore.load();
    if (state == null) return;
    final queue = await _buildQueueFromState(state);

    if (state.queueIds.isNotEmpty && queue.isEmpty) {
      // Wait until we can resolve queue items (likely requires Jellyfin session).
      _pendingState = state;
      return;
    }

    await _applyStateFromStorage(state, queue);
    _pendingState = null;
    _hasRestored = true;
  }

  Future<List<JellyfinTrack>> _buildQueueFromState(PlaybackState state) async {
    if (state.queueSnapshot.isNotEmpty) {
      return state.toQueueTracks();
    }
    if (state.queueIds.isEmpty) {
      return const [];
    }

    final jellyfin = _jellyfinService;
    if (jellyfin != null) {
      try {
        final tracks = await jellyfin.loadTracksByIds(state.queueIds);
        if (tracks.isNotEmpty) {
          return tracks;
        }
      } catch (e) {
        debugPrint('⚠️ Failed to restore queue from Jellyfin: $e');
      }
    }

    final downloadService = _downloadService;
    if (downloadService != null) {
      final restored = <JellyfinTrack>[];
      for (final id in state.queueIds) {
        final track = downloadService.trackFor(id);
        if (track != null) {
          restored.add(track);
        }
      }
      if (restored.isNotEmpty) {
        return restored;
      }
    }

    return const [];
  }

  Future<void> _applyStateFromStorage(
    PlaybackState state,
    List<JellyfinTrack> queue,
  ) async {
    _volume = state.volume.clamp(0.0, 1.0);
    await _player.setVolume(_volume);
    await _nextPlayer.setVolume(_volume);
    _volumeController.add(_volume);

    _repeatMode = RepeatMode.values.firstWhere(
      (mode) => mode.name == state.repeatMode,
      orElse: () => RepeatMode.off,
    );
    _repeatModeController.add(_repeatMode);

    _isShuffleEnabled = state.shuffleEnabled;
    _shuffleController.add(_isShuffleEnabled);

    if (queue.isEmpty) {
      return;
    }

    final clampedIndex = state.currentQueueIndex.clamp(0, queue.length - 1);
    final track = queue[clampedIndex];

    await playTrack(
      track,
      queueContext: queue,
      reorderQueue: false,
      fromShuffle: state.shuffleEnabled,
    );

    if (state.positionMs > 0) {
      final position = Duration(milliseconds: state.positionMs);
      await seek(position);
    }

    if (!state.isPlaying) {
      await pause();
    }
  }
  
  Future<void> playTrack(
    JellyfinTrack track, {
    List<JellyfinTrack>? queueContext,
    String? albumId,
    String? albumName,
    bool reorderQueue = false,
    bool fromShuffle = false,
  }) async {
    _isShuffleEnabled = fromShuffle;
    _shuffleController.add(_isShuffleEnabled);

    _currentTrack = track;
    _currentTrackController.add(track);
    
    if (queueContext != null) {
      if (reorderQueue) {
        _queue = List<JellyfinTrack>.from(queueContext)
          ..sort((a, b) {
            final discA = a.discNumber ?? 0;
            final discB = b.discNumber ?? 0;
            if (discA != discB) return discA.compareTo(discB);
            final trackA = a.indexNumber ?? 0;
            final trackB = b.indexNumber ?? 0;
            if (trackA != trackB) return trackA.compareTo(trackB);
            return a.name.compareTo(b.name);
          });
      } else {
        _queue = queueContext;
      }
      _currentIndex = _queue.indexWhere((t) => t.id == track.id);
      if (_currentIndex == -1) {
        _queue = [track];
        _currentIndex = 0;
      }
    } else {
      _queue = [track];
      _currentIndex = 0;
    }
    
    _queueController.add(_queue);
    
    // Update audio handler with current track metadata
    _audioHandler?.updateNautuneMediaItem(track);
    _audioHandler?.updateNautuneQueue(_queue);
    
    final downloadUrl = track.directDownloadUrl();
    final universalUrl = track.universalStreamUrl(
      deviceId: _deviceId,
      maxBitrate: 320000,
      audioCodec: 'mp3',
      container: 'mp3',
    );

    await _player.stop();

    Future<bool> trySetSource(String? url, {bool isFile = false}) async {
      if (url == null) return false;
      try {
        if (isFile) {
          await _player.setSource(DeviceFileSource(url));
        } else {
          await _player.setSource(UrlSource(url));
        }
        await _player.setVolume(_volume);
        return true;
      } on PlatformException {
        return false;
      }
    }
    Future<bool> trySetAssetSource(String? assetPath) async {
      if (assetPath == null) return false;
      final normalized = assetPath.startsWith('assets/')
          ? assetPath.substring('assets/'.length)
          : assetPath;
      try {
        await _player.setSource(AssetSource(normalized));
        await _player.setVolume(_volume);
        return true;
      } on PlatformException {
        return false;
      }
    }

    String? activeUrl;
    bool isOffline = false;
    
    // Check for downloaded file first (works in airplane mode!)
    final localPath = _downloadService?.getLocalPath(track.id);
    if (localPath != null) {
      // Verify file exists before trying to play
      final file = File(localPath);
      if (await file.exists()) {
        if (await trySetSource(localPath, isFile: true)) {
          activeUrl = localPath;
          isOffline = true;
          print('✅ Playing from local file: $localPath');
        } else {
          print('⚠️ Local file exists but failed to load: $localPath');
        }
      } else {
        print('⚠️ Local file not found (may be orphaned): $localPath');
        // Clean up orphaned reference
        await _downloadService?.verifyAndCleanupDownloads();
      }
    }
    
    // Try streaming if no local file or local file failed
    if (activeUrl == null) {
      if (await trySetSource(downloadUrl)) {
        activeUrl = downloadUrl;
      } else if (await trySetSource(universalUrl)) {
        activeUrl = universalUrl;
      } else if (await trySetAssetSource(track.assetPathOverride)) {
        activeUrl = track.assetPathOverride;
      }
    }

    if (activeUrl == null) {
      throw PlatformException(
        code: 'no_source',
        message: 'Unable to play ${track.name}. File may be unavailable.',
      );
    }

    try {
      await _player.resume();
      
      // Report playback start to Jellyfin
      if (_reportingService != null) {
        print('🎵 Reporting playback start to Jellyfin: ${track.name}');
        await _reportingService!.reportPlaybackStart(
          track,
          playMethod: isOffline ? 'DirectPlay' : (activeUrl == downloadUrl ? 'DirectStream' : 'Transcode'),
        );
      } else {
        print('⚠️ Reporting service not initialized!');
      }
      
      _lastPlayingState = true;
    } on PlatformException {
      if (activeUrl != universalUrl && universalUrl != null) {
        if (await trySetSource(universalUrl)) {
          await _player.resume();
          activeUrl = universalUrl;
          
          // Report transcoded playback
          if (_reportingService != null) {
            await _reportingService!.reportPlaybackStart(
              track,
              playMethod: 'Transcode',
            );
          }
          _lastPlayingState = true;
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    
    // Cache upcoming tracks for smooth streaming (only when streaming, not offline)
    if (!isOffline) {
      _cacheUpcomingTracks();
    }
    
    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: Duration.zero,
      queue: _queue,
      currentQueueIndex: _currentIndex,
      isPlaying: true,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
    );
  }
  
  Future<void> playAlbum(
    List<JellyfinTrack> tracks, {
    String? albumId,
    String? albumName,
  }) async {
    if (tracks.isEmpty) return;
    final ordered = List<JellyfinTrack>.from(tracks)
      ..sort((a, b) {
        final discA = a.discNumber ?? 0;
        final discB = b.discNumber ?? 0;
        if (discA != discB) return discA.compareTo(discB);
        final trackA = a.indexNumber ?? 0;
        final trackB = b.indexNumber ?? 0;
        if (trackA != trackB) return trackA.compareTo(trackB);
        return a.name.compareTo(b.name);
      });
    final first = ordered.first;
    await playTrack(
      first,
      queueContext: ordered,
      albumId: albumId,
      albumName: albumName,
      reorderQueue: false,
    );
  }
  
  Future<void> pause() async {
    await _player.pause();
    final position = await _player.getCurrentPosition();
    if (position != null) {
      _lastPosition = position;
    }
    _emitIdleVisualizer();
    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: _lastPosition,
      isPlaying: false,
    );
  }
  
  Future<void> resume() async {
    await _player.resume();
    await _stateStore.savePlaybackSnapshot(isPlaying: true);
  }
  
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _lastPosition = position;
    await _stateStore.savePlaybackSnapshot(position: position);
  }
  
  Future<void> skipToNext() async {
    try {
      if (_currentIndex < _queue.length - 1) {
        _currentIndex++;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        );
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        _currentIndex = 0;
        await playTrack(
          _queue[0],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        );
      }
    } catch (e) {
      debugPrint('❌ Skip to next failed: $e');
      rethrow;
    }
  }

  Future<void> skipToPrevious() async {
    try {
      if (_currentIndex > 0) {
        _currentIndex--;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        );
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        _currentIndex = _queue.length - 1;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        );
      }
    } catch (e) {
      debugPrint('❌ Skip to previous failed: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    // Save the current track state BEFORE clearing, to preserve favorite status
    if (_currentTrack != null) {
      await _stateStore.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        position: _lastPosition,
        queue: _queue,
        currentQueueIndex: _currentIndex,
        isPlaying: false,
      );
      
      // Report stop to Jellyfin
      if (_reportingService != null) {
        await _reportingService!.reportPlaybackStopped(
          _currentTrack!,
          _lastPosition,
        );
      }
    }
    
    await _player.stop();
    _currentTrack = null;
    _currentTrackController.add(null);
    _queue.clear();
    _currentIndex = 0;
    _lastPosition = Duration.zero;
    _isShuffleEnabled = false;
    _shuffleController.add(_isShuffleEnabled);
    _emitIdleVisualizer();
    await _stateStore.clearPlaybackData();
  }

  // Alias methods for compatibility
  Future<void> playPause() async {
    final state = _player.state;
    if (state == PlayerState.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> playNext() => skipToNext();
  Future<void> playPrevious() => skipToPrevious();
  Future<void> next() => skipToNext();
  Future<void> previous() => skipToPrevious();
  
  // Queue management
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;
    
    final track = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, track);
    
    // Update current index if affected
    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    
    _queueController.add(_queue);
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queue,
      currentQueueIndex: _currentIndex,
      currentTrack: _currentTrack,
    ));
  }
  
  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (_queue.length == 1) return; // Don't remove last track
    
    _queue.removeAt(index);
    
    // Update current index if affected
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      // Removing current track - play next if available
      if (_currentIndex >= _queue.length) {
        _currentIndex = _queue.length - 1;
      }
      if (_queue.isNotEmpty) {
        unawaited(playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
        ));
      }
    }
    
    _queueController.add(_queue);
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queue,
      currentQueueIndex: _currentIndex,
      currentTrack: _currentTrack,
    ));
  }

  Future<void> jumpToQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    await playTrack(
      _queue[_currentIndex],
      queueContext: _queue,
      fromShuffle: _isShuffleEnabled,
    );
  }
  
  // Shuffle and Repeat functionality
  void toggleRepeatMode() {
    switch (_repeatMode) {
      case RepeatMode.off:
        _repeatMode = RepeatMode.all;
        break;
      case RepeatMode.all:
        _repeatMode = RepeatMode.one;
        break;
      case RepeatMode.one:
        _repeatMode = RepeatMode.off;
        break;
    }
    _repeatModeController.add(_repeatMode);
    debugPrint('🔁 Repeat mode: $_repeatMode');
    unawaited(_stateStore.savePlaybackSnapshot(repeatMode: _repeatMode.name));
  }
  
  void shuffleQueue() {
    if (_queue.isEmpty) return;
    
    // Keep current track at current position
    final currentTrack = _currentTrack;
    final remainingTracks = List<JellyfinTrack>.from(_queue);
    
    if (currentTrack != null) {
      remainingTracks.removeWhere((t) => t.id == currentTrack.id);
    }
    
    // Shuffle remaining tracks
    remainingTracks.shuffle(Random());
    
    // Rebuild queue: current + shuffled rest
    if (currentTrack != null) {
      _queue = [currentTrack, ...remainingTracks];
      _currentIndex = 0;
    } else {
      _queue = remainingTracks;
    }
    
    _isShuffleEnabled = true;
    _shuffleController.add(true);
    _queueController.add(_queue);
    debugPrint('🌊 Queue shuffled: ${_queue.length} tracks');
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queue,
      currentQueueIndex: _currentIndex,
      shuffleEnabled: _isShuffleEnabled,
    ));
  }
  
  Future<void> playShuffled(List<JellyfinTrack> tracks) async {
    if (tracks.isEmpty) return;
    
    final shuffled = List<JellyfinTrack>.from(tracks)..shuffle(Random());
    await playTrack(
      shuffled.first,
      queueContext: shuffled,
      fromShuffle: true,
    );
    debugPrint('🌊 Playing shuffled: ${shuffled.length} tracks');
  }
  
  void _emitVisualizerFrame(Duration position) {
    if (!_visualizerController.hasListener) return;
    final t = position.inMilliseconds / 120.0;
    final bars = List<double>.generate(_visualizerBarCount, (index) {
      final wave = (sin(t + index * 0.45) + 1) * 0.5;
      final ripple = (sin((t * 0.6) + index) + 1) * 0.25;
      final value = ((wave * 0.7) + (ripple * 0.3)) * _volume;
      return value.clamp(0.0, 1.0);
    });
    _visualizerController.add(bars);
  }

  void _emitIdleVisualizer() {
    if (!_visualizerController.hasListener) return;
    _visualizerController.add(List<double>.filled(_visualizerBarCount, 0));
  }

  void _startPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _saveCurrentPosition();
    });
  }
  
  void _stopPositionSaving() {
    _positionSaveTimer?.cancel();
  }
  
  Future<void> _saveCurrentPosition() async {
    if (_currentTrack == null) return;
    
    final position = await _player.getCurrentPosition();
    if (position != null) {
      _lastPosition = position;
      await _stateStore.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        position: position,
        queue: null,
        currentQueueIndex: _currentIndex,
        isPlaying: isPlaying,
      );
    }
  }
  
  
  // ========== CROSSFADE METHODS ==========
  
  /// Check if we should trigger crossfade based on current position
  void _checkCrossfadeTrigger(Duration position) async {
    if (!_crossfadeEnabled || _isCrossfading || _crossfadeDurationSeconds == 0) {
      return;
    }

    final duration = await _player.getDuration();
    if (duration == null || _currentTrack == null) return;

    // Calculate trigger point (crossfade duration before track ends)
    final triggerPoint = duration - Duration(seconds: _crossfadeDurationSeconds);
    
    // Don't trigger if we're not near the end
    if (position < triggerPoint) return;

    // Check if next track exists
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _queue.length && _repeatMode != RepeatMode.all) return;

    // Get next track
    final nextTrack = nextIndex < _queue.length ? _queue[nextIndex] : _queue[0];

    // SMART: Don't crossfade within same album (respect artist intent)
    final currentAlbumId = _currentTrack!.albumId;
    final nextAlbumId = nextTrack.albumId;
    
    if (currentAlbumId != null && 
        nextAlbumId != null && 
        currentAlbumId == nextAlbumId) {
      debugPrint('🎵 Same album - skipping crossfade');
      return;
    }

    // Trigger crossfade
    debugPrint('🌊 Starting crossfade: ${_currentTrack!.name} → ${nextTrack.name}');
    _startCrossfade(nextTrack, nextIndex);
  }

  /// Start crossfade to next track
  Future<void> _startCrossfade(JellyfinTrack nextTrack, int nextIndex) async {
    if (_isCrossfading) return;
    _isCrossfading = true;

    try {
      // Create crossfade player
      _crossfadePlayer = AudioPlayer();
      
      // Prepare next track
      final prepared = await _prepareTrackForCrossfade(nextTrack);
      if (!prepared) {
        throw Exception('Failed to prepare next track');
      }
      
      // Execute the crossfade
      await _executeCrossfade(nextTrack, nextIndex);
      
    } catch (e) {
      debugPrint('❌ Crossfade failed: $e');
      _cancelCrossfade();
    }
  }

  /// Prepare next track for crossfade
  Future<bool> _prepareTrackForCrossfade(JellyfinTrack track) async {
    if (_crossfadePlayer == null) return false;

    try {
      // Check for local file first
      final localPath = _downloadService?.getLocalPath(track.id);
      if (localPath != null) {
        final file = File(localPath);
        if (await file.exists()) {
          await _crossfadePlayer!.setSourceDeviceFile(localPath);
          debugPrint('✅ Crossfade: loaded local file');
          return true;
        }
      }
      
      // Fall back to streaming
      final downloadUrl = track.downloadUrl(_jellyfinService?.baseUrl, _jellyfinService?.token);
      await _crossfadePlayer!.setSourceUrl(downloadUrl);
      debugPrint('✅ Crossfade: loaded stream');
      return true;
    } catch (e) {
      debugPrint('❌ Crossfade prep failed: $e');
      return false;
    }
  }

  /// Execute the crossfade (volume fade)
  Future<void> _executeCrossfade(JellyfinTrack nextTrack, int nextIndex) async {
    if (_crossfadePlayer == null) return;

    final steps = 30; // Number of fade steps (smooth)
    final stepDuration = Duration(milliseconds: (_crossfadeDurationSeconds * 1000) ~/ steps);
    
    // Start next track at 0 volume
    await _crossfadePlayer!.setVolume(0.0);
    await _crossfadePlayer!.resume();
    
    // Fade volumes over time
    for (int i = 0; i <= steps; i++) {
      if (!_isCrossfading || _crossfadePlayer == null) break;
      
      final progress = i / steps;
      
      // Exponential curves for natural sound
      final fadeOut = 1.0 - (progress * progress); // Quadratic fade out
      final fadeIn = progress * progress; // Quadratic fade in
      
      await _player.setVolume(_volume * fadeOut);
      await _crossfadePlayer!.setVolume(_volume * fadeIn);
      
      if (i < steps) {
        await Future.delayed(stepDuration);
      }
    }
    
    // Complete the transition
    await _completeCrossfadeTransition(nextTrack, nextIndex);
  }

  /// Complete crossfade and switch to next track
  Future<void> _completeCrossfadeTransition(JellyfinTrack nextTrack, int nextIndex) async {
    // Stop current player
    await _player.stop();
    await _player.setVolume(_volume); // Reset volume
    
    // Update track info
    _currentIndex = nextIndex;
    _currentTrack = nextTrack;
    _currentAlbumId = nextTrack.albumId;
    _currentTrackController.add(_currentTrack);
    
    // Report to Jellyfin
    if (_reportingService != null) {
      await _reportingService!.reportPlaybackStart(nextTrack, playMethod: 'DirectPlay');
    }
    
    // Clean up
    _crossfadePlayer?.dispose();
    _crossfadePlayer = null;
    _isCrossfading = false;
    
    debugPrint('✅ Crossfade complete → ${nextTrack.name}');
  }

  // ========== STREAM CACHING METHODS ==========
  
  /// Cache upcoming tracks for smooth streaming (only when online)
  void _cacheUpcomingTracks() {
    if (_queue.isEmpty || _currentIndex >= _queue.length) return;
    
    // Determine how many tracks to cache (max 5)
    final tracksToCache = (_queue.length - _currentIndex - 1).clamp(0, _maxCachedTracks);
    
    if (tracksToCache == 0) return;
    
    debugPrint('🔄 Caching next $tracksToCache tracks for smooth streaming');
    
    // Cache in background
    for (int i = 1; i <= tracksToCache; i++) {
      final index = _currentIndex + i;
      if (index >= _queue.length) break;
      
      final track = _queue[index];
      
      // Skip if already downloaded locally
      final localPath = _downloadService?.getLocalPath(track.id);
      if (localPath != null) continue;
      
      // Skip if already cached
      if (_cachedStreamUrls.containsKey(track.id)) continue;
      
      // Cache the stream URL
      _cacheTrackUrl(track);
    }
  }
  
  /// Cache a single track's stream URL
  Future<void> _cacheTrackUrl(JellyfinTrack track) async {
    try {
      final url = track.directDownloadUrl();
      if (url != null) {
        _cachedStreamUrls[track.id] = url;
        debugPrint('✅ Cached stream URL for: ${track.name}');
      }
    } catch (e) {
      debugPrint('⚠️ Failed to cache track ${track.name}: $e');
    }
  }
  
  /// Start periodic cache cleanup (remove old cached URLs)
  void _startCacheCleanup() {
    _cacheCleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupCache();
    });
  }
  
  /// Clean up cached URLs that are no longer in the queue or are too far behind
  void _cleanupCache() {
    if (_cachedStreamUrls.isEmpty) return;
    
    final trackIds = _queue.map((t) => t.id).toSet();
    final toRemove = <String>[];
    
    for (final cachedId in _cachedStreamUrls.keys) {
      // Remove if not in current queue
      if (!trackIds.contains(cachedId)) {
        toRemove.add(cachedId);
        continue;
      }
      
      // Remove if too far behind current position (more than 10 tracks back)
      final index = _queue.indexWhere((t) => t.id == cachedId);
      if (index != -1 && index < _currentIndex - 10) {
        toRemove.add(cachedId);
      }
    }
    
    for (final id in toRemove) {
      _cachedStreamUrls.remove(id);
    }
    
    if (toRemove.isNotEmpty) {
      debugPrint('🧹 Cleaned up ${toRemove.length} cached stream URLs');
    }
  }

  void dispose() {
    _positionSaveTimer?.cancel();
    _crossfadeTimer?.cancel();
    _cacheCleanupTimer?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _audioHandler?.dispose();
    _player.dispose();
    _nextPlayer.dispose();
    _crossfadePlayer?.dispose();
    _cachedStreamUrls.clear();
    _currentTrackController.close();
    _playingController.close();
    _positionController.close();
    _durationController.close();
    _queueController.close();
    _repeatModeController.close();
    _volumeController.close();
    _shuffleController.close();
    _visualizerController.close();
  }
}
