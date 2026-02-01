import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, sin;
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import 'audio_cache_service.dart';
import 'audio_handler.dart';
import 'download_service.dart';
import 'haptic_service.dart';
import 'image_prewarm_service.dart';
import 'listening_analytics_service.dart';
import 'listenbrainz_service.dart';
import 'lyrics_service.dart';
import 'playback_reporting_service.dart';
import 'playback_state_store.dart';
import '../models/playback_state.dart';
import '../models/play_stats.dart';
import 'local_cache_service.dart';
import 'ios_fft_service.dart';
import 'pulseaudio_fft_service.dart';
import 'connectivity_service.dart';
import 'waveform_service.dart';
import '../models/loop_state.dart';

enum RepeatMode {
  off,      // No repeat
  all,      // Repeat queue
  one,      // Repeat current track
}

/// Combined player state snapshot for efficient UI updates.
/// Avoids nested StreamBuilders and reduces widget rebuilds.
class PlayerSnapshot {
  final JellyfinTrack? track;
  final bool isPlaying;
  final Duration position;
  final Duration duration;

  const PlayerSnapshot({
    this.track,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
}

/// Frequency bands extracted from visualizer for reactive effects.
/// Bass, mid, and treble are normalized 0.0-1.0 values.
class FrequencyBands {
  final double bass;
  final double mid;
  final double treble;

  const FrequencyBands({
    required this.bass,
    required this.mid,
    required this.treble,
  });

  static const zero = FrequencyBands(bass: 0, mid: 0, treble: 0);
}

class AudioPlayerService {
  static const int _visualizerBarCount = 24;

  // Pre-allocated array for visualizer to avoid per-frame allocations
  final List<double> _visualizerBars = List<double>.filled(_visualizerBarCount, 0.0);

  AudioPlayer _player = AudioPlayer();
  AudioPlayer _nextPlayer = AudioPlayer();
  final PlaybackStateStore _stateStore = PlaybackStateStore();
  DownloadService? _downloadService;
  PlaybackReportingService? _reportingService;
  NautuneAudioHandler? _audioHandler;
  JellyfinService? _jellyfinService;
  LocalCacheService? _cacheService;
  PlayStatsAggregate _playStats = PlayStatsAggregate();
  Duration _accumulatedTime = Duration.zero;
  double _volume = 1.0;
  double _lastVolume = 1.0;      // For detecting volume changes
  double _volumePulse = 0.0;     // Decays when volume changes (creates pulse effect)

  // Track-reactive visualizer parameters (from ReplayGain + genre)
  double _trackIntensity = 0.5;   // From ReplayGain (0.3-1.0)
  double _bassEmphasis = 0.5;     // From genre (0.2-0.8)
  double _animationSpeed = 1.0;   // From genre (0.5-2.0)

  PlayStatsAggregate get playStats => _playStats;
  
  // Player subscriptions
  StreamSubscription? _playerPosSub;
  StreamSubscription? _playerDurSub;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _playerCompleteSub;

  bool _isShuffleEnabled = false;
  bool _hasRestored = false;
  PlaybackState? _pendingState;

  // Track if current playback is from local file (download or cache)
  bool _isCurrentTrackLocal = false;

  // Pre-loading support for gapless playback
  JellyfinTrack? _preloadedTrack;
  bool _isPreloading = false;
  bool _gaplessPlaybackEnabled = true;
  bool _preloadedTrackIsLocal = false; // Track if preloaded track is from local storage

  // Audio cache service for pre-caching album tracks
  final AudioCacheService _audioCacheService = AudioCacheService.instance;

  // Image pre-warm service for pre-caching album art
  ImagePrewarmService? _imagePrewarmService;

  // Lyrics service for pre-fetching lyrics
  LyricsService? _lyricsService;
  bool _lyricsPrefetched = false;

  // ListenBrainz scrobbling tracking
  bool _hasScrobbled = false;
  DateTime? _trackStartTime;

  // Sleep timer support
  Timer? _sleepTimer;
  Duration _sleepTimeRemaining = Duration.zero;
  int _sleepTracksRemaining = 0;
  bool _isSleepTimerByTracks = false;
  final _sleepTimerController = BehaviorSubject<Duration>.seeded(Duration.zero);
  double _preSleepVolume = 1.0; // Store volume before fade

  // Crossfade support
  AudioPlayer? _crossfadePlayer;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  Timer? _crossfadeTimer;
  bool _isCrossfading = false;
  
  // Infinite Radio support
  bool _infiniteRadioEnabled = false;
  bool _isFetchingInfiniteRadio = false;
  static const int _infiniteRadioThreshold = 2; // Fetch when 2 or fewer tracks remain

  // Streaming quality
  StreamingQuality _streamingQuality = StreamingQuality.original;

  // Smart caching settings
  int _preCacheTrackCount = 3;  // 0 = off, 3, 5, or 10
  bool _wifiOnlyCaching = false;
  ConnectivityService? _connectivityService;

  JellyfinTrack? _currentTrack;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  Timer? _positionSaveTimer;
  bool _isTransitioning = false;
  Duration _lastPosition = Duration.zero;
  bool _lastPlayingState = false;
  RepeatMode _repeatMode = RepeatMode.off;

  // A-B Loop state
  LoopState _loopState = LoopState.empty;
  final _loopStateController = BehaviorSubject<LoopState>.seeded(LoopState.empty);

  final StreamController<double> _volumeController = StreamController<double>.broadcast();
  final StreamController<bool> _shuffleController = StreamController<bool>.broadcast();
  final StreamController<List<double>> _visualizerController = StreamController<List<double>>.broadcast();
  final _frequencyBandsController = BehaviorSubject<FrequencyBands>.seeded(FrequencyBands.zero);
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  void setDownloadService(DownloadService service) {
    _downloadService = service;
  }

  void setReportingService(PlaybackReportingService service) {
    _reportingService = service;
    _reportingService?.attachPositionProvider(() => _lastPosition);
  }

  /// Gets the offline artwork URI for a track if available.
  /// Returns a file:// URI for local artwork, or null if not available.
  Future<Uri?> _getOfflineArtworkUri(String trackId) async {
    final artworkPath = await _downloadService?.getArtworkPathForTrack(trackId);
    if (artworkPath != null && File(artworkPath).existsSync()) {
      return Uri.file(artworkPath);
    }
    return null;
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

  void setInfiniteRadioEnabled(bool enabled) {
    _infiniteRadioEnabled = enabled;
    debugPrint('🔄 Infinite Radio: ${enabled ? "enabled" : "disabled"}');
  }

  void setGaplessPlaybackEnabled(bool enabled) {
    _gaplessPlaybackEnabled = enabled;
    if (!enabled) {
      _clearPreload();
    }
    debugPrint('🔄 Gapless Playback: ${enabled ? "enabled" : "disabled"}');
  }

  void setStreamingQuality(StreamingQuality quality) {
    _streamingQuality = quality;
    debugPrint('🎵 Streaming quality: ${quality.label}');
  }

  StreamingQuality get streamingQuality => _streamingQuality;

  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
  }

  void setPreCacheTrackCount(int count) {
    _preCacheTrackCount = count;
    debugPrint('📦 Pre-cache track count: $count');
  }

  void setWifiOnlyCaching(bool value) {
    _wifiOnlyCaching = value;
    debugPrint('📦 WiFi-only caching: $value');
  }

  int get preCacheTrackCount => _preCacheTrackCount;
  bool get wifiOnlyCaching => _wifiOnlyCaching;

  /// Gets the appropriate stream URL based on quality setting.
  /// Returns (url, isDirectStream) tuple.
  /// If quality is "original", returns direct download URL (lossless).
  /// Otherwise returns universal stream URL with appropriate bitrate.
  (String? url, bool isDirectStream) _getStreamUrl(JellyfinTrack track, {String? sessionId}) {
    final quality = _streamingQuality;

    // For original/lossless quality, use direct download URL
    if (quality == StreamingQuality.original) {
      final url = track.directDownloadUrl();
      debugPrint('🎵 Stream URL (Direct): $url');
      return (url, true);
    }

    // For auto mode, check network type and switch quality accordingly
    if (quality == StreamingQuality.auto) {
      return _getAutoQualityStreamUrl(track, sessionId: sessionId);
    }

    // For transcoded quality, use the stream endpoint that forces transcoding
    final bitrate = quality.maxBitrate ?? 320000;
    final url = track.transcodedStreamUrl(
      deviceId: _deviceId,
      audioBitrate: bitrate,
      audioCodec: 'mp3',
      container: 'mp3',
      playSessionId: sessionId,
    );
    debugPrint('🎵 Stream URL (Transcode ${bitrate ~/ 1000}kbps): $url');
    return (url, false);
  }

  // Cached network type for auto quality mode
  _NetworkType _cachedNetworkType = _NetworkType.wifi;
  DateTime? _lastNetworkCheck;

  /// Get stream URL based on auto quality mode with network-aware switching
  /// - WiFi/Ethernet → Original (lossless)
  /// - Cellular → Normal (192kbps)
  /// - Unknown/Slow → Low (128kbps)
  (String? url, bool isDirectStream) _getAutoQualityStreamUrl(
    JellyfinTrack track, {
    String? sessionId,
  }) {
    // Refresh network type in background if stale (older than 30 seconds)
    _refreshNetworkTypeIfNeeded();

    // Use cached network type for quality decision
    switch (_cachedNetworkType) {
      case _NetworkType.wifi:
        // WiFi/Ethernet: Use original lossless quality
        final url = track.directDownloadUrl();
        debugPrint('🎵 Stream URL (Auto/WiFi - Original): $url');
        return (url, true);

      case _NetworkType.cellular:
        // Cellular: Use normal quality (192kbps)
        final url = track.transcodedStreamUrl(
          deviceId: _deviceId,
          audioBitrate: 192000,
          audioCodec: 'mp3',
          container: 'mp3',
          playSessionId: sessionId,
        );
        debugPrint('🎵 Stream URL (Auto/Cellular - 192kbps): $url');
        return (url, false);

      case _NetworkType.slow:
        // Slow connection: Use low quality (128kbps)
        final url = track.transcodedStreamUrl(
          deviceId: _deviceId,
          audioBitrate: 128000,
          audioCodec: 'mp3',
          container: 'mp3',
          playSessionId: sessionId,
        );
        debugPrint('🎵 Stream URL (Auto/Slow - 128kbps): $url');
        return (url, false);
    }
  }

  /// Refresh cached network type if stale
  void _refreshNetworkTypeIfNeeded() {
    final now = DateTime.now();
    final lastCheck = _lastNetworkCheck;

    // Check every 30 seconds
    if (lastCheck != null && now.difference(lastCheck).inSeconds < 30) {
      return;
    }

    _lastNetworkCheck = now;

    // Start async network check
    final connectivity = _connectivityService;
    if (connectivity == null) return;

    unawaited(_updateNetworkType(connectivity));
  }

  /// Update cached network type from connectivity service
  Future<void> _updateNetworkType(ConnectivityService connectivity) async {
    try {
      final isWifi = await connectivity.isOnWifi();
      if (isWifi) {
        if (_cachedNetworkType != _NetworkType.wifi) {
          _cachedNetworkType = _NetworkType.wifi;
          debugPrint('📶 Network type updated: WiFi (original quality)');
        }
        return;
      }

      final isMobile = await connectivity.isOnMobileData();
      if (isMobile) {
        if (_cachedNetworkType != _NetworkType.cellular) {
          _cachedNetworkType = _NetworkType.cellular;
          debugPrint('📶 Network type updated: Cellular (192kbps)');
        }
        return;
      }

      // Unknown/VPN - assume slow
      if (_cachedNetworkType != _NetworkType.slow) {
        _cachedNetworkType = _NetworkType.slow;
        debugPrint('📶 Network type updated: Unknown/Slow (128kbps)');
      }
    } catch (e) {
      debugPrint('📶 Network check failed: $e');
    }
  }

  void _cancelCrossfade() {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    _isCrossfading = false;
    // Don't dispose - reuse the player instance
    _crossfadePlayer?.stop();
  }

  void setLocalCacheService(LocalCacheService service) {
    _cacheService = service;
    _loadPlayStats();
  }

  Future<void> _loadPlayStats() async {
    if (_cacheService == null || _jellyfinService?.session == null) return;
    try {
      final sessionKey = _cacheService!.cacheKeyForSession(_jellyfinService!.session!);
      final statsMap = await _cacheService!.readPlayStats(sessionKey);
      if (statsMap != null) {
        _playStats = PlayStatsAggregate.fromJson(statsMap);
      }
    } catch (e) {
      debugPrint('Error loading play stats: $e');
    }
  }

  Future<void> _savePlayStats() async {
    if (_cacheService == null || _jellyfinService?.session == null) return;
    try {
      final sessionKey = _cacheService!.cacheKeyForSession(_jellyfinService!.session!);
      await _cacheService!.savePlayStats(sessionKey, _playStats.toJson());
    } catch (e) {
      debugPrint('Error saving play stats: $e');
    }
  }

  void setJellyfinService(JellyfinService service) {
    _jellyfinService = service;
    _imagePrewarmService = ImagePrewarmService(jellyfinService: service);
    _lyricsService = LyricsService(jellyfinService: service);
    _loadPlayStats();
    if (_pendingState != null && !_hasRestored) {
      unawaited(applyStoredState(_pendingState!));
    }
  }
  
  // Streams
  final StreamController<JellyfinTrack?> _currentTrackController = BehaviorSubject<JellyfinTrack?>();
  final StreamController<bool> _playingController = BehaviorSubject<bool>.seeded(false);
  
  // Use BehaviorSubject to ensure new listeners get the latest value immediately
  final BehaviorSubject<Duration> _positionController = BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration> _bufferedPositionController = BehaviorSubject<Duration>.seeded(Duration.zero);
  final BehaviorSubject<Duration?> _durationController = BehaviorSubject<Duration?>.seeded(null);

  // Cached duration to avoid repeated async getDuration() calls in position update handlers
  Duration? _cachedDuration;

  final StreamController<List<JellyfinTrack>> _queueController = BehaviorSubject<List<JellyfinTrack>>.seeded([]);
  final StreamController<RepeatMode> _repeatModeController = BehaviorSubject<RepeatMode>.seeded(RepeatMode.off);
  
  Stream<JellyfinTrack?> get currentTrackStream => _currentTrackController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<List<JellyfinTrack>> get queueStream => _queueController.stream;
  Stream<RepeatMode> get repeatModeStream => _repeatModeController.stream;
  Stream<double> get volumeStream => _volumeController.stream;
  Stream<bool> get shuffleStream => _shuffleController.stream;
  Stream<List<double>> get visualizerStream => _visualizerController.stream;
  Stream<Duration> get sleepTimerStream => _sleepTimerController.stream;
  Stream<FrequencyBands> get frequencyBandsStream => _frequencyBandsController.stream;
  Stream<LoopState> get loopStateStream => _loopStateController.stream;

  /// A stream that combines position, buffered position, and duration into a single snapshot.
  /// This is the "Silver Bullet" for smooth progress bars.
  Stream<PositionData> get positionDataStream =>
      Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
          _positionController.stream,
          _bufferedPositionController.stream,
          _durationController.stream,
          (position, bufferedPosition, duration) => PositionData(
              position, bufferedPosition, duration ?? Duration.zero));

  /// Combined player snapshot stream for full player screen.
  /// Flattens 4 nested StreamBuilders into one, reducing rebuild overhead by ~75%.
  Stream<PlayerSnapshot> get playerSnapshotStream =>
      Rx.combineLatest4<JellyfinTrack?, bool, Duration, Duration?, PlayerSnapshot>(
          _currentTrackController.stream,
          _playingController.stream,
          _positionController.stream,
          _durationController.stream,
          (track, isPlaying, position, duration) => PlayerSnapshot(
              track: track,
              isPlaying: isPlaying,
              position: position,
              duration: duration ?? track?.duration ?? Duration.zero,
          ),
      );

  JellyfinTrack? get currentTrack => _currentTrack;
  bool get isPlaying => _player.state == PlayerState.playing;
  Duration get currentPosition => _lastPosition;
  AudioPlayer get player => _player;
  List<JellyfinTrack> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  RepeatMode get repeatMode => _repeatMode;
  double get volume => _volume;
  bool get shuffleEnabled => _isShuffleEnabled;
  bool get isSleepTimerActive => _sleepTimer != null || _sleepTracksRemaining > 0;
  Duration get sleepTimeRemaining => _sleepTimeRemaining;
  int get sleepTracksRemaining => _sleepTracksRemaining;
  LoopState get loopState => _loopState;

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
    final clamped = value.clamp(0.0, 1.0);
    _volume = clamped.toDouble();
    _volumeController.add(_volume);

    // Apply ReplayGain normalization if available
    final currentMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
    final adjustedVolume = (_volume * currentMultiplier).clamp(0.0, 1.0);

    await Future.wait([
      _player.setVolume(adjustedVolume),
      _nextPlayer.setVolume(_volume),
    ]);
    unawaited(_stateStore.savePlaybackSnapshot(volume: _volume));
  }
  
  AudioPlayerService() {
    _initAudioSession();
    _attachPlayerListeners(_player);
    _initAudioHandler();
    _player.setVolume(_volume);
    _nextPlayer.setVolume(_volume);
    _volumeController.add(_volume);
    _emitIdleVisualizer();

    // Initialize reusable crossfade player
    _crossfadePlayer = AudioPlayer();
  }

  String get _deviceId {
    // Prefer persistent device ID from session if available
    final sessionDeviceId = _jellyfinService?.session?.deviceId;
    if (sessionDeviceId != null) return sessionDeviceId;
    
    // Fallback to platform-based ID (legacy/offline without session)
    return 'nautune-${Platform.operatingSystem}';
  }

  Future<void> _initAudioHandler() async {
    // Initialize AudioService for all platforms (Mobile + Desktop)
    // On Linux, this provides MPRIS support via DBus.
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
          // Desktop specific configs (if any) are handled automatically by the platform implementation
        ),
      );
      debugPrint('✅ Audio service initialized for media controls');
    } catch (e) {
      debugPrint('⚠️ Audio service initialization failed: $e');
    }
  }
  
  Future<void> _initAudioSession() async {
    // Initialize FFT services for real audio visualization
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.initialize());
    }
    if (Platform.isLinux) {
      unawaited(PulseAudioFFTService.instance.initialize());
    }

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
      debugPrint('Audio session setup failed: $e');
    }
  }
  
  void _detachListeners() {
    _playerPosSub?.cancel();
    _playerDurSub?.cancel();
    _playerStateSub?.cancel();
    _playerCompleteSub?.cancel();
  }

  void _attachPlayerListeners(AudioPlayer player) {
    _detachListeners();
    
    // Position updates
    _playerPosSub = player.onPositionChanged.listen((position) {
      _positionController.add(position);
      _lastPosition = position;
      if (player.state == PlayerState.playing) {
        _emitVisualizerFrame(position);
      }
      // Check A-B loop boundary
      _checkLoopBoundary(position);
      // Check if we should start crossfade
      _checkCrossfadeTrigger(position);
      // Check if we should pre-load next track
      _checkPreloadTrigger(position);
      // Pre-fetch lyrics for next track at ~50% playback
      _checkLyricsPrefetch(position);
      // Check ListenBrainz scrobble threshold
      _checkListenBrainzScrobble(position);
      // Sync iOS FFT shadow player position (every second, with ms precision)
      if (Platform.isIOS && position.inMilliseconds % 1000 < 50) {
        IOSFFTService.instance.syncPosition(position.inMilliseconds / 1000.0);
      }
    });

    // Duration updates
    _playerDurSub = player.onDurationChanged.listen((duration) {
      // For streams, player might report 0 or very small duration.
      // If we have track metadata, prefer that unless player reports something reasonable.
      if (duration.inSeconds > 0) {
        _cachedDuration = duration;
        _durationController.add(duration);
      } else if (_currentTrack != null) {
        // Fallback to metadata duration
        _cachedDuration = _currentTrack!.duration;
        _durationController.add(_currentTrack!.duration);
      } else {
        _cachedDuration = duration;
        _durationController.add(duration);
      }
    });
    
    // State changes
    _playerStateSub = player.onPlayerStateChanged.listen((state) {
      final isPlaying = state == PlayerState.playing;
      _playingController.add(isPlaying);
      
      // Report state change to Jellyfin
      if (_lastPlayingState != isPlaying && _currentTrack != null) {
        _lastPlayingState = isPlaying;
        if (_reportingService != null) {
          _reportingService?.reportPlaybackProgress(
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
    _playerCompleteSub = player.onPlayerComplete.listen((_) async {
      if (!_isTransitioning) {
        await _gaplessTransition();
      }
    });
  }
  
  Future<void> _gaplessTransition() async {
    // Record actual listening time for the completed track
    _recordActualListeningTime();

    // Check track-based sleep timer FIRST
    if (_isSleepTimerByTracks && _sleepTracksRemaining > 0) {
      _sleepTracksRemaining--;
      debugPrint('😴 Sleep timer: $_sleepTracksRemaining tracks remaining');
      _sleepTimerController.add(Duration(seconds: -_sleepTracksRemaining));

      if (_sleepTracksRemaining <= 0) {
        debugPrint('😴 Sleep timer complete - stopping playback');
        _fadeOutAndStop();
        return; // Don't transition to next track
      }
    }

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

    // Check if we need to fetch more tracks for infinite radio
    // OPTIMIZATION: Check if we already have a next track. If so, don't block!
    final hasNextTrack = _currentIndex + 1 < _queue.length;
    
    if (hasNextTrack) {
      // We have a next track, so fetch more in background without waiting
      if (_infiniteRadioEnabled) {
         unawaited(_checkInfiniteRadio());
      }
    } else {
      // No next track, we MUST wait for infinite radio if enabled
      if (_infiniteRadioEnabled) {
        await _checkInfiniteRadio();
      }
    }

    // Move to next track
    if (_currentIndex + 1 < _queue.length) {
      _isTransitioning = true;

      try {
        final nextTrack = _queue[_currentIndex + 1];

        // Check if we have this track pre-loaded AND gapless is enabled
        if (_gaplessPlaybackEnabled && _preloadedTrack?.id == nextTrack.id) {
          debugPrint('⚡ Using pre-loaded track for instant playback: ${nextTrack.name}');

          // SWAP PLAYERS for seamless transition
          // 1. Detach listeners from current player (which is ending)
          _detachListeners();

          // 2. Play the pre-loaded track (already loaded in _nextPlayer)
          await _nextPlayer.setVolume(_volume);
          await _nextPlayer.resume();

          // 3. IMPORTANT: Update AudioHandler to listen to the NEW player (which is playing)
          // BEFORE stopping the old one. This prevents the OS from seeing a "Stop" state.
          _audioHandler?.updatePlayer(_nextPlayer);
          final offlineArtUri = await _getOfflineArtworkUri(nextTrack.id);
          _audioHandler?.updateNautuneMediaItem(nextTrack, offlineArtUri: offlineArtUri);

          // 3.5 Brief yield to ensure OS media controls are fully updated
          // This prevents audio glitch from racing between handler update and player stop
          await Future.delayed(const Duration(milliseconds: 50));

          // 4. Stop the old player (AudioHandler is no longer listening to this one)
          await _player.stop();

          // 5. Swap the references
          final oldPlayer = _player;
          _player = _nextPlayer;
          _nextPlayer = oldPlayer; // Reuse old player for next pre-load

          // 6. Re-attach listeners to the NEW main player
          _attachPlayerListeners(_player);

          _currentIndex++;
          _currentTrack = nextTrack;
          _currentTrackController.add(_currentTrack);
          _isCurrentTrackLocal = _preloadedTrackIsLocal; // Update for A-B loop support
          _analyzeTrackForVisualizer(nextTrack); // Configure visualizer for track

          // 7. Explicitly emit playing state since the listener may not fire
          //    if player was already playing when attached
          _playingController.add(true);
          _lastPlayingState = true;
          
          // Immediately update duration from metadata
          if (nextTrack.duration != null) {
            _durationController.add(nextTrack.duration);
          }

          // Pre-warm album art for upcoming tracks
          _imagePrewarmService?.prewarmQueueImages(_queue, _currentIndex);

          // Smart pre-cache more upcoming tracks
          unawaited(_smartPreCacheUpcoming(_queue, _currentIndex));

          // Clear pre-load state
          _preloadedTrack = null;
        } else {
          // No pre-loaded track or gapless disabled, do regular playback
          _currentIndex++;
          await playTrack(
            _queue[_currentIndex],
            queueContext: _queue,
            fromShuffle: _isShuffleEnabled,
          );
        }
      } catch (e) {
        debugPrint('❌ Gapless transition failed: $e');
        // Recovery: try to play next track without gapless optimization
        if (_currentIndex + 1 < _queue.length) {
          _currentIndex++;
          try {
            await playTrack(
              _queue[_currentIndex],
              queueContext: _queue,
              fromShuffle: _isShuffleEnabled,
            );
          } catch (retryError) {
            debugPrint('❌ Recovery also failed: $retryError');
            await stop();
          }
        } else {
          await stop();
        }
      } finally {
        _isTransitioning = false;
        _saveCurrentPosition();
      }
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
      } else if (_infiniteRadioEnabled) {
        // Try to fetch more tracks for infinite radio before stopping
        debugPrint('📻 Queue ended, trying infinite radio...');
        await _fetchInfiniteRadioTracks();
        
        // Check if we got new tracks
        if (_currentIndex + 1 < _queue.length) {
          _currentIndex++;
          await playTrack(
            _queue[_currentIndex],
            queueContext: _queue,
            fromShuffle: _isShuffleEnabled,
          );
        } else {
          // No more tracks available
          debugPrint('📻 Infinite Radio: No more tracks available, stopping');
          await stop();
        }
      } else {
        // Stop playback
        await stop();
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
    if (state == null) {
      debugPrint('📭 No playback state to restore');
      return;
    }
    
    debugPrint('📥 Restoring playback state: ${state.currentTrackName ?? "Unknown"} (Queue: ${state.queueIds.length})');
    
    try {
      final queue = await _buildQueueFromState(state).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('⚠️ Playback restoration timed out - skipping');
          return [];
        },
      );

      if (state.queueIds.isNotEmpty && queue.isEmpty) {
      // Wait until we can resolve queue items (likely requires Jellyfin session).
      _pendingState = state;
      return;
    }

    await _applyStateFromStorage(state, queue);
    _pendingState = null;
    _hasRestored = true;
    } catch (e, stack) {
      debugPrint('⚠️ Failed to restore playback state: $e\n$stack');
      // Don't rethrow - we want app to continue even if restore fails
    }
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
    _cachedDuration = track.duration; // Initialize cached duration from track metadata
    _lyricsPrefetched = false; // Reset lyrics prefetch flag for new track
    clearLoop(); // Clear A-B loop markers on track change
    _analyzeTrackForVisualizer(track); // Configure visualizer for track

    // Track play count
    _playStats.incrementPlayCount(track.id);
    unawaited(_savePlayStats());

    // Record actual listening time for the PREVIOUS track (if any) before starting new one
    _recordActualListeningTime();

    // Reset ListenBrainz scrobble state and submit "now playing"
    _hasScrobbled = false;
    _trackStartTime = DateTime.now();
    unawaited(ListenBrainzService().submitNowPlaying(track));

    // Immediately update duration from metadata to prevent UI lag
    if (track.duration != null) {
      _durationController.add(track.duration);
    }
    
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
        _queue = List<JellyfinTrack>.from([track]);
        _currentIndex = 0;
      }
    } else {
      _queue = List<JellyfinTrack>.from([track]);
      _currentIndex = 0;
    }

    _queueController.add(_queue);

    // Clear any pre-loaded track since queue changed
    _clearPreload();

    // Pre-warm album art for upcoming tracks in queue
    _imagePrewarmService?.prewarmQueueImages(_queue, _currentIndex);

    // Update audio handler with current track metadata immediately
    // This is critical for Lock Screen to update BEFORE audio starts
    final offlineArtUri = await _getOfflineArtworkUri(track.id);
    _audioHandler?.updateNautuneMediaItem(track, offlineArtUri: offlineArtUri);
    _audioHandler?.updateNautuneQueue(_queue);
    
    // Generate a session ID to link the stream and the reporting
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    // RESOLVE SOURCE BEFORE STOPPING PLAYER
    // This minimizes "dead air" time which causes iOS background suspension
    final (streamUrl, isDirectStream) = _getStreamUrl(track, sessionId: sessionId);

    // Don't stop yet! Resolve the source first.

    String? activeUrl;
    bool isOffline = false;
    bool isLocalFile = false;

    // Check for downloaded file first (works in airplane mode!)
    final localPath = _downloadService?.getLocalPath(track.id);
    if (localPath != null) {
      // Verify file exists before trying to play
      final file = File(localPath);
      if (await file.exists()) {
          activeUrl = localPath;
          isOffline = true;
          isLocalFile = true;
          debugPrint('✅ Found local file: $localPath');
        } else {
          debugPrint('⚠️ Local file not found (may be orphaned): $localPath');
          // Clean up orphaned reference
          await _downloadService?.verifyAndCleanupDownloads();
        }
    }

    // Check for cached file (pre-cached during album playback)
    if (activeUrl == null) {
      final cachedFile = await _audioCacheService.getCachedFile(track.id);
      if (cachedFile != null && await cachedFile.exists()) {
        activeUrl = cachedFile.path;
        isLocalFile = true;
        debugPrint('✅ Found in cache: ${cachedFile.path}');
      }
    }

    // Try streaming if no local/cached file
    if (activeUrl == null) {
      // Use the stream URL based on quality preference
      if (streamUrl != null) {
        activeUrl = streamUrl;
        if (isDirectStream) {
          debugPrint('🎵 Streaming: Original quality (direct)');
        } else {
          debugPrint('🎵 Streaming: ${_streamingQuality.label}');
        }
      } else if (track.assetPathOverride != null) {
        activeUrl = track.assetPathOverride;
      }
    }

    if (activeUrl == null) {
      throw PlatformException(
        code: 'no_source',
        message: 'Unable to play ${track.name}. File may be unavailable.',
      );
    }

    // Store whether this track is playing from local storage (for A-B loop support)
    _isCurrentTrackLocal = isLocalFile;

    // Cache the currently playing track in background if streaming (not already local/cached)
    // This enables A-B loop and offline replay after the track finishes caching
    if (!isLocalFile && _preCacheTrackCount > 0 && streamUrl != null) {
      unawaited(_audioCacheService.cacheTrack(track, streamUrl: streamUrl).then((cachedFile) {
        // Update local flag if caching succeeded and this track is still playing
        if (cachedFile != null && _currentTrack?.id == track.id) {
          _isCurrentTrackLocal = true;
        }
      }));
    }

    // NOW we touch the player.
    // We don't explicitly call stop() because setSource will handle it, 
    // and we want to minimize the gap.

    Future<void> applySourceAndPlay() async {
        final url = activeUrl!;
        if (isLocalFile) {
           await _player.setSource(DeviceFileSource(url));
        } else if (url.startsWith('assets/')) {
           final normalized = url.substring('assets/'.length);
           await _player.setSource(AssetSource(normalized));
        } else {
           await _player.setSource(UrlSource(url));
        }

        // Apply ReplayGain normalization
        final adjustedVolume = _volume * track.replayGainMultiplier;
        await _player.setVolume(adjustedVolume.clamp(0.0, 1.0));
        if (track.normalizationGain != null) {
           debugPrint('🔊 Applied ReplayGain: ${track.normalizationGain} dB');
        }
        
        await _player.resume();
    }

    try {
      // Seed duration immediately from metadata (important for streams)
      _durationController.add(track.duration);

      await applySourceAndPlay();

      // Report playback start to Jellyfin
      if (_reportingService != null) {
        debugPrint('🎵 Reporting playback start to Jellyfin: ${track.name}');
        await _reportingService?.reportPlaybackStart(
          track,
          playMethod: isOffline ? 'DirectPlay' : (isDirectStream ? 'DirectStream' : 'Transcode'),
          sessionId: sessionId,
        );
      }

      _lastPlayingState = true;

      // iOS FFT: Use local file immediately, or cache streaming track first
      if (Platform.isIOS) {
        if (isLocalFile) {
          // Local file - start FFT immediately
          await IOSFFTService.instance.setAudioUrl('file://$activeUrl');
          await IOSFFTService.instance.startCapture();
        } else {
          // Streaming - cache in background (same quality as playback), then start FFT
          _cacheTrackForIOSFFT(track, activeUrl);
        }
      }

      // Linux FFT: PulseAudio captures system audio directly (no file path needed)
      if (Platform.isLinux) {
        PulseAudioFFTService.instance.startCapture();
      }

      // Waveform extraction: Cache streaming tracks for waveform visualization
      if (!isLocalFile && WaveformService.instance.isAvailable) {
        _cacheTrackForWaveform(track, activeUrl);
      }
    } on PlatformException {
      // Fallback logic for streaming failure - try transcoded stream if direct failed
      if (!isLocalFile && isDirectStream) {
        final fallbackUrl = track.universalStreamUrl(
          deviceId: _deviceId,
          maxBitrate: 320000,
          audioCodec: 'mp3',
          container: 'mp3',
        );
        if (fallbackUrl != null) {
          debugPrint('⚠️ Direct stream failed, trying transcoded stream...');
          activeUrl = fallbackUrl;
          await applySourceAndPlay();

          // Report transcoded playback
          if (_reportingService != null) {
            await _reportingService?.reportPlaybackStart(
              track,
              playMethod: 'Transcode',
              sessionId: sessionId,
            );
          }
          _lastPlayingState = true;
          // No iOS FFT for streaming - would double bandwidth
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
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
    
    // Smart pre-cache upcoming tracks based on user settings
    unawaited(_smartPreCacheUpcoming(ordered, 0));
  }

  /// Trigger smart pre-caching for upcoming tracks in queue.
  /// Uses user's configured pre-cache count and WiFi-only settings.
  Future<void> _smartPreCacheUpcoming(List<JellyfinTrack> queue, int currentIndex) async {
    await _audioCacheService.smartPreCacheQueue(
      queue: queue,
      currentIndex: currentIndex,
      preCacheCount: _preCacheTrackCount,
      wifiOnly: _wifiOnlyCaching,
      connectivityService: _connectivityService,
    );
  }
  
  Future<void> pause() async {
    HapticService.lightTap();
    await _fadeOutAndPause();
    final position = await _player.getCurrentPosition();
    if (position != null) {
      _lastPosition = position;
    }
    _emitIdleVisualizer();
    // Save full playback state including queue so user can resume at exact position
    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: _lastPosition,
      queue: _queue,
      currentQueueIndex: _currentIndex,
      isPlaying: false,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
      volume: _volume,
    );
  }
  
  Future<void> resume() async {
    HapticService.lightTap();
    await _resumeAndFadeIn();
    await _stateStore.savePlaybackSnapshot(isPlaying: true);
  }
  
  // Fade helpers
  Future<void> _fadeOutAndPause() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    
    // Quick fade out (gentler: 400ms total, 20Hz update rate)
    const steps = 8;
    const stepDuration = Duration(milliseconds: 50); 
    final startVolume = _volume;
    
    for (int i = 0; i < steps; i++) {
      final vol = startVolume * (1.0 - ((i + 1) / steps));
      await _player.setVolume(vol);
      await Future.delayed(stepDuration);
    }
    
    await _player.pause();
    await _player.setVolume(startVolume); // Restore for next play
  }

  Future<void> _resumeAndFadeIn() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;

    // Start silent
    await _player.setVolume(0.0);
    await _player.resume();

    // Quick fade in (gentler: 400ms total, 20Hz update rate)
    const steps = 8;
    const stepDuration = Duration(milliseconds: 50);
    final targetVolume = _volume;

    for (int i = 0; i <= steps; i++) {
      final vol = targetVolume * (i / steps);
      await _player.setVolume(vol);
      await Future.delayed(stepDuration);
    }
  }
  
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _lastPosition = position;
    await _stateStore.savePlaybackSnapshot(position: position);
  }
  
  Future<void> skipToNext() async {
    HapticService.mediumTap();
    // Record actual listening time before skipping
    _recordActualListeningTime();
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
    HapticService.mediumTap();
    // Record actual listening time before skipping
    _recordActualListeningTime();
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

  /// Cache streaming track for iOS FFT visualization.
  /// Once cached, starts FFT from local file and syncs to current position.
  /// Uses the same [streamUrl] as playback to match transcoding quality.
  void _cacheTrackForIOSFFT(JellyfinTrack track, String streamUrl) {
    if (!Platform.isIOS) return;

    final trackId = track.id;
    debugPrint('🎵 iOS FFT: Caching track for visualization: ${track.name}');

    // Cache in background using same stream URL as playback
    _audioCacheService.cacheTrack(track, streamUrl: streamUrl).then((cachedFile) async {
      if (cachedFile == null) {
        debugPrint('⚠️ iOS FFT: Cache failed for ${track.name}');
        return;
      }

      // Make sure we're still playing the same track
      if (_currentTrack?.id != trackId) {
        debugPrint('🎵 iOS FFT: Track changed, skipping FFT start');
        return;
      }

      // Start FFT from cached file
      final filePath = 'file://${cachedFile.path}';
      debugPrint('🎵 iOS FFT: Starting from cache: ${track.name}');

      await IOSFFTService.instance.setAudioUrl(filePath);

      // Sync to current playback position BEFORE starting capture
      // Use milliseconds for precision
      final currentPosMs = _lastPosition.inMilliseconds.toDouble() / 1000.0;
      await IOSFFTService.instance.syncPosition(currentPosMs);

      await IOSFFTService.instance.startCapture();

      // Sync again after a short delay to ensure accuracy
      await Future.delayed(const Duration(milliseconds: 100));
      if (_currentTrack?.id == trackId) {
        final updatedPos = _lastPosition.inMilliseconds.toDouble() / 1000.0;
        await IOSFFTService.instance.syncPosition(updatedPos);
      }

      debugPrint('🎵 iOS FFT: Started and synced to ${currentPosMs}s');
    }).catchError((e) {
      debugPrint('⚠️ iOS FFT: Error caching for FFT: $e');
    });
  }

  /// Cache streaming track for waveform extraction
  void _cacheTrackForWaveform(JellyfinTrack track, String streamUrl) {
    final trackId = track.id;

    // Skip if waveform already exists
    WaveformService.instance.hasWaveform(trackId).then((hasWaveform) async {
      if (hasWaveform) {
        debugPrint('🌊 Waveform: Already exists for ${track.name}');
        return;
      }

      debugPrint('🌊 Waveform: Caching track for extraction: ${track.name}');

      // Cache the track (this will trigger waveform extraction via audio_cache_service)
      final cachedFile = await _audioCacheService.cacheTrack(track, streamUrl: streamUrl);
      if (cachedFile == null) {
        debugPrint('⚠️ Waveform: Cache failed for ${track.name}');
        return;
      }

      debugPrint('🌊 Waveform: Cached, extraction triggered for ${track.name}');
    }).catchError((e) {
      debugPrint('⚠️ Waveform: Error caching for extraction: $e');
    });
  }

  Future<void> stop() async {
    // Record actual listening time before stopping
    _recordActualListeningTime();

    // 1. Stop audio immediately
    await _player.stop();

    // Stop FFT capture
    if (Platform.isIOS) {
      await IOSFFTService.instance.stopCapture();
    }
    if (Platform.isLinux) {
      PulseAudioFFTService.instance.stopCapture();
    }

    // 2. CLEAR persistence so app starts fresh on next launch
    try {
      debugPrint('🧹 Clearing playback state on stop');
      await _stateStore.clearPlaybackData();
    } catch (e) {
      debugPrint('Error clearing playback state: $e');
    }
    
    // Report stop to Jellyfin
    if (_currentTrack != null && _reportingService != null) {
      _reportingService?.reportPlaybackStopped(
        _currentTrack!,
        _lastPosition,
      ).catchError((e) => debugPrint('Stop report failed: $e'));
    }
    
    // 3. CLEAR active memory state
    _currentTrack = null;
    _currentTrackController.add(null);
    _queue = [];
    _currentIndex = 0;
    _lastPosition = Duration.zero;
    _isShuffleEnabled = false;
    _isCurrentTrackLocal = false;
    _shuffleController.add(false);
    
    _emitIdleVisualizer();
    _playingController.add(false);

    debugPrint('🛑 Playback stopped and queue cleared');
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

    // Clear pre-loaded track since queue changed
    _clearPreload();

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

  /// Add track(s) to play immediately after the current track
  /// This is the "Play Next" feature - inserts at currentIndex + 1
  void playNext(List<JellyfinTrack> tracks) {
    if (tracks.isEmpty) return;

    // If nothing is playing, just start playing the first track
    if (_currentTrack == null || _queue.isEmpty) {
      unawaited(playTrack(tracks.first, queueContext: tracks));
      return;
    }

    // Insert tracks right after the current track
    final insertIndex = _currentIndex + 1;
    _queue.insertAll(insertIndex, tracks);

    // Clear pre-loaded track since queue changed
    _clearPreload();

    _queueController.add(_queue);
    _audioHandler?.updateNautuneQueue(_queue);

    debugPrint('▶️ Play Next: Added ${tracks.length} track(s) at position $insertIndex');

    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queue,
      currentQueueIndex: _currentIndex,
      currentTrack: _currentTrack,
    ));
  }

  /// Add track(s) to the end of the queue
  /// This is the "Add to Queue" feature - appends to the end
  void addToQueue(List<JellyfinTrack> tracks) {
    if (tracks.isEmpty) return;

    // If nothing is playing, just start playing the first track
    if (_currentTrack == null || _queue.isEmpty) {
      unawaited(playTrack(tracks.first, queueContext: tracks));
      return;
    }

    // Add tracks to the end of the queue
    _queue.addAll(tracks);

    // Clear pre-loaded track since queue changed
    _clearPreload();

    _queueController.add(_queue);
    _audioHandler?.updateNautuneQueue(_queue);

    debugPrint('➕ Add to Queue: Added ${tracks.length} track(s) to end of queue');

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

  // A-B Loop functionality
  // Only works for local/cached tracks (not streaming)

  /// Check if the current track supports looping (is local or cached)
  bool get isLoopAvailable {
    if (_currentTrack == null) return false;
    // Use the flag set during playback - covers both downloads and cache
    return _isCurrentTrackLocal;
  }

  /// Set the loop start marker (A) at the current position
  void setLoopStart() {
    if (!isLoopAvailable) {
      debugPrint('🔁 Loop: Not available for streaming tracks');
      return;
    }
    _loopState = _loopState.copyWith(
      start: _lastPosition,
      clearEnd: true, // Clear end when setting new start
      isActive: false,
    );
    _loopStateController.add(_loopState);
    debugPrint('🔁 Loop: Set A marker at ${_loopState.formattedStart}');
  }

  /// Set the loop end marker (B) at the current position and activate loop
  void setLoopEnd() {
    if (!isLoopAvailable) {
      debugPrint('🔁 Loop: Not available for streaming tracks');
      return;
    }
    if (_loopState.start == null) {
      debugPrint('🔁 Loop: Cannot set B without A');
      return;
    }
    if (_lastPosition <= _loopState.start!) {
      debugPrint('🔁 Loop: B must be after A');
      return;
    }
    _loopState = _loopState.copyWith(
      end: _lastPosition,
      isActive: true,
    );
    _loopStateController.add(_loopState);
    debugPrint('🔁 Loop: Set B marker at ${_loopState.formattedEnd}, loop active');
  }

  /// Set loop markers at specific positions (for UI drag/drop)
  void setLoopMarkers(Duration start, Duration end) {
    if (!isLoopAvailable) return;
    if (end <= start) return;
    _loopState = LoopState(
      start: start,
      end: end,
      isActive: true,
    );
    _loopStateController.add(_loopState);
    debugPrint('🔁 Loop: Set markers ${_loopState.formattedStart} - ${_loopState.formattedEnd}');
  }

  /// Toggle loop on/off (only if markers are set)
  void toggleLoop() {
    if (!_loopState.hasValidLoop) {
      debugPrint('🔁 Loop: No valid loop markers set');
      return;
    }
    _loopState = _loopState.copyWith(isActive: !_loopState.isActive);
    _loopStateController.add(_loopState);
    debugPrint('🔁 Loop: ${_loopState.isActive ? "activated" : "deactivated"}');
  }

  /// Clear all loop markers
  void clearLoop() {
    _loopState = LoopState.empty;
    _loopStateController.add(_loopState);
    debugPrint('🔁 Loop: Cleared');
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
  
  /// Check if we need to fetch more tracks for infinite radio mode
  Future<void> _checkInfiniteRadio() async {
    if (!_infiniteRadioEnabled || _isFetchingInfiniteRadio) return;
    if (_jellyfinService == null || _currentTrack == null) return;
    
    // Calculate remaining tracks in queue
    final remainingTracks = _queue.length - _currentIndex - 1;
    
    if (remainingTracks <= _infiniteRadioThreshold) {
      debugPrint('📻 Infinite Radio: $remainingTracks tracks remaining, fetching more...');
      await _fetchInfiniteRadioTracks();
    }
  }
  
  /// Fetch similar tracks using Jellyfin's Instant Mix and append to queue
  Future<void> _fetchInfiniteRadioTracks() async {
    if (_isFetchingInfiniteRadio || _jellyfinService == null || _currentTrack == null) {
      return;
    }
    
    _isFetchingInfiniteRadio = true;
    
    try {
      // Use current track to find similar tracks
      final mixTracks = await _jellyfinService!.getInstantMix(
        itemId: _currentTrack!.id,
        limit: 20, // Fetch 20 tracks at a time
      );
      
      if (mixTracks.isEmpty) {
        debugPrint('📻 Infinite Radio: No similar tracks found');
        return;
      }
      
      // Filter out tracks already in queue to avoid duplicates
      final existingIds = _queue.map((t) => t.id).toSet();
      final newTracks = mixTracks.where((t) => !existingIds.contains(t.id)).toList();
      
      if (newTracks.isEmpty) {
        debugPrint('📻 Infinite Radio: All suggested tracks already in queue');
        return;
      }
      
      // Append new tracks to queue
      _queue.addAll(newTracks);
      
      debugPrint('📻 Infinite Radio: Added ${newTracks.length} tracks to queue (total: ${_queue.length})');
      
      // Save updated queue
      unawaited(_stateStore.savePlaybackSnapshot(
        queue: _queue,
        currentQueueIndex: _currentIndex,
      ));
      
    } catch (e) {
      debugPrint('📻 Infinite Radio: Failed to fetch tracks: $e');
    } finally {
      _isFetchingInfiniteRadio = false;
    }
  }
  
  /// Analyze track metadata (ReplayGain + genres) to configure visualizer
  void _analyzeTrackForVisualizer(JellyfinTrack? track) {
    if (track == null) {
      _trackIntensity = 0.5;
      _bassEmphasis = 0.5;
      _animationSpeed = 1.0;
      return;
    }

    // ReplayGain loudness: negative = louder track
    // Range typically -20dB to +10dB, we map to intensity 0.3-1.0
    final gain = track.normalizationGain ?? 0.0;
    _trackIntensity = (0.65 - (gain / 40)).clamp(0.3, 1.0);
    // e.g., -6.5dB → 0.65 + 0.16 = 0.81 (high intensity)
    // e.g., +5dB → 0.65 - 0.125 = 0.52 (moderate)

    // Genre-based animation style
    final genres = track.genres?.map((g) => g.toLowerCase()).toList() ?? [];

    // Bass-heavy genres
    const bassyGenres = ['edm', 'electronic', 'rock', 'metal', 'hip-hop', 'hip hop',
                         'dubstep', 'drum and bass', 'house', 'techno', 'punk', 'rap'];
    // Smooth genres
    const smoothGenres = ['classical', 'jazz', 'ambient', 'folk', 'acoustic',
                          'piano', 'orchestral', 'new age', 'chill', 'lounge'];

    final isBassy = genres.any((g) => bassyGenres.any((b) => g.contains(b)));
    final isSmooth = genres.any((g) => smoothGenres.any((s) => g.contains(s)));

    if (isBassy) {
      _bassEmphasis = 0.8;      // Strong bass response
      _animationSpeed = 1.5;    // Faster, more energetic
    } else if (isSmooth) {
      _bassEmphasis = 0.25;     // Gentle bass
      _animationSpeed = 0.6;    // Slower, flowing
    } else {
      _bassEmphasis = 0.5;      // Default
      _animationSpeed = 1.0;
    }

    debugPrint('🎨 Visualizer: intensity=${_trackIntensity.toStringAsFixed(2)}, '
        'bassEmphasis=$_bassEmphasis, speed=$_animationSpeed '
        '(gain: ${gain.toStringAsFixed(1)}dB, genres: ${genres.take(3).join(", ")})');
  }

  void _emitVisualizerFrame(Duration position) {
    final hasVisualizerListeners = _visualizerController.hasListener;
    final hasFrequencyListeners = _frequencyBandsController.hasListener;
    if (!hasVisualizerListeners && !hasFrequencyListeners) return;

    // Time variable scaled by track's animation speed
    final t = (position.inMilliseconds / 120.0) * _animationSpeed;

    // Detect volume change and create pulse effect
    if ((_volume - _lastVolume).abs() > 0.01) {
      _volumePulse = 1.0; // Trigger pulse on volume change
      _lastVolume = _volume;
    }
    _volumePulse *= 0.95; // Decay pulse

    // Amplitude driven by track intensity (from ReplayGain)
    final baseAmplitude = 0.15 + (_trackIntensity * 0.35);
    final volumeMultiplier = baseAmplitude + (_volume * 0.5) + (_volumePulse * 0.2);

    // Reuse pre-allocated array instead of List.generate() to avoid per-frame allocations
    for (int index = 0; index < _visualizerBarCount; index++) {
      // Different frequencies for bass/mid/treble regions
      final freq = index < 8 ? 0.3 : (index < 16 ? 0.7 : 1.2);
      final wave = (sin(t * freq + index * 0.45) + 1) * 0.5;
      final ripple = (sin((t * freq * 0.6) + index) + 1) * 0.25;

      // Bass region (0-7) gets genre-based emphasis
      final bassBoost = index < 8 ? _bassEmphasis * 0.4 : 0.0;
      final value = ((wave * 0.7) + (ripple * 0.3) + bassBoost) * volumeMultiplier;
      _visualizerBars[index] = value.clamp(0.0, 1.0);
    }

    if (hasVisualizerListeners) {
      // Pass a copy of the list to avoid mutation issues in stream listeners
      _visualizerController.add(List<double>.from(_visualizerBars));
    }

    // Extract frequency bands with genre emphasis using pre-allocated array
    if (hasFrequencyListeners) {
      // Calculate bass (indices 0-7)
      double bassSum = 0.0;
      for (int i = 0; i < 8; i++) {
        bassSum += _visualizerBars[i];
      }
      final rawBass = bassSum / 8;
      final bass = (rawBass + _bassEmphasis * 0.2).clamp(0.0, 1.0);

      // Calculate mid (indices 8-15)
      double midSum = 0.0;
      for (int i = 8; i < 16; i++) {
        midSum += _visualizerBars[i];
      }
      final mid = (midSum / 8).clamp(0.0, 1.0);

      // Calculate treble (indices 16-23)
      double trebleSum = 0.0;
      for (int i = 16; i < 24; i++) {
        trebleSum += _visualizerBars[i];
      }
      final treble = (trebleSum / 8).clamp(0.0, 1.0);

      _frequencyBandsController.add(FrequencyBands(
        bass: bass,
        mid: mid,
        treble: treble,
      ));
    }
  }

  void _emitIdleVisualizer() {
    if (_visualizerController.hasListener) {
      _visualizerController.add(List<double>.filled(_visualizerBarCount, 0));
    }
    if (_frequencyBandsController.hasListener) {
      _frequencyBandsController.add(FrequencyBands.zero);
    }
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
  
  /// Track being recorded (to avoid double-recording)
  JellyfinTrack? _trackBeingRecorded;

  /// Record actual listening time for the current track to analytics.
  /// Call this when: track ends, user skips, user stops, new track starts.
  void _recordActualListeningTime() {
    final track = _currentTrack;
    final startTime = _trackStartTime;

    // Only record if we have a valid track and start time
    if (track == null || startTime == null) return;

    // Prevent double-recording the same track instance
    if (_trackBeingRecorded?.id == track.id && _trackBeingRecorded == track) {
      return;
    }
    _trackBeingRecorded = track;

    // Calculate actual listening time
    final now = DateTime.now();
    final actualDurationMs = now.difference(startTime).inMilliseconds;

    // Record to analytics with actual duration
    unawaited(ListeningAnalyticsService().recordPlay(
      track,
      actualDurationMs: actualDurationMs,
      playStartTime: startTime,
    ));

    debugPrint('🎵 Recorded actual listen time: ${actualDurationMs ~/ 1000}s for "${track.name}"');

    // Clear start time to prevent duplicate recording
    _trackStartTime = null;
    _trackBeingRecorded = null;
  }

  Future<void> _saveCurrentPosition() async {
    if (_currentTrack == null) return;

    final position = await _player.getCurrentPosition();
    if (position != null) {
      // Track listen time
      if (isPlaying) {
        _playStats.addListenTime(_currentTrack!.id, const Duration(seconds: 1));
        _accumulatedTime += const Duration(seconds: 1);
        // Save every minute
        if (_accumulatedTime.inSeconds >= 60) {
          _accumulatedTime = Duration.zero;
          unawaited(_savePlayStats());
        }
      }

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

  /// Saves full playback state including queue - called when app goes to background
  /// or is about to be force closed. This ensures user can resume exactly where they left off.
  Future<void> saveFullPlaybackState() async {
    if (_currentTrack == null) return;
    
    final position = await _player.getCurrentPosition();
    if (position != null) {
      _lastPosition = position;
    }
    
    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: _lastPosition,
      queue: _queue,
      currentQueueIndex: _currentIndex,
      isPlaying: isPlaying,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
      volume: _volume,
    );
    debugPrint('💾 Full playback state saved: ${_currentTrack?.name} @ ${_lastPosition.inSeconds}s');
  }


  // ========== A-B LOOP METHODS ==========

  /// Check if position has reached loop end and seek back to start
  void _checkLoopBoundary(Duration position) {
    if (!_loopState.isActive || !_loopState.hasValidLoop) return;

    // Check if we've passed the loop end point
    if (position >= _loopState.end!) {
      // Seek back to loop start
      debugPrint('🔁 Loop: Reached end, seeking to start');
      unawaited(seek(_loopState.start!));
    }
  }

  // ========== CROSSFADE METHODS ==========

  /// Check if we should trigger crossfade based on current position
  void _checkCrossfadeTrigger(Duration position) async {
    if (!_crossfadeEnabled || _isCrossfading || _crossfadeDurationSeconds == 0) {
      return;
    }

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _cachedDuration;
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
    if (_isCrossfading || _crossfadePlayer == null) return;
    _isCrossfading = true;

    try {
      // Stop any existing playback in crossfade player
      await _crossfadePlayer!.stop();

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
    if (_crossfadePlayer == null) return;

    // Stop current player
    await _player.stop();
    await _player.setVolume(_volume); // Reset volume

    // Swap players: move crossfade player's source to main player
    // This is done by stopping the crossfade player and letting the normal
    // playback flow handle the next track
    await _crossfadePlayer!.stop();

    // Update track info
    _currentIndex = nextIndex;
    _currentTrack = nextTrack;
    _currentTrackController.add(_currentTrack);

    // Play the next track normally (already loaded in crossfade player)
    await playTrack(
      nextTrack,
      queueContext: _queue,
      fromShuffle: _isShuffleEnabled,
    );

    _isCrossfading = false;

    debugPrint('✅ Crossfade complete → ${nextTrack.name}');
  }

  // ========== PRE-LOADING METHODS FOR GAPLESS PLAYBACK ==========

  /// Check if we should pre-load the next track (when current track reaches 70%)
  void _checkPreloadTrigger(Duration position) async {
    if (!_gaplessPlaybackEnabled) return;
    if (_isPreloading || _currentTrack == null) return;

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _cachedDuration;
    if (duration == null || duration.inMilliseconds == 0) return;

    // Pre-load when we're 70% through the current track
    final preloadThreshold = duration * 0.7;
    if (position < preloadThreshold) return;

    // Get next track
    final nextTrack = _getNextTrack();
    if (nextTrack == null) return;

    // Don't pre-load if already loaded
    if (_preloadedTrack?.id == nextTrack.id) return;

    // Pre-load the next track
    await _preloadNextTrack(nextTrack);
  }

  /// Pre-fetch lyrics for the next track at ~50% playback
  void _checkLyricsPrefetch(Duration position) async {
    if (_lyricsPrefetched || _currentTrack == null || _lyricsService == null) return;

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _cachedDuration;
    if (duration == null || duration.inMilliseconds == 0) return;

    // Pre-fetch lyrics at 50% playback
    final prefetchThreshold = duration * 0.5;
    if (position < prefetchThreshold) return;

    // Get next track
    final nextTrack = _getNextTrack();
    if (nextTrack == null) return;

    _lyricsPrefetched = true;
    debugPrint('Prefetching lyrics for next track: ${nextTrack.name}');
    _lyricsService!.prefetchLyrics(nextTrack);
  }

  /// Check if we should scrobble to ListenBrainz
  /// Scrobbles when track has played for 50% OR 4 minutes, whichever is less
  void _checkListenBrainzScrobble(Duration position) async {
    if (_hasScrobbled || _currentTrack == null || _trackStartTime == null) return;

    final listenBrainz = ListenBrainzService();
    if (!listenBrainz.isScrobblingEnabled) return;

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _currentTrack!.duration ?? _cachedDuration;
    if (duration == null || duration.inMilliseconds == 0) return;

    // Scrobble threshold: 50% of track OR 4 minutes, whichever is less
    final halfDuration = duration.inSeconds ~/ 2;
    const fourMinutes = 240; // 4 minutes in seconds
    final thresholdSeconds = halfDuration < fourMinutes ? halfDuration : fourMinutes;

    // Check if we've reached the threshold
    if (position.inSeconds >= thresholdSeconds) {
      _hasScrobbled = true;
      debugPrint('🎵 ListenBrainz: Scrobbling "${_currentTrack!.name}" (${position.inSeconds}s >= ${thresholdSeconds}s threshold)');

      unawaited(listenBrainz.submitListen(
        _currentTrack!,
        _trackStartTime!,
      ));
    }
  }

  /// Pre-load the next track into _nextPlayer for instant playback
  Future<void> _preloadNextTrack(JellyfinTrack track) async {
    if (_isPreloading) return;
    _isPreloading = true;

    try {
      debugPrint('⏩ Pre-loading next track: ${track.name}');

      await _nextPlayer.stop();

      Future<bool> trySetSource(String? url, {bool isFile = false}) async {
        if (url == null) return false;
        try {
          if (isFile) {
            await _nextPlayer.setSource(DeviceFileSource(url));
          } else {
            await _nextPlayer.setSource(UrlSource(url));
          }
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
          await _nextPlayer.setSource(AssetSource(normalized));
          return true;
        } on PlatformException {
          return false;
        }
      }

      bool loaded = false;
      bool isLocal = false;

      // Try local file first (downloaded)
      final localPath = _downloadService?.getLocalPath(track.id);
      if (localPath != null) {
        final file = File(localPath);
        if (await file.exists()) {
          if (await trySetSource(localPath, isFile: true)) {
            loaded = true;
            isLocal = true;
            debugPrint('✅ Pre-loaded from local file: ${track.name}');
          }
        }
      }

      // Try cached file (pre-cached during album playback)
      if (!loaded) {
        final cachedFile = await _audioCacheService.getCachedFile(track.id);
        if (cachedFile != null && await cachedFile.exists()) {
          if (await trySetSource(cachedFile.path, isFile: true)) {
            loaded = true;
            isLocal = true;
            debugPrint('✅ Pre-loaded from cache: ${track.name}');
          }
        }
      }

      // Try streaming if no local/cached file
      if (!loaded) {
        final (streamUrl, isDirectStream) = _getStreamUrl(track);

        if (await trySetSource(streamUrl)) {
          loaded = true;
          isLocal = false;
          if (isDirectStream) {
            debugPrint('✅ Pre-loaded from stream (original): ${track.name}');
          } else {
            debugPrint('✅ Pre-loaded from stream (${_streamingQuality.label}): ${track.name}');
          }
        } else if (await trySetAssetSource(track.assetPathOverride)) {
          loaded = true;
          isLocal = true; // Asset files are local
          debugPrint('✅ Pre-loaded from asset: ${track.name}');
        }
      }

      if (loaded) {
        _preloadedTrack = track;
        _preloadedTrackIsLocal = isLocal;
        // Set to ready but don't play yet
        await _nextPlayer.setVolume(0.0); // Silent until we swap
      } else {
        debugPrint('⚠️ Failed to pre-load: ${track.name}');
        _preloadedTrack = null;
        _preloadedTrackIsLocal = false;
      }
    } catch (e) {
      debugPrint('⚠️ Error pre-loading track: $e');
      _preloadedTrack = null;
    } finally {
      _isPreloading = false;
    }
  }

  /// Get the next track that should play (respects repeat mode)
  JellyfinTrack? _getNextTrack() {
    if (_queue.isEmpty) return null;

    // Repeat one mode - next track is the same track
    if (_repeatMode == RepeatMode.one) {
      return _currentTrack;
    }

    // Get next index
    int nextIndex = _currentIndex + 1;

    // Handle end of queue
    if (nextIndex >= _queue.length) {
      if (_repeatMode == RepeatMode.all) {
        nextIndex = 0; // Loop back to start
      } else {
        return null; // Queue ended
      }
    }

    return _queue[nextIndex];
  }

  /// Clear pre-loaded track (called when queue changes)
  void _clearPreload() {
    _preloadedTrack = null;
    _preloadedTrackIsLocal = false;
    _nextPlayer.stop();
  }
  
  // ========== AUDIO CACHE METHODS ==========
  
  /// Clear the audio cache (streaming cache, not downloads)
  Future<void> clearAudioCache() async {
    await _audioCacheService.clearCache();
  }
  
  /// Get audio cache statistics
  Future<Map<String, dynamic>> getAudioCacheStats() async {
    return _audioCacheService.getCacheStats();
  }
  
  /// Pre-cache tracks for an album (can be called manually)
  Future<void> preCacheAlbumTracks(List<JellyfinTrack> tracks) async {
    await _audioCacheService.cacheAlbumTracks(tracks);
  }

  // ========== SLEEP TIMER METHODS ==========

  /// Start sleep timer with duration (time-based)
  void startSleepTimer(Duration duration) {
    cancelSleepTimer();
    _isSleepTimerByTracks = false;
    _sleepTimeRemaining = duration;
    _preSleepVolume = _volume;
    _sleepTimerController.add(_sleepTimeRemaining);

    debugPrint('😴 Sleep timer started: ${duration.inMinutes} minutes');

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sleepTimeRemaining -= const Duration(seconds: 1);
      _sleepTimerController.add(_sleepTimeRemaining);

      // Start fade-out in last 30 seconds
      if (_sleepTimeRemaining.inSeconds <= 30 && _sleepTimeRemaining.inSeconds > 0) {
        final fadeProgress = _sleepTimeRemaining.inSeconds / 30.0;
        final fadedVolume = _preSleepVolume * fadeProgress;
        _player.setVolume(fadedVolume.clamp(0.0, 1.0));
      }

      // Timer complete
      if (_sleepTimeRemaining.inSeconds <= 0) {
        debugPrint('😴 Sleep timer complete - stopping playback');
        _fadeOutAndStop();
      }
    });
  }

  /// Start sleep timer by track count
  void startSleepTimerByTracks(int trackCount) {
    cancelSleepTimer();
    _isSleepTimerByTracks = true;
    _sleepTracksRemaining = trackCount;
    _preSleepVolume = _volume;
    // Broadcast a sentinel value indicating track-based timer
    _sleepTimerController.add(Duration(seconds: -_sleepTracksRemaining));

    debugPrint('😴 Sleep timer started: $trackCount tracks remaining');
  }

  /// Cancel sleep timer
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimeRemaining = Duration.zero;
    _sleepTracksRemaining = 0;
    _isSleepTimerByTracks = false;
    _sleepTimerController.add(Duration.zero);

    // Restore volume if we were fading
    if (_preSleepVolume != _volume) {
      setVolume(_preSleepVolume);
    }

    debugPrint('😴 Sleep timer cancelled');
  }

  /// Fade out volume and stop playback
  void _fadeOutAndStop() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimeRemaining = Duration.zero;
    _sleepTracksRemaining = 0;
    _isSleepTimerByTracks = false;
    _sleepTimerController.add(Duration.zero);

    // Final fade to zero and pause
    _player.setVolume(0.0);
    pause();

    // Restore volume for next session
    Future.delayed(const Duration(milliseconds: 500), () {
      setVolume(_preSleepVolume);
    });

    debugPrint('😴 Sleep timer: Playback stopped, volume restored to $_preSleepVolume');
  }

  void dispose() {
    _positionSaveTimer?.cancel();
    _crossfadeTimer?.cancel();
    _sleepTimer?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _detachListeners();
    _audioHandler?.dispose();
    _player.dispose();
    _nextPlayer.dispose();
    _crossfadePlayer?.dispose();
    _currentTrackController.close();
    _playingController.close();
    _positionController.close();
    _bufferedPositionController.close();
    _durationController.close();
    _queueController.close();
    _repeatModeController.close();
    _volumeController.close();
    _shuffleController.close();
    _visualizerController.close();
    _sleepTimerController.close();
    _frequencyBandsController.close();
  }
}

class PositionData {
  const PositionData(
    this.position,
    this.bufferedPosition,
    this.duration,
  );

  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;
}

/// Network type for auto quality selection
enum _NetworkType {
  wifi,     // WiFi or Ethernet - use original quality
  cellular, // Mobile data - use normal quality (192kbps)
  slow,     // Unknown/slow - use low quality (128kbps)
}
