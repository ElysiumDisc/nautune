import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, sin;
import 'dart:ui' show AppLifecycleState;
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
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
import 'playback_logic.dart';
import 'playback_reporting_service.dart';
import 'playback_state_store.dart';
import '../models/playback_state.dart';
import '../models/play_stats.dart';
import 'local_cache_service.dart';
import 'ios_fft_service.dart';
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

  // Double-buffer strategy for visualizer: write to one buffer, emit the other.
  // Eliminates per-frame List.from() allocation.
  final Float64List _vizBufferA = Float64List(_visualizerBarCount);
  final Float64List _vizBufferB = Float64List(_visualizerBarCount);
  bool _useVizBufferA = true;
  // Pre-allocated idle frame (all zeros) reused across calls
  static final List<double> _idleVisualizerFrame =
      List<double>.unmodifiable(List<double>.filled(_visualizerBarCount, 0.0));

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
  DateTime? _lastListenTimeRecord;
  int _lastThresholdCheckMs = 0;
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

  // Cancellable waveform extraction subscription
  StreamSubscription? _waveformExtractionSub;

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
  LyricsService? get lyricsService => _lyricsService;
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
  // True once the time-based sleep timer has started lowering the player
  // volume. The fade is derived from [_volume] (the user's volume, which the
  // fade never modifies), so cancelling only has to re-apply [_volume] when
  // this is set.
  bool _sleepFadeApplied = false;

  // Monotonic token for playTrack/gapless/crossfade. Each new request bumps
  // it; older requests bail after every await so the last *request* wins
  // rather than the last to finish.
  int _playRequestId = 0;
  // Serialises player source/resume operations across overlapping requests.
  Future<void> _playerOpLock = Future<void>.value();
  // Serialises playback start/stop reports so a slow "stopped" for the old
  // track can't null the session id of the track that started after it.
  Future<void> _reportChain = Future<void>.value();
  // Track whose playback start was last reported to Jellyfin (null once its
  // stop has been reported).
  JellyfinTrack? _reportedTrack;

  // Session restore: track loaded in paused state, begin-track bookkeeping
  // deferred until the user first resumes.
  bool _restoreBeginPending = false;
  // Session restore: source could not be prepared in time; set it lazily on
  // first resume.
  bool _restoreSourcePending = false;

  // Audio interruptions (phone calls, Siri, other apps)
  bool _wasPlayingBeforeInterruption = false;
  bool _isDucked = false;

  // Crossfade support
  AudioPlayer? _crossfadePlayer;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  Timer? _crossfadeTimer;
  bool _isCrossfading = false;
  bool _crossfadeTrackIsLocal = false;
  
  // Infinite Radio support
  bool _infiniteRadioEnabled = false;
  Completer<void>? _infiniteRadioFetchCompleter;
  static const int _infiniteRadioThreshold = 2; // Fetch when 2 or fewer tracks remain

  // Streaming quality
  StreamingQuality _streamingQuality = StreamingQuality.original;

  // Smart caching settings
  int _preCacheTrackCount = 3;  // 0 = off, 3, 5, or 10
  bool _wifiOnlyCaching = false;
  ConnectivityService? _connectivityService;
  StreamSubscription<bool>? _connectivitySubscription;

  // Battery saver mode (Submarine Mode)
  bool _batterySaverMode = false;

  JellyfinTrack? _currentTrack;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  Timer? _positionSaveTimer;
  int? _lastSavedPositionMs;
  bool _isTransitioning = false;
  bool _disposed = false;
  Duration _lastPosition = Duration.zero;
  bool _lastPlayingState = false;
  RepeatMode _repeatMode = RepeatMode.off;

  // A-B Loop state
  LoopState _loopState = LoopState.empty;
  bool _isLoopSeeking = false; // Guard to prevent seek thrashing at loop boundary
  final _loopStateController = BehaviorSubject<LoopState>.seeded(LoopState.empty);

  final StreamController<double> _volumeController = StreamController<double>.broadcast();
  final StreamController<bool> _shuffleController = StreamController<bool>.broadcast();
  final StreamController<List<double>> _visualizerController = StreamController<List<double>>.broadcast();
  final StreamController<String> _playbackErrorController = StreamController<String>.broadcast();
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
    if (artworkPath != null && await File(artworkPath).exists()) {
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

  bool get infiniteRadioEnabled => _infiniteRadioEnabled;

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
    // Subscribe to connectivity changes for immediate quality adaptation
    _connectivitySubscription?.cancel();
    _connectivitySubscription = service.onStatusChange.listen((_) {
      _updateNetworkType(service);
    });
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

  bool get batterySaverMode => _batterySaverMode;

  void setBatterySaverMode(bool enabled) {
    _batterySaverMode = enabled;
    // Restart position save timer with appropriate interval
    if (_positionSaveTimer != null) {
      _startPositionSaving();
    }
    debugPrint('🔋 Battery saver mode: ${enabled ? "ON" : "OFF"}');

    // When exiting battery saver, trigger waveform extraction for current track
    if (!enabled && _currentTrack != null && WaveformService.instance.isAvailable) {
      unawaited(_triggerWaveformForCurrentTrack().catchError(
        (e) => debugPrint('🌊 Waveform trigger failed: $e'),
      ));
    }
  }

  /// Trigger waveform extraction for the currently playing track.
  /// Called when exiting battery saver mode to catch up on skipped extractions.
  Future<void> _triggerWaveformForCurrentTrack() async {
    final track = _currentTrack;
    if (track == null) return;

    // Check local file sources
    final localPath = await _downloadService?.getLocalPath(track.id);
    if (localPath != null) {
      _extractWaveformForLocalFile(track, localPath);
      return;
    }
    final cachedFile = await _audioCacheService.getCachedFile(track.id);
    if (cachedFile != null && await cachedFile.exists()) {
      _extractWaveformForLocalFile(track, cachedFile.path);
      return;
    }
    // Streaming — cache then extract
    final (streamUrl, _) = _getStreamUrl(track);
    if (streamUrl != null) {
      _cacheTrackForWaveform(track, streamUrl);
    }
  }

  PlaybackReportingService? get reportingService => _reportingService;

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

  /// Refresh cached network type if stale (fallback for stream-based updates)
  void _refreshNetworkTypeIfNeeded() {
    final now = DateTime.now();
    final lastCheck = _lastNetworkCheck;

    // Check every 10 seconds (primary updates come from connectivity stream)
    if (lastCheck != null && now.difference(lastCheck).inSeconds < 10) {
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

  /// Update offline state for lyrics caching (returns expired cache when offline)
  void setOfflineMode(bool offline) {
    _lyricsService?.setOffline(offline);
  }

  /// Enable or disable image prewarming (called by offline mode gate).
  void setImagePrewarmEnabled(bool enabled) {
    _imagePrewarmService?.enabled = enabled;
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
  Stream<String> get playbackErrorStream => _playbackErrorController.stream;

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

    // Apply ReplayGain to both main and preloaded player
    final nextTrack = _preloadedTrack;
    final nextMultiplier = nextTrack?.replayGainMultiplier ?? 1.0;
    final nextAdjustedVolume = (_volume * nextMultiplier).clamp(0.0, 1.0);
    await Future.wait([
      _player.setVolume(adjustedVolume),
      _nextPlayer.setVolume(nextAdjustedVolume),
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
      // A session restore may have finished before the handler existed;
      // publish its track now so the lock screen / CarPlay aren't blank.
      final restored = _currentTrack;
      if (restored != null) {
        await _publishMediaItem(restored);
        _audioHandler?.updateNautuneQueue(_queue);
        await _audioHandler?.forceBroadcastCurrentState();
      }
    } catch (e) {
      debugPrint('⚠️ Audio service initialization failed: $e');
    }
  }
  
  Future<void> _initAudioSession() async {
    // Initialize FFT services for real audio visualization
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.initialize());
    }

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      
      // Handle audio interruptions (phone calls, other media apps)
      await _interruptionSubscription?.cancel();
      _interruptionSubscription = session.interruptionEventStream.listen(
        _handleInterruption,
        onError: (e) => debugPrint('⚠️ Audio interruption stream error: $e'),
      );

      // Pause when headphones are unplugged / audio becomes noisy
      await _becomingNoisySubscription?.cancel();
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen(
        (_) => unawaited(pause()),
        onError: (e) => debugPrint('⚠️ Becoming noisy stream error: $e'),
      );
    } catch (e) {
      debugPrint('Audio session setup failed: $e');
    }
  }

  /// Reactivate audio session after interruption and resume playback.
  /// This is critical for iOS lock screen playback recovery.
  Future<void> _reactivateAndResume() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      // Configuring alone does not re-activate the session after iOS
      // deactivated it for the interruption.
      await session.setActive(true);
      debugPrint('🔊 Audio session reactivated after interruption');
      await resume();
    } catch (e) {
      debugPrint('⚠️ Failed to reactivate audio session: $e');
    }
  }

  /// Handles OS audio interruptions.
  ///
  /// iOS reports `begin` as [AudioInterruptionType.unknown] and `end` as
  /// [AudioInterruptionType.pause] only when the system says playback should
  /// resume. We only auto-resume if *we* were playing when it began, so music
  /// the user had paused before a call stays paused.
  void _handleInterruption(AudioInterruptionEvent event) {
    if (_disposed) return;
    if (event.begin) {
      debugPrint('🔊 Audio interruption began: ${event.type}');
      if (event.type == AudioInterruptionType.duck) {
        if (isPlaying && !_isDucked) {
          _isDucked = true;
          final multiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
          unawaited(_player.setVolume((_volume * multiplier * 0.3).clamp(0.0, 1.0)));
        }
        return;
      }
      // pause / unknown: remember whether we were audible, then pause.
      final wasPlaying = isPlaying || _lastPlayingState;
      _wasPlayingBeforeInterruption = _wasPlayingBeforeInterruption || wasPlaying;
      if (wasPlaying) {
        unawaited(pause());
      }
    } else {
      debugPrint('🔊 Audio interruption ended: ${event.type}');
      if (_isDucked) {
        _isDucked = false;
        unawaited(_applyUserVolumeToPlayer());
      }
      if (event.type == AudioInterruptionType.duck) return;
      final shouldResume = event.type == AudioInterruptionType.pause &&
          _wasPlayingBeforeInterruption;
      _wasPlayingBeforeInterruption = false;
      if (shouldResume && !isPlaying) {
        unawaited(_reactivateAndResume());
      }
    }
  }

  /// Re-apply the user's volume (with ReplayGain) to the main player, e.g.
  /// after ducking or a cancelled sleep-timer fade.
  Future<void> _applyUserVolumeToPlayer() async {
    final multiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
    await _player.setVolume((_volume * multiplier).clamp(0.0, 1.0));
  }

  /// Configure and activate the audio session right before audible playback
  /// (iOS may have deactivated it in the background or after interruptions).
  Future<void> _ensureSessionActiveForPlayback() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (e) {
      debugPrint('⚠️ Failed to activate audio session: $e');
    }
  }

  /// Whether the app is in the foreground. The iOS FFT shadow player must not
  /// be (re)started while backgrounded; main.dart suspends it on background
  /// and IOSFFTService.resumeFromBackground() re-engages it on return.
  bool get _isAppInForeground {
    try {
      final state = SchedulerBinding.instance.lifecycleState;
      // `inactive` (Control Center, call banner) is still on screen.
      return state == null ||
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive;
    } catch (_) {
      return true;
    }
  }

  /// Point the iOS FFT shadow player at [fileUrl] and start capture, but only
  /// start capture when foregrounded. When backgrounded the URL is still set
  /// so capture resumes on the right track when the app returns.
  Future<void> _startIOSFFTFor(String fileUrl, {bool restart = false}) async {
    if (!Platform.isIOS) return;
    final fft = IOSFFTService.instance;
    final foreground = _isAppInForeground;
    if (restart) {
      await fft.stopCapture();
      fft.resetUrl();
    }
    await fft.setAudioUrl(fileUrl);
    if (foreground) {
      await fft.startCapture();
    }
  }

  /// Public method to reactivate the audio session.
  /// Call this when app returns from background or goes to background.
  Future<void> reactivateAudioSession() async {
    try {
      // Audio session reconfiguration is only needed on iOS
      if (Platform.isIOS) {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());
        debugPrint('🔊 Audio session reactivated');
      }

      // Force broadcast current state (playing or paused) so lock screen
      // controls stay interactive even when paused before locking the screen.
      // This is needed on all platforms, not just iOS.
      await _audioHandler?.forceBroadcastCurrentState();
    } catch (e) {
      debugPrint('⚠️ Failed to reactivate audio session: $e');
    }
  }

  Future<void> _detachListeners() async {
    // Cancel and null-out so reattach can't stack subscriptions if
    // _attachPlayerListeners throws midway or is called concurrently.
    final futures = <Future<void>>[];
    final pos = _playerPosSub;
    final dur = _playerDurSub;
    final state = _playerStateSub;
    final done = _playerCompleteSub;
    _playerPosSub = null;
    _playerDurSub = null;
    _playerStateSub = null;
    _playerCompleteSub = null;
    if (pos != null) futures.add(pos.cancel());
    if (dur != null) futures.add(dur.cancel());
    if (state != null) futures.add(state.cancel());
    if (done != null) futures.add(done.cancel());
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  void _attachPlayerListeners(AudioPlayer player) {
    // Fire-and-forget detach; null-out happens synchronously so we don't
    // double-attach even while the old subs finish their cancel Future.
    unawaited(_detachListeners());
    
    // Position updates
    _playerPosSub = player.onPositionChanged.listen((position) {
      // Late-arriving callbacks after dispose() would hit closed controllers.
      // The _detachListeners() cancel future races with controller.close() in
      // dispose(); checking _disposed here is the synchronous guard.
      if (_disposed) return;
      _positionController.add(position);
      _lastPosition = position;
      if (player.state == PlayerState.playing && !_batterySaverMode) {
        _emitVisualizerFrame(position);
      }
      // Check A-B loop boundary (needs every tick for tight enforcement)
      _checkLoopBoundary(position);

      // Threshold-based checks only need to run ~once per second
      final posMs = position.inMilliseconds;
      // `posMs < last` catches backward jumps (seek, A-B loop, new track) that
      // would otherwise suppress the checks until the old position is passed.
      if (posMs - _lastThresholdCheckMs >= 1000 || posMs < _lastThresholdCheckMs) {
        _lastThresholdCheckMs = posMs;
        // Check if we should start crossfade
        unawaited(_checkCrossfadeTrigger(position).catchError(
          (e) => debugPrint('🌊 Crossfade trigger failed: $e'),
        ));
        // Check if we should pre-load next track
        unawaited(_checkPreloadTrigger(position).catchError(
          (e) => debugPrint('⏩ Preload trigger failed: $e'),
        ));
        // Pre-fetch lyrics for next track at ~50% playback
        unawaited(_checkLyricsPrefetch(position).catchError(
          (e) => debugPrint('🎤 Lyrics prefetch failed: $e'),
        ));
        // Check ListenBrainz scrobble threshold
        unawaited(_checkListenBrainzScrobble(position).catchError(
          (e) => debugPrint('🎵 ListenBrainz scrobble check failed: $e'),
        ));
        // Sync iOS FFT shadow player position
        if (Platform.isIOS) {
          IOSFFTService.instance.syncPosition(posMs / 1000.0);
        }
      }
    });

    // Duration updates
    // IMPORTANT: Prefer player-reported duration over metadata since it reflects
    // actual audio length. Metadata can be inaccurate (especially for variable bitrate files).
    _playerDurSub = player.onDurationChanged.listen((duration) {
      if (_disposed) return;
      // Use player duration if it's reasonable (> 1 second)
      // This prevents progress bar showing "complete" while audio still plays
      if (duration.inSeconds > 1) {
        _cachedDuration = duration;
        _durationController.add(duration);
      } else if (_currentTrack != null && _currentTrack!.duration != null) {
        // Fallback to metadata duration only if player reports nothing useful
        _cachedDuration = _currentTrack!.duration;
        _durationController.add(_currentTrack!.duration);
      } else if (duration.inMilliseconds > 0) {
        // Last resort: use whatever the player reported
        _cachedDuration = duration;
        _durationController.add(duration);
      }
    });
    
    // State changes
    _playerStateSub = player.onPlayerStateChanged.listen(
      (state) {
        if (_disposed) return;
        final isPlaying = state == PlayerState.playing;
        _playingController.add(isPlaying);

        // Report state change to Jellyfin (only for real Jellyfin tracks)
        if (_lastPlayingState != isPlaying && _currentTrack != null) {
          _lastPlayingState = isPlaying;
          if (_reportingService != null && _currentTrack!.serverUrl != null) {
            _reportingService?.notifyPaused(!isPlaying);
            _reportingService?.reportPlaybackProgress(
              _currentTrack!,
              _lastPosition,
              !isPlaying, // isPaused
            );
          }
        }

        if (isPlaying) {
          _lastListenTimeRecord = DateTime.now();
          _startPositionSaving();
          unawaited(_stateStore.savePlaybackSnapshot(isPlaying: true));
        } else {
          _stopPositionSaving();
          _saveCurrentPosition();
          _emitIdleVisualizer();
          unawaited(_stateStore.savePlaybackSnapshot(isPlaying: false));
        }
      },
      onError: (e) => debugPrint('⚠️ Player state stream error: $e'),
    );

    // Track completion - gapless transition
    _playerCompleteSub = player.onPlayerComplete.listen(
      (_) async {
        if (_disposed) return;
        // During a crossfade the outgoing player completes mid-fade; the
        // crossfade itself advances the queue, so don't advance twice.
        if (!_isTransitioning && !_isCrossfading) {
          await _gaplessTransition();
        }
      },
      onError: (e) => debugPrint('⚠️ Player complete stream error: $e'),
    );
  }
  
  Future<void> _gaplessTransition() async {
    // Close out the finished track: listening time + Jellyfin "stopped".
    _recordActualListeningTime();
    _reportOutgoingStopped();

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
        queueIndex: _currentIndex,
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
      // Claim the player: an older in-flight playTrack must not resume over
      // us, and a newer one (user tap mid-swap) makes us back off.
      final requestId = ++_playRequestId;
      bool isStale() => _disposed || requestId != _playRequestId;
      var usedFallback = false;

      try {
        final nextIndex = _currentIndex + 1;
        final nextTrack = _queue[nextIndex];

        // Check if we have this track pre-loaded AND gapless is enabled
        if (_gaplessPlaybackEnabled && _preloadedTrack?.id == nextTrack.id) {
          debugPrint('⚡ Using pre-loaded track for instant playback: ${nextTrack.name}');

          // CRITICAL: Ensure audio session is active before gapless transition (iOS fix)
          // Without this, resume() can fail silently if iOS deactivated the session
          await _ensureSessionActiveForPlayback();
          if (isStale()) return;

          // SWAP PLAYERS for seamless transition
          // 1. Start playback on the pre-loaded player as early as possible,
          //    at the user's volume with the new track's ReplayGain applied.
          await _nextPlayer.setVolume(
            (_volume * nextTrack.replayGainMultiplier).clamp(0.0, 1.0),
          );
          await _nextPlayer.resume();

          // 2. Detach listeners from the old main player (which is ending)
          // We don't await this to keep the transition instant.
          unawaited(_detachListeners());

          // 3. IMPORTANT: Update AudioHandler to listen to the NEW player (which is playing)
          // BEFORE stopping the old one. This prevents the OS from seeing a "Stop" state.
          _audioHandler?.updatePlayer(_nextPlayer);
          final offlineArtUri = await _getOfflineArtworkUri(nextTrack.id);

          // 3.5 Wait for media session to process the update before stopping old player.
          // Uses a Completer that resolves when updateNautuneMediaItem broadcasts,
          // with a 500ms timeout fallback for safety.
          final updateFuture = _audioHandler?.awaitMediaSessionUpdate();
          _audioHandler?.updateNautuneMediaItem(nextTrack, offlineArtUri: offlineArtUri);
          if (updateFuture != null) await updateFuture;

          if (isStale()) {
            // A newer playTrack took over the main player while we swapped:
            // abandon the swap and hand the OS controls back to it.
            debugPrint('⚡ Gapless swap superseded by a newer request');
            await _nextPlayer.stop();
            if (_disposed) return;
            _audioHandler?.updatePlayer(_player);
            _attachPlayerListeners(_player);
            final current = _currentTrack;
            if (current != null) unawaited(_publishMediaItem(current));
            return;
          }

          // 4. Stop the old player (AudioHandler is no longer listening to this one)
          await _player.stop();

          // 5. Swap the references
          final oldPlayer = _player;
          _player = _nextPlayer;
          _nextPlayer = oldPlayer; // Reuse old player for next pre-load

          // 6. Re-attach listeners to the NEW main player
          _attachPlayerListeners(_player);

          final nextIsLocal = _preloadedTrackIsLocal;
          _preloadedTrack = null;
          _preloadedTrackIsLocal = false;

          _currentIndex = nextIndex;
          _currentTrack = nextTrack;
          _currentTrackController.add(_currentTrack);
          _isCurrentTrackLocal = nextIsLocal; // Update for A-B loop support
          _analyzeTrackForVisualizer(nextTrack); // Configure visualizer for track

          // 7. Explicitly emit playing state since the listener may not fire
          //    if player was already playing when attached
          _playingController.add(true);
          _lastPlayingState = true;

          // Per-track bookkeeping (scrobble/history/report/duration/loop...)
          _onTrackBegan(
            nextTrack,
            playMethod: _playMethodFor(nextTrack, isLocal: nextIsLocal),
            publishMediaItem: false, // already published above
          );

          // 8. Force OS media controls to update (fixes lock screen grayed out button)
          await _audioHandler?.forcePlayingState();

          // Pre-warm album art for upcoming tracks
          if (!_batterySaverMode) {
            _imagePrewarmService?.prewarmQueueImages(_queue, _currentIndex);
          }

          // Smart pre-cache more upcoming tracks
          unawaited(_smartPreCacheUpcoming(_queue, _currentIndex));

          // Restart FFT for the new track during gapless transition.
          // Capture only (re)starts when the app is foregrounded.
          // Wrapped in try-catch: FFT failures are non-fatal and must not crash playback
          try {
            if (Platform.isIOS) {
              String? localPath;
              if (nextIsLocal) {
                localPath = await _downloadService?.getLocalPath(nextTrack.id);
                if (localPath == null) {
                  final cachedFile = await _audioCacheService.getCachedFile(nextTrack.id);
                  localPath = cachedFile?.path;
                }
              }
              if (localPath != null) {
                if (_currentTrack?.id == nextTrack.id) {
                  await _startIOSFFTFor('file://$localPath', restart: true);
                  debugPrint('🎵 iOS FFT: Restarted for gapless transition to ${nextTrack.name}');
                }
              } else {
                // Streaming track during gapless - stop the old track's shadow
                // player, then cache for FFT in background
                await IOSFFTService.instance.stopCapture();
                IOSFFTService.instance.resetUrl();
                final (streamUrl, _) = _getStreamUrl(nextTrack);
                if (streamUrl != null) {
                  unawaited(_cacheTrackForIOSFFT(nextTrack, streamUrl).catchError(
                    (e) => debugPrint('🎵 iOS FFT cache (gapless) failed: $e'),
                  ));
                }
              }
            }
          } catch (fftError) {
            debugPrint('⚠️ FFT restart during gapless failed: $fftError');
            // Non-fatal: playback continues without visualization
          }
        } else {
          // No pre-loaded track or gapless disabled, do regular playback
          debugPrint('🎵 Gapless not available, using regular playback for: ${nextTrack.name}');
          usedFallback = true;
          await playTrack(
            nextTrack,
            queueContext: _queue,
            fromShuffle: _isShuffleEnabled,
            queueIndex: nextIndex,
          );
        }
      } catch (e) {
        debugPrint('❌ Gapless transition failed: $e');
        // playTrack returns (rather than throws) when superseded, so an error
        // from the fallback path is always the latest request's. For the
        // swap path, a newer request means the user has taken over.
        if (_disposed || (!usedFallback && isStale())) return;
        _playbackErrorController.add('Track transition failed, retrying...');
        // Recovery: reactivate audio session and try to play next track
        if (_currentIndex + 1 < _queue.length) {
          final retryIndex = _currentIndex + 1;
          try {
            // Ensure audio session is active before recovery attempt
            await _ensureSessionActiveForPlayback();
            await playTrack(
              _queue[retryIndex],
              queueContext: _queue,
              fromShuffle: _isShuffleEnabled,
              queueIndex: retryIndex,
            );
          } catch (retryError) {
            debugPrint('❌ Recovery also failed: $retryError');
            _playbackErrorController.add('Playback failed. Skipping track.');
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
        await playTrack(
          _queue[0],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: 0,
        );
      } else if (_infiniteRadioEnabled) {
        // Try to fetch more tracks for infinite radio before stopping
        debugPrint('📻 Queue ended, trying infinite radio...');
        await _fetchInfiniteRadioTracks();
        
        // Check if we got new tracks
        if (_currentIndex + 1 < _queue.length) {
          final nextIndex = _currentIndex + 1;
          await playTrack(
            _queue[nextIndex],
            queueContext: _queue,
            fromShuffle: _isShuffleEnabled,
            queueIndex: nextIndex,
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
    // If the user starts playback while we are restoring, their request wins.
    final requestId = _playRequestId;
    bool superseded() => _disposed || requestId != _playRequestId;

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

    if (queue.isEmpty || superseded()) {
      return;
    }

    final clampedIndex = state.currentQueueIndex.clamp(0, queue.length - 1);
    final track = queue[clampedIndex];

    // Set up track state WITHOUT auto-playing
    // This prevents unexpected audio on app restore
    _currentTrack = track;
    _currentTrackController.add(track);
    _resetPerTrackState(track);
    // Copy: restored lists may be fixed-length (toQueueTracks) and must not
    // be shared with the caller.
    _queue = List<JellyfinTrack>.of(queue);
    _currentIndex = clampedIndex;
    _queueController.add(List.from(_queue));
    _isCurrentTrackLocal = false;

    // Publish the restored track to the lock screen / CarPlay (paused). If
    // the audio handler isn't up yet, _initAudioHandler publishes it.
    unawaited(_publishMediaItem(track));
    _audioHandler?.updateNautuneQueue(_queue);

    // Begin-track bookkeeping (start time, Jellyfin start report, now
    // playing) is deferred to the first resume().
    _trackStartTime = null;
    _restoreBeginPending = true;
    _restoreSourcePending = false;

    final position = Duration(milliseconds: state.positionMs);
    _positionController.add(position);
    _lastPosition = position;

    // Prepare audio source without playing. Bounded so an unreachable server
    // can't hang app startup; on timeout the source is set lazily on resume.
    var sourceReady = false;
    try {
      final resolved = await _resolvePlaybackSource(track);
      if (superseded()) return;
      if (resolved != null) {
        _isCurrentTrackLocal = resolved.isLocalFile;
        _restorePlayMethod = resolved.playMethod;
        await _withPlayerLock(() => _player
            .setSource(_sourceFor(resolved.url, isLocalFile: resolved.isLocalFile))
            .timeout(_restoreSourceTimeout));
        sourceReady = true;
      }
    } on TimeoutException {
      debugPrint('⚠️ Restore: audio source not ready after '
          '${_restoreSourceTimeout.inSeconds}s - will load on first play');
    } catch (e) {
      debugPrint('⚠️ Failed to prepare audio source during restore: $e');
    }
    if (superseded()) return;
    _restoreSourcePending = !sourceReady;

    // Seek to saved position
    if (sourceReady && state.positionMs > 0) {
      try {
        await seek(position).timeout(_restoreSourceTimeout);
      } catch (e) {
        debugPrint('⚠️ Failed to seek during restore: $e');
      }
      if (superseded()) return;
      _positionController.add(position);
      _lastPosition = position;
    }

    // Always restore in paused state - user must explicitly resume
    // This prevents unexpected audio playback on app launch
    _playingController.add(false);

    // Update media controls to show paused state
    _audioHandler?.playbackState.add(
      audio_service.PlaybackState(
        controls: [
          audio_service.MediaControl.skipToPrevious,
          audio_service.MediaControl.play,
          audio_service.MediaControl.skipToNext,
        ],
        systemActions: const {
          audio_service.MediaAction.seek,
          audio_service.MediaAction.seekForward,
          audio_service.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: audio_service.AudioProcessingState.ready,
        playing: false,
        updatePosition: Duration(milliseconds: state.positionMs),
        speed: 1.0,
        queueIndex: clampedIndex,
      ),
    );
  }

  static const Duration _restoreSourceTimeout = Duration(seconds: 5);
  String _restorePlayMethod = 'DirectPlay';

  /// Resolve where [track] plays from, in playback priority order:
  /// downloaded file → audio cache → stream → asset/path override.
  /// Returns null if no source is available.
  Future<_ResolvedSource?> _resolvePlaybackSource(
    JellyfinTrack track, {
    String? sessionId,
  }) async {
    final (streamUrl, isDirectStream) = _getStreamUrl(track, sessionId: sessionId);

    // 1) Downloaded file (works in airplane mode!)
    final localPath = await _downloadService?.getLocalPath(track.id);
    if (localPath != null) {
      debugPrint('✅ Found local file: $localPath');
      return _ResolvedSource(
        url: localPath,
        isLocalFile: true,
        isDownloaded: true,
        isDirectStream: isDirectStream,
        streamUrl: streamUrl,
      );
    }

    // 2) Cached file (pre-cached during album playback)
    final cachedFile = await _audioCacheService.getCachedFile(track.id);
    if (cachedFile != null && await cachedFile.exists()) {
      debugPrint('✅ Found in cache: ${cachedFile.path}');
      return _ResolvedSource(
        url: cachedFile.path,
        isLocalFile: true,
        isDownloaded: false,
        isDirectStream: isDirectStream,
        streamUrl: streamUrl,
      );
    }

    // 3) Stream, based on quality preference
    if (streamUrl != null) {
      if (isDirectStream) {
        debugPrint('🎵 Streaming: Original quality (direct)');
      } else {
        debugPrint('🎵 Streaming: ${_streamingQuality.label}');
      }
      return _ResolvedSource(
        url: streamUrl,
        isLocalFile: false,
        isDownloaded: false,
        isDirectStream: isDirectStream,
        streamUrl: streamUrl,
      );
    }

    // 4) Asset path override (bundled asset or local file)
    final assetPath = track.assetPathOverride;
    if (assetPath != null) {
      debugPrint('🎵 Using asset path override: $assetPath');
      return _ResolvedSource(
        url: assetPath,
        isLocalFile: true,
        isDownloaded: false,
        isDirectStream: isDirectStream,
        streamUrl: streamUrl,
      );
    }
    return null;
  }

  /// audioplayers [Source] for a resolved URL/path.
  Source _sourceFor(String url, {required bool isLocalFile}) {
    if (url.startsWith('assets/')) {
      return AssetSource(url.substring('assets/'.length));
    }
    if (isLocalFile) return DeviceFileSource(url);
    return UrlSource(url);
  }

  /// Run [op] after any in-flight player source/resume operation finishes.
  Future<T> _withPlayerLock<T>(Future<T> Function() op) {
    final previous = _playerOpLock;
    final done = Completer<void>();
    _playerOpLock = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }

  String _playMethodFor(JellyfinTrack track, {required bool isLocal}) {
    if (isLocal) return 'DirectPlay';
    final (_, isDirectStream) = _getStreamUrl(track);
    return isDirectStream ? 'DirectStream' : 'Transcode';
  }

  // ========== PER-TRACK BOOKKEEPING ==========

  /// State that must be reset the moment the current track changes (before
  /// any await), so position ticks can't act on the previous track's state.
  void _resetPerTrackState(JellyfinTrack track) {
    _hasScrobbled = false;
    _lyricsPrefetched = false;
    _lastThresholdCheckMs = -1000; // let the first tick run the checks
    if (_loopState.hasMarkers || _loopState.isActive) {
      clearLoop(); // A-B loop markers belong to the previous track
    }
    _cachedDuration = track.duration;
    _durationController.add(track.duration);
  }

  /// Single place for everything that happens when [track] actually starts
  /// playing, regardless of how it started (playTrack, gapless swap,
  /// crossfade, or resuming a restored session).
  void _onTrackBegan(
    JellyfinTrack track, {
    String? playMethod,
    String? sessionId,
    bool countPlay = true,
    bool resetState = true,
    bool publishMediaItem = true,
  }) {
    // Jellyfin "stopped" for whatever was reported before (no-op if the
    // caller already closed it out).
    _reportOutgoingStopped();

    if (resetState) _resetPerTrackState(track);
    _trackStartTime = DateTime.now();
    // The player may know the real length better than metadata (and a
    // pre-loaded player's duration event fired before we attached).
    unawaited(_refreshDurationFromPlayer(track));

    if (countPlay) {
      _playStats.incrementPlayCount(track.id);
      unawaited(_savePlayStats());
    }

    unawaited(ListenBrainzService().submitNowPlaying(track));

    final reporting = _reportingService;
    if (reporting != null && track.serverUrl != null) {
      debugPrint('🎵 Reporting playback start to Jellyfin: ${track.name}');
      _reportedTrack = track;
      _enqueueReport(() => reporting.reportPlaybackStart(
            track,
            playMethod: playMethod ?? 'DirectPlay',
            sessionId: sessionId,
          ));
    }

    if (publishMediaItem) {
      unawaited(_publishMediaItem(track));
    }
  }

  /// Report "stopped" for the track whose start was last reported.
  void _reportOutgoingStopped({Duration? position}) {
    final track = _reportedTrack;
    if (track == null) return;
    _reportedTrack = null;
    final reporting = _reportingService;
    if (reporting == null) return;
    final stoppedAt = position ?? _lastPosition;
    _enqueueReport(() => reporting.reportPlaybackStopped(track, stoppedAt));
  }

  /// Run reporting calls strictly in order: a slow "stopped" for the old
  /// track must finish before the new track's "start" sets a new session id.
  void _enqueueReport(Future<void> Function() op) {
    _reportChain = _reportChain
        .then((_) => op().timeout(const Duration(seconds: 15)))
        .catchError((Object e) {
      debugPrint('📡 Playback report failed: $e');
    });
  }

  Future<void> _refreshDurationFromPlayer(JellyfinTrack track) async {
    try {
      final duration = await _player.getDuration();
      if (_disposed || _currentTrack?.id != track.id) return;
      if (duration != null && duration.inSeconds > 1) {
        _cachedDuration = duration;
        _durationController.add(duration);
      }
    } catch (e) {
      debugPrint('⚠️ Duration refresh failed: $e');
    }
  }

  Future<void> _publishMediaItem(JellyfinTrack track) async {
    final offlineArtUri = await _getOfflineArtworkUri(track.id);
    if (_disposed || _currentTrack?.id != track.id) return;
    _audioHandler?.updateNautuneMediaItem(track, offlineArtUri: offlineArtUri);
  }

  Future<void> playTrack(
    JellyfinTrack track, {
    List<JellyfinTrack>? queueContext,
    String? albumId,
    String? albumName,
    bool reorderQueue = false,
    bool fromShuffle = false,
    int? queueIndex,
  }) async {
    // Newest request wins: every await below re-checks this token.
    final requestId = ++_playRequestId;
    bool isStale() => _disposed || requestId != _playRequestId;

    // A crossfade in progress would swap players underneath this request.
    if (_isCrossfading) _cancelCrossfade();

    // Close out the OUTGOING track before switching, so its listening time
    // and Jellyfin "stopped" are credited to it rather than to [track].
    _recordActualListeningTime();
    _reportOutgoingStopped();
    _restoreBeginPending = false;
    _restoreSourcePending = false;

    _isShuffleEnabled = fromShuffle;
    _shuffleController.add(_isShuffleEnabled);

    // Cancel any in-flight waveform extraction from the previous track
    _waveformExtractionSub?.cancel();
    _waveformExtractionSub = null;

    // Queue + index are updated synchronously so rapid skips see them.
    if (queueContext != null) {
      final isInternalQueue = identical(queueContext, _queue);
      final List<JellyfinTrack> newQueue;
      if (reorderQueue) {
        newQueue = List<JellyfinTrack>.from(queueContext)
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
        // Copy: never alias (and later mutate) the caller's list.
        newQueue = List<JellyfinTrack>.of(queueContext);
      }
      final index = resolveQueueIndex<JellyfinTrack>(
        newQueue,
        track.id,
        (t) => t.id,
        requestedIndex: reorderQueue ? null : queueIndex,
        nearIndex: isInternalQueue ? _currentIndex : null,
      );
      if (index == -1) {
        _queue = <JellyfinTrack>[track];
        _currentIndex = 0;
      } else {
        _queue = newQueue;
        _currentIndex = index;
      }
    } else {
      _queue = <JellyfinTrack>[track];
      _currentIndex = 0;
    }

    _currentTrack = track;
    _currentTrackController.add(track);
    _resetPerTrackState(track);
    _analyzeTrackForVisualizer(track); // Configure visualizer for track

    _queueController.add(_queue);

    // Clear any pre-loaded track since queue changed
    _clearPreload();

    // Pre-warm album art for upcoming tracks in queue
    if (!_batterySaverMode) {
      _imagePrewarmService?.prewarmQueueImages(_queue, _currentIndex);
    }

    // Reset FFT URL tracking to ensure new track gets fresh FFT setup
    if (Platform.isIOS) {
      IOSFFTService.instance.resetUrl();
    }

    // CRITICAL: Ensure audio session is active before playing (iOS fix)
    // iOS can deactivate the session when app is in background or after interruptions
    await _ensureSessionActiveForPlayback();
    if (isStale()) return;

    // Update audio handler with current track metadata immediately
    // This is critical for Lock Screen to update BEFORE audio starts
    final offlineArtUri = await _getOfflineArtworkUri(track.id);
    if (isStale()) return;
    _audioHandler?.updateNautuneMediaItem(track, offlineArtUri: offlineArtUri);
    _audioHandler?.updateNautuneQueue(_queue);
    
    // Generate a session ID to link the stream and the reporting
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    // RESOLVE SOURCE BEFORE TOUCHING THE PLAYER
    // This minimizes "dead air" time which causes iOS background suspension
    final resolved = await _resolvePlaybackSource(track, sessionId: sessionId);
    if (isStale()) return;

    if (resolved == null) {
      throw PlatformException(
        code: 'no_source',
        message: 'Unable to play ${track.name}. File may be unavailable.',
      );
    }

    var activeUrl = resolved.url;
    final isLocalFile = resolved.isLocalFile;
    final isDirectStream = resolved.isDirectStream;
    final streamUrl = resolved.streamUrl;

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
      }).catchError((e) {
        debugPrint('Cache: Failed to cache current track: $e');
      }));
    }

    // NOW we touch the player (serialised with other requests).
    // We don't explicitly call stop() because setSource will handle it,
    // and we want to minimize the gap.
    Future<bool> applySourceAndPlay(String url) => _withPlayerLock(() async {
          if (isStale()) return false;
          await _player.setSource(_sourceFor(url, isLocalFile: isLocalFile));
          if (isStale()) return false;

          // Apply ReplayGain normalization
          final adjustedVolume = _volume * track.replayGainMultiplier;
          await _player.setVolume(adjustedVolume.clamp(0.0, 1.0));
          if (track.normalizationGain != null) {
            debugPrint('🔊 Applied ReplayGain: ${track.normalizationGain} dB');
          }

          await _player.resume();
          return !isStale();
        });

    String playMethod;
    var usedFallback = false;
    try {
      if (!await applySourceAndPlay(activeUrl)) return;
      playMethod = resolved.playMethod;
    } on PlatformException {
      if (isStale()) return;
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
          usedFallback = true;
          if (!await applySourceAndPlay(activeUrl)) return;
          playMethod = 'Transcode';
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }

    _lastPlayingState = true;

    // Per-track bookkeeping: start time, play count, now-playing, Jellyfin
    // start report (after the outgoing track's stop). Queue/loop/duration
    // state was already reset synchronously above.
    _onTrackBegan(
      track,
      playMethod: playMethod,
      sessionId: sessionId,
      resetState: false,
      publishMediaItem: false,
    );

    if (!usedFallback) {
      // iOS FFT: Use local file immediately, or cache streaming track first
      if (Platform.isIOS) {
        if (isLocalFile) {
          // Local file - start FFT immediately (foreground only)
          await _startIOSFFTFor('file://$activeUrl');
        } else {
          // Streaming - cache in background (same quality as playback), then start FFT
          unawaited(_cacheTrackForIOSFFT(track, activeUrl).catchError(
            (e) => debugPrint('🎵 iOS FFT cache failed: $e'),
          ));
        }
      }
      if (isStale()) return;

      // Waveform extraction: Extract for all tracks (local and streaming)
      if (WaveformService.instance.isAvailable && !_batterySaverMode) {
        if (isLocalFile) {
          // Local file - extract waveform directly if not already exists
          _extractWaveformForLocalFile(track, activeUrl);
        } else {
          // Streaming - cache first, then extract
          _cacheTrackForWaveform(track, activeUrl);
        }
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
    // Ensure OS has correct paused state with updated position so lock screen
    // controls remain interactive after pausing from the app
    await _audioHandler?.forceBroadcastCurrentState();
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
    await _ensureSessionActiveForPlayback();
    // Restored session whose source couldn't be prepared at startup
    // (e.g. server unreachable): load it now.
    if (_restoreSourcePending) {
      if (!await _prepareRestoredSource()) return;
    }
    await _resumeAndFadeIn();
    if (_restoreBeginPending) {
      _restoreBeginPending = false;
      final track = _currentTrack;
      if (track != null) _beginRestoredTrack(track);
    }
    await _stateStore.savePlaybackSnapshot(isPlaying: true);
    await _audioHandler?.forceBroadcastCurrentState();
  }

  /// Lazily set the source for a track restored from a previous launch.
  Future<bool> _prepareRestoredSource() async {
    final track = _currentTrack;
    if (track == null) return false;
    final requestId = _playRequestId;
    bool superseded() => _disposed || requestId != _playRequestId;
    try {
      final resolved = await _resolvePlaybackSource(track);
      if (superseded()) return false;
      if (resolved == null) {
        _playbackErrorController.add('Unable to play ${track.name}. File may be unavailable.');
        return false;
      }
      await _withPlayerLock(() => _player.setSource(
            _sourceFor(resolved.url, isLocalFile: resolved.isLocalFile),
          ));
      if (superseded()) return false;
      _isCurrentTrackLocal = resolved.isLocalFile;
      _restorePlayMethod = resolved.playMethod;
      _restoreSourcePending = false;
      if (_lastPosition > Duration.zero) {
        await _player.seek(_lastPosition);
      }
      return !superseded();
    } catch (e) {
      debugPrint('⚠️ Failed to load restored track: $e');
      _playbackErrorController.add('Unable to play ${track.name}.');
      return false;
    }
  }

  /// First resume of a track restored from a previous launch.
  ///
  /// The play count is NOT incremented: it was counted when the track
  /// originally started, and this is a continuation of that play. Listening
  /// time/history, the Jellyfin start report and "now playing" do run, since
  /// the previous launch never closed them out. If the restored position is
  /// already past the scrobble point, the previous launch scrobbled it, so it
  /// is not scrobbled again.
  void _beginRestoredTrack(JellyfinTrack track) {
    _onTrackBegan(
      track,
      playMethod: _restorePlayMethod,
      countPlay: false,
      resetState: false,
      publishMediaItem: true,
    );
    final duration = track.duration ?? _cachedDuration;
    if (duration != null &&
        duration > Duration.zero &&
        _lastPosition.inSeconds >= scrobbleThresholdSeconds(duration)) {
      _hasScrobbled = true;
    }
  }
  
  // Fade helpers
  Future<void> _fadeOutAndPause() async {
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;

    // Quick fade out (gentler: 400ms total, 20Hz update rate)
    const steps = 8;
    const stepDuration = Duration(milliseconds: 50);
    final startVolume = _volume;
    final currentMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
    final fadeTrack = _currentTrack;

    for (int i = 0; i < steps; i++) {
      // Abort fade if track changed mid-fade
      if (_currentTrack != fadeTrack) return;
      final vol = startVolume * (1.0 - ((i + 1) / steps));
      await _player.setVolume((vol * currentMultiplier).clamp(0.0, 1.0));
      await Future.delayed(stepDuration);
    }

    await _player.pause();
    await _player.setVolume((startVolume * currentMultiplier).clamp(0.0, 1.0)); // Restore for next play
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
    final currentMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;

    for (int i = 0; i <= steps; i++) {
      final vol = targetVolume * (i / steps);
      await _player.setVolume((vol * currentMultiplier).clamp(0.0, 1.0));
      await Future.delayed(stepDuration);
    }
  }
  
  Future<void> seek(Duration position) async {
    // Clamp position to valid range to prevent seeking beyond track bounds
    final duration = _cachedDuration ?? _currentTrack?.duration;
    final clampedPosition = duration != null
        ? Duration(milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds))
        : position;

    // Let the once-per-second threshold checks (preload, crossfade,
    // scrobble, lyrics) run on the next tick, including after backward seeks.
    _lastThresholdCheckMs = clampedPosition.inMilliseconds - 1000;

    // Update position immediately for responsive UI (before player confirms)
    _lastPosition = clampedPosition;
    // After a seek, the next periodic save should write the new position.
    _lastSavedPositionMs = null;
    _positionController.add(clampedPosition);

    // Perform the actual seek
    await _player.seek(clampedPosition);
    await _stateStore.savePlaybackSnapshot(position: clampedPosition);

    // Sync iOS FFT shadow player position after seek
    if (Platform.isIOS) {
      IOSFFTService.instance.syncPosition(clampedPosition.inMilliseconds / 1000.0);
    }
  }

  Future<void> skipToNext() async {
    HapticService.mediumTap();
    // Record actual listening time before skipping
    _recordActualListeningTime();

    // Stop FFT before switching tracks to prevent concurrent shadow players
    if (Platform.isIOS) {
      await IOSFFTService.instance.stopCapture();
    }

    try {
      if (_currentIndex < _queue.length - 1) {
        _currentIndex++;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: _currentIndex,
        );
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        _currentIndex = 0;
        await playTrack(
          _queue[0],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: 0,
        );
      } else if (_infiniteRadioEnabled) {
        await _checkInfiniteRadio();
        if (_currentIndex < _queue.length - 1) {
          _currentIndex++;
          await playTrack(
            _queue[_currentIndex],
            queueContext: _queue,
            fromShuffle: _isShuffleEnabled,
            queueIndex: _currentIndex,
          );
        }
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

    // Stop FFT before switching tracks to prevent concurrent shadow players
    if (Platform.isIOS) {
      await IOSFFTService.instance.stopCapture();
    }

    try {
      if (_currentIndex > 0) {
        _currentIndex--;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: _currentIndex,
        );
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        _currentIndex = _queue.length - 1;
        await playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: _currentIndex,
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
  Future<void> _cacheTrackForIOSFFT(JellyfinTrack track, String streamUrl) async {
    if (!Platform.isIOS) return;

    final trackId = track.id;

    // Check for downloaded file first
    final localPath = await _downloadService?.getLocalPath(trackId);
    if (localPath != null) {
      debugPrint('🎵 iOS FFT: Using downloaded file for ${track.name}');
      await IOSFFTService.instance.setAudioUrl('file://$localPath');
      
      // Still start capture if track hasn't changed
      if (_currentTrack?.id == trackId && _isAppInForeground) {
        await IOSFFTService.instance.startCapture();
      }
      return;
    }

    // Check for cached file
    final cachedFile = await _audioCacheService.getCachedFile(trackId);
    if (cachedFile != null && await cachedFile.exists()) {
      debugPrint('🎵 iOS FFT: Using cached file for ${track.name}');
      await IOSFFTService.instance.setAudioUrl('file://${cachedFile.path}');
      
      // Still start capture if track hasn't changed
      if (_currentTrack?.id == trackId && _isAppInForeground) {
        await IOSFFTService.instance.startCapture();
      }
      return;
    }

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

      // Re-check staleness after await
      if (_currentTrack?.id != trackId) return;

      // Sync to current playback position BEFORE starting capture
      // Use milliseconds for precision
      final currentPosMs = _lastPosition.inMilliseconds.toDouble() / 1000.0;
      await IOSFFTService.instance.syncPosition(currentPosMs);

      // Re-check staleness after await. Don't start the shadow player while
      // backgrounded; the URL is set so it resumes on return to foreground.
      if (_currentTrack?.id != trackId || !_isAppInForeground) return;

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

  /// Cache streaming track for waveform extraction.
  /// Dedup is handled by AudioCacheService (caching) and WaveformService (extraction).
  void _cacheTrackForWaveform(JellyfinTrack track, String streamUrl) {
    unawaited(_cacheTrackForWaveformAsync(track, streamUrl));
  }

  Future<void> _cacheTrackForWaveformAsync(JellyfinTrack track, String streamUrl) async {
    final trackId = track.id;

    try {
      // Skip if waveform already exists
      final hasWaveform = await WaveformService.instance.hasWaveform(trackId);
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
    } catch (e) {
      debugPrint('⚠️ Waveform: Error caching for extraction: $e');
    }
  }

  /// Extract waveform directly from a local file (downloaded or cached)
  void _extractWaveformForLocalFile(JellyfinTrack track, String filePath) {
    final trackId = track.id;

    WaveformService.instance.hasWaveform(trackId).then((hasWaveform) async {
      if (hasWaveform) {
        debugPrint('🌊 Waveform: Already exists for ${track.name}');
        return;
      }

      // Cancel any previous waveform extraction and await full teardown
      // so the stream can never emit after reassignment.
      await _waveformExtractionSub?.cancel();
      _waveformExtractionSub = null;

      debugPrint('🌊 Waveform: Extracting for local file: ${track.name}');
      _waveformExtractionSub = WaveformService.instance.extractWaveform(trackId, filePath).listen(
        (_) {
          // Progress updates (silently consume)
        },
        onDone: () {
          debugPrint('🌊 Waveform: Extraction complete for ${track.name}');
          _waveformExtractionSub = null;
        },
        onError: (e) {
          debugPrint('⚠️ Waveform: Error extracting from local file: $e');
          _waveformExtractionSub = null;
        },
      );
    }).catchError((e) {
      debugPrint('⚠️ Waveform: Error checking waveform existence: $e');
    });
  }

  Future<void> stop() async {
    // Supersede any in-flight playTrack/gapless request so it can't resume
    // audio after we stop.
    _playRequestId++;
    _restoreBeginPending = false;
    _restoreSourcePending = false;
    if (_isCrossfading) _cancelCrossfade();

    // Record actual listening time before stopping
    _recordActualListeningTime();

    // Report stop to Jellyfin (only for tracks whose start was reported).
    // Queued behind/ahead of other reports so it can't clear the session id
    // of a track started after it. Position captured before stopping.
    _reportOutgoingStopped();

    // 1. Stop audio immediately
    await _player.stop();

    // Stop FFT capture
    if (Platform.isIOS) {
      await IOSFFTService.instance.stopCapture();
    }

    // 2. CLEAR persistence so app starts fresh on next launch
    try {
      debugPrint('🧹 Clearing playback state on stop');
      await _stateStore.clearPlaybackData();
    } catch (e) {
      debugPrint('Error clearing playback state: $e');
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

    // Ensure iOS media controls reflect stopped state
    await _audioHandler?.forceBroadcastCurrentState();

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
          queueIndex: _currentIndex,
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

  /// Insert a track at a specific index in the queue (used for undo)
  void insertIntoQueue(int index, JellyfinTrack track) {
    if (index < 0) index = 0;
    if (index > _queue.length) index = _queue.length;

    _queue.insert(index, track);

    // Adjust current index if insertion is before or at current position
    if (index <= _currentIndex) {
      _currentIndex++;
    }

    _clearPreload();
    _queueController.add(_queue);
    _audioHandler?.updateNautuneQueue(_queue);

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
      queueIndex: index,
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
    // Wait for any in-flight fetch to complete first
    if (_infiniteRadioFetchCompleter != null) {
      await _infiniteRadioFetchCompleter!.future;
    }
    if (!_infiniteRadioEnabled) return;
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
    if (_infiniteRadioFetchCompleter != null || _jellyfinService == null || _currentTrack == null) {
      return;
    }

    _infiniteRadioFetchCompleter = Completer<void>();

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
      var newTracks = mixTracks.where((t) => !existingIds.contains(t.id)).toList();

      // Fallback: if all duplicates, try with a random different track from queue
      if (newTracks.isEmpty && _queue.length > 1) {
        debugPrint('📻 Infinite Radio: All duplicates, trying different seed track...');

        // Pick a random track from the queue that has a different albumId
        final currentAlbumId = _currentTrack!.albumId;
        final differentAlbumTracks = _queue.where((t) => t.albumId != currentAlbumId).toList();
        final seedTrack = differentAlbumTracks.isNotEmpty
            ? differentAlbumTracks[Random().nextInt(differentAlbumTracks.length)]
            : _queue[Random().nextInt(_queue.length)];

        final fallbackTracks = await _jellyfinService!.getInstantMix(
          itemId: seedTrack.id,
          limit: 20,
        );
        newTracks = fallbackTracks.where((t) => !existingIds.contains(t.id)).toList();
      }

      if (newTracks.isEmpty) {
        debugPrint('📻 Infinite Radio: No new tracks found after fallback');
        return;
      }

      // Append new tracks to queue
      _queue.addAll(newTracks);

      debugPrint('📻 Infinite Radio: Added ${newTracks.length} tracks to queue (total: ${_queue.length})');

      // Notify UI and audio handler of queue change
      _queueController.add(List.from(_queue));
      _audioHandler?.updateNautuneQueue(_queue);

      // Save updated queue
      unawaited(_stateStore.savePlaybackSnapshot(
        queue: _queue,
        currentQueueIndex: _currentIndex,
      ));

    } catch (e) {
      debugPrint('📻 Infinite Radio: Failed to fetch tracks: $e');
    } finally {
      _infiniteRadioFetchCompleter!.complete();
      _infiniteRadioFetchCompleter = null;
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

    // Double-buffer: write to current buffer, emit it, then swap for next frame
    final writeBuffer = _useVizBufferA ? _vizBufferA : _vizBufferB;

    for (int index = 0; index < _visualizerBarCount; index++) {
      // Different frequencies for bass/mid/treble regions
      final freq = index < 8 ? 0.3 : (index < 16 ? 0.7 : 1.2);
      final wave = (sin(t * freq + index * 0.45) + 1) * 0.5;
      final ripple = (sin((t * freq * 0.6) + index) + 1) * 0.25;

      // Bass region (0-7) gets genre-based emphasis
      final bassBoost = index < 8 ? _bassEmphasis * 0.4 : 0.0;
      final value = ((wave * 0.7) + (ripple * 0.3) + bassBoost) * volumeMultiplier;
      writeBuffer[index] = value.clamp(0.0, 1.0);
    }

    if (hasVisualizerListeners) {
      // Emit buffer reference directly -- next frame writes to the other buffer
      _visualizerController.add(writeBuffer);
      _useVizBufferA = !_useVizBufferA;
    }

    // Extract frequency bands with genre emphasis
    if (hasFrequencyListeners) {
      // Calculate bass (indices 0-7)
      double bassSum = 0.0;
      for (int i = 0; i < 8; i++) {
        bassSum += writeBuffer[i];
      }
      final rawBass = bassSum / 8;
      final bass = (rawBass + _bassEmphasis * 0.2).clamp(0.0, 1.0);

      // Calculate mid (indices 8-15)
      double midSum = 0.0;
      for (int i = 8; i < 16; i++) {
        midSum += writeBuffer[i];
      }
      final mid = (midSum / 8).clamp(0.0, 1.0);

      // Calculate treble (indices 16-23)
      double trebleSum = 0.0;
      for (int i = 16; i < 24; i++) {
        trebleSum += writeBuffer[i];
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
      _visualizerController.add(_idleVisualizerFrame);
    }
    if (_frequencyBandsController.hasListener) {
      _frequencyBandsController.add(FrequencyBands.zero);
    }
  }

  void _startPositionSaving() {
    _positionSaveTimer?.cancel();
    // Normal: 15s (was 5s). Battery saver: 30s. Crash-resume granularity
    // of 15s is acceptable for music and saves ~66% of disk writes on long
    // playback sessions.
    _lastSavedPositionMs = null;
    final interval = _batterySaverMode
        ? const Duration(seconds: 30)
        : const Duration(seconds: 15);
    _positionSaveTimer = Timer.periodic(interval, (_) {
      _saveCurrentPosition();
    });
  }
  
  void _stopPositionSaving() {
    _positionSaveTimer?.cancel();
  }
  
  /// Record actual listening time for the current track to analytics.
  /// Call this when: track ends, user skips, user stops, new track starts.
  void _recordActualListeningTime() {
    final track = _currentTrack;
    final startTime = _trackStartTime;

    // Only record if we have a valid track and start time
    // _trackStartTime is nulled after recording, preventing double-recording
    if (track == null || startTime == null) return;

    // Clear start time immediately to prevent duplicate recording
    _trackStartTime = null;

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
  }

  Future<void> _saveCurrentPosition() async {
    if (_currentTrack == null) return;
    // Skip entirely when not playing — paused/buffering snapshots aren't
    // useful and the background lifecycle already calls saveFullPlaybackState()
    // on suspend.
    if (!isPlaying) return;

    final position = await _player.getCurrentPosition();
    if (position == null) return;

    // Listen-time accounting (uses real elapsed time, not the fixed tick).
    final now = DateTime.now();
    final elapsed = _lastListenTimeRecord != null
        ? now.difference(_lastListenTimeRecord!)
        : (_batterySaverMode
            ? const Duration(seconds: 30)
            : const Duration(seconds: 15));
    _lastListenTimeRecord = now;
    _playStats.addListenTime(_currentTrack!.id, elapsed);
    _accumulatedTime += elapsed;
    if (_accumulatedTime.inSeconds >= 60) {
      _accumulatedTime = Duration.zero;
      unawaited(_savePlayStats());
    }

    _lastPosition = position;

    // Skip the disk snapshot if position hasn't meaningfully advanced since
    // the last save (e.g. user paused right after a save, or the player is
    // momentarily stalled). Threshold: 1s.
    final positionMs = position.inMilliseconds;
    if (_lastSavedPositionMs != null &&
        (positionMs - _lastSavedPositionMs!).abs() < 1000) {
      return;
    }
    _lastSavedPositionMs = positionMs;

    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: position,
      queue: null,
      currentQueueIndex: _currentIndex,
      isPlaying: isPlaying,
    );
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
    if (_isLoopSeeking) return; // Prevent seek thrashing

    // Check if we've passed the loop end point
    if (position >= _loopState.end!) {
      _isLoopSeeking = true;
      debugPrint('🔁 Loop: Reached end, seeking to start');
      unawaited(seek(_loopState.start!).whenComplete(() {
        _isLoopSeeking = false;
      }));
    }
  }

  // ========== CROSSFADE METHODS ==========

  /// Check if we should trigger crossfade based on current position
  Future<void> _checkCrossfadeTrigger(Duration position) async {
    if (!_crossfadeEnabled || _isCrossfading || _crossfadeDurationSeconds == 0) {
      return;
    }
    // Repeat-one replays the same track; crossfading into itself is wrong and
    // the completion handler already restarts it.
    if (_repeatMode == RepeatMode.one) return;
    if (_isTransitioning) return;

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _cachedDuration;
    if (duration == null || _currentTrack == null) return;

    // Calculate trigger point (crossfade duration before track ends)
    final triggerPoint = duration - Duration(seconds: _crossfadeDurationSeconds);
    
    // Don't trigger if we're not near the end
    if (position < triggerPoint) return;

    // Check if next track exists
    if (_queue.isEmpty) return;
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _queue.length && _repeatMode != RepeatMode.all) return;

    // Wrap to 0 if repeating (safe because _queue is non-empty)
    final resolvedIndex = nextIndex < _queue.length ? nextIndex : 0;
    final nextTrack = _queue[resolvedIndex];

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
    _startCrossfade(nextTrack, resolvedIndex);
  }

  /// Start crossfade to next track
  Future<void> _startCrossfade(JellyfinTrack nextTrack, int nextIndex) async {
    if (_isCrossfading || _crossfadePlayer == null) return;
    _isCrossfading = true;
    // Claim the player; a user-initiated playTrack during the fade wins.
    final requestId = ++_playRequestId;

    try {
      // Stop any existing playback in crossfade player
      await _crossfadePlayer!.stop();

      // Prepare next track
      final prepared = await _prepareTrackForCrossfade(nextTrack);
      if (!prepared) {
        throw Exception('Failed to prepare next track');
      }

      // Execute the crossfade
      await _executeCrossfade(nextTrack, nextIndex, requestId);

    } catch (e) {
      debugPrint('❌ Crossfade failed: $e');
      final wasOurs = _playRequestId == requestId;
      _cancelCrossfade();
      if (wasOurs && !_disposed) {
        // Restore the outgoing track's volume in case we were mid-fade.
        unawaited(_applyUserVolumeToPlayer());
        // The outgoing player may already have completed while the
        // completion handler was suppressed for the crossfade: advance now.
        if (_player.state == PlayerState.completed && !_isTransitioning) {
          unawaited(_gaplessTransition());
        }
      }
    }
  }

  /// Prepare next track for crossfade
  Future<bool> _prepareTrackForCrossfade(JellyfinTrack track) async {
    if (_crossfadePlayer == null) return false;

    try {
      // Check for local file first
      final localPath = await _downloadService?.getLocalPath(track.id);
      if (localPath != null) {
        await _crossfadePlayer!.setSourceDeviceFile(localPath);
        _crossfadeTrackIsLocal = true;
        debugPrint('✅ Crossfade: loaded local file');
        return true;
      }
      
      // Fall back to streaming
      final downloadUrl = track.downloadUrl(_jellyfinService?.baseUrl, _jellyfinService?.token);
      await _crossfadePlayer!.setSourceUrl(downloadUrl);
      _crossfadeTrackIsLocal = false;
      debugPrint('✅ Crossfade: loaded stream');
      return true;
    } catch (e) {
      debugPrint('❌ Crossfade prep failed: $e');
      return false;
    }
  }

  /// Execute the crossfade (Concurrent overlap)
  Future<void> _executeCrossfade(
    JellyfinTrack nextTrack,
    int nextIndex,
    int requestId,
  ) async {
    if (_crossfadePlayer == null) return;
    bool aborted() =>
        _disposed || !_isCrossfading || requestId != _playRequestId;

    final steps = 25; // More steps for smoother concurrent transition
    final stepDuration = Duration(milliseconds: (_crossfadeDurationSeconds * 1000) ~/ steps);
    // ReplayGain for each side of the fade
    final outMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
    final inMultiplier = nextTrack.replayGainMultiplier;

    // Start the next track at volume 0.0 immediately
    await _crossfadePlayer!.setVolume(0.0);
    if (aborted()) return;
    await _crossfadePlayer!.resume();

    // Concurrent Fade loop
    for (int i = 0; i <= steps; i++) {
      if (aborted() || _crossfadePlayer == null) break;

      final progress = i / steps;
      // Quadratic curves for natural logarithmic volume perception
      final fadeOut = 1.0 - (progress * progress);
      final fadeIn = progress * progress;

      // Update both volumes simultaneously
      unawaited(_player.setVolume((_volume * fadeOut * outMultiplier).clamp(0.0, 1.0)));
      unawaited(_crossfadePlayer!.setVolume((_volume * fadeIn * inMultiplier).clamp(0.0, 1.0)));

      if (i < steps) {
        await Future.delayed(stepDuration);
      }
    }

    // Cancelled (e.g. user picked another track): the new request owns the
    // main player now — don't stop it or swap players under it.
    if (aborted()) {
      if (!_disposed) await _crossfadePlayer?.stop();
      return;
    }

    // Complete the transition (stops the faded-out old player)
    await _completeCrossfadeTransition(nextTrack, nextIndex);
  }

  /// Complete crossfade and switch to next track
  Future<void> _completeCrossfadeTransition(JellyfinTrack nextTrack, int nextIndex) async {
    if (_crossfadePlayer == null) return;

    // Close out the outgoing track (listening time + Jellyfin "stopped")
    // before any state switches to the new one.
    _recordActualListeningTime();
    _reportOutgoingStopped();

    // Stop old main player (already faded out)
    await _player.stop();
    await _player.setVolume(_volume); // Reset volume for next use

    // SWAP: crossfade player becomes the new main player
    await _detachListeners();

    // Update AudioHandler to listen to the crossfade player (now main)
    _audioHandler?.updatePlayer(_crossfadePlayer!);

    // Swap the references
    final oldPlayer = _player;
    _player = _crossfadePlayer!;
    _crossfadePlayer = oldPlayer; // Reuse old player for next crossfade

    // Re-attach listeners to the new main player
    _attachPlayerListeners(_player);

    // The queue may have been edited during the fade; re-resolve the slot.
    final resolvedIndex = resolveQueueIndex<JellyfinTrack>(
      _queue,
      nextTrack.id,
      (t) => t.id,
      requestedIndex: nextIndex,
      nearIndex: _currentIndex,
    );

    // Update track info
    if (resolvedIndex != -1) _currentIndex = resolvedIndex;
    _currentTrack = nextTrack;
    _currentTrackController.add(_currentTrack);
    _isCurrentTrackLocal = _crossfadeTrackIsLocal;
    _analyzeTrackForVisualizer(nextTrack);

    // Explicitly emit playing state
    _playingController.add(true);
    _lastPlayingState = true;

    _isCrossfading = false;
    _clearPreload();

    // Per-track bookkeeping (scrobble/history/report/duration/loop/media item)
    _onTrackBegan(
      nextTrack,
      playMethod: _crossfadeTrackIsLocal ? 'DirectPlay' : 'DirectStream',
    );

    // Force OS media controls update
    await _audioHandler?.forcePlayingState();

    // Keep the FFT shadow player on the right track (foreground only).
    if (Platform.isIOS) {
      try {
        await IOSFFTService.instance.stopCapture();
        IOSFFTService.instance.resetUrl();
        final (streamUrl, _) = _getStreamUrl(nextTrack);
        if (streamUrl != null) {
          unawaited(_cacheTrackForIOSFFT(nextTrack, streamUrl).catchError(
            (e) => debugPrint('🎵 iOS FFT cache (crossfade) failed: $e'),
          ));
        }
      } catch (e) {
        debugPrint('⚠️ FFT restart after crossfade failed: $e');
      }
    }

    unawaited(_stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: Duration.zero,
      queue: _queue,
      currentQueueIndex: _currentIndex,
      isPlaying: true,
    ));

    debugPrint('✅ Crossfade complete → ${nextTrack.name}');
  }

  // ========== PRE-LOADING METHODS FOR GAPLESS PLAYBACK ==========

  /// Check if we should pre-load the next track (when current track reaches 70%)
  Future<void> _checkPreloadTrigger(Duration position) async {
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
  Future<void> _checkLyricsPrefetch(Duration position) async {
    if (_batterySaverMode) return;
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
  Future<void> _checkListenBrainzScrobble(Duration position) async {
    if (_batterySaverMode) return;
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

      Future<bool> trySetAssetPathOverride(String? assetPath) async {
        if (assetPath == null) return false;
        try {
          if (assetPath.startsWith('assets/')) {
            // Flutter bundled asset
            final normalized = assetPath.substring('assets/'.length);
            await _nextPlayer.setSource(AssetSource(normalized));
          } else {
            // Local file path (e.g., Essential Mix download)
            await _nextPlayer.setSource(DeviceFileSource(assetPath));
          }
          return true;
        } on PlatformException {
          return false;
        }
      }

      bool loaded = false;
      bool isLocal = false;

      // Try local file first (downloaded)
      final localPath = await _downloadService?.getLocalPath(track.id);
      if (localPath != null) {
        if (await trySetSource(localPath, isFile: true)) {
          loaded = true;
          isLocal = true;
          debugPrint('✅ Pre-loaded from local file: ${track.name}');
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
        } else if (await trySetAssetPathOverride(track.assetPathOverride)) {
          loaded = true;
          isLocal = true; // Asset/local files are local
          debugPrint('✅ Pre-loaded from asset path override: ${track.name}');
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
      if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
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
    unawaited(_nextPlayer.stop());
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
    _sleepTimerController.add(_sleepTimeRemaining);

    debugPrint('😴 Sleep timer started: ${duration.inMinutes} minutes');

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Pause countdown when playback is paused (saves CPU, prevents inaccurate timing)
      if (_player.state != PlayerState.playing) return;

      _sleepTimeRemaining -= const Duration(seconds: 1);
      _sleepTimerController.add(_sleepTimeRemaining);

      // Fade out over the last 30 seconds, from the user's current volume
      // (apply ReplayGain normalization). [_volume] itself is never changed.
      final fadedVolume = sleepTimerFadeVolume(
        userVolume: _volume,
        remaining: _sleepTimeRemaining,
      );
      if (fadedVolume != null) {
        _sleepFadeApplied = true;
        final replayGainMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
        _player.setVolume((fadedVolume * replayGainMultiplier).clamp(0.0, 1.0));
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

    // Only undo the fade if this timer actually lowered the player volume.
    // The user's volume (_volume) was never modified, so re-apply it.
    if (_sleepFadeApplied) {
      _sleepFadeApplied = false;
      unawaited(_applyUserVolumeToPlayer());
    }

    debugPrint('😴 Sleep timer cancelled');
  }

  /// Fade out volume and stop playback
  Future<void> _fadeOutAndStop() async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimeRemaining = Duration.zero;
    _sleepTracksRemaining = 0;
    _isSleepTimerByTracks = false;
    _sleepTimerController.add(Duration.zero);

    // Final fade to zero and pause (apply ReplayGain)
    final replayGainMultiplier = _currentTrack?.replayGainMultiplier ?? 1.0;
    await _player.setVolume((0.0 * replayGainMultiplier).clamp(0.0, 1.0));
    await pause();
    _sleepFadeApplied = false;

    // Restore the player to the user's volume for next session (pause()
    // already does this; repeat after a beat in case the fade raced it).
    await Future.delayed(const Duration(milliseconds: 500));
    if (!_disposed && !isPlaying && (_currentTrack != null || _queue.isNotEmpty)) {
      await _applyUserVolumeToPlayer();
    }

    debugPrint('😴 Sleep timer: Playback stopped, volume restored to $_volume');
  }

  void dispose() {
    // Set flag FIRST: player listener callbacks check this to short-circuit
    // before touching controllers that are about to close below. Without it,
    // the unawaited _detachListeners() race would let a queued onPositionChanged
    // call _positionController.add() after close() and throw "Bad state".
    _disposed = true;
    _positionSaveTimer?.cancel();
    _crossfadeTimer?.cancel();
    _sleepTimer?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _waveformExtractionSub?.cancel();
    _connectivitySubscription?.cancel();
    unawaited(_detachListeners());
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
    _loopStateController.close();
    _playbackErrorController.close();
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

/// Where a track will be played from (see `_resolvePlaybackSource`).
class _ResolvedSource {
  const _ResolvedSource({
    required this.url,
    required this.isLocalFile,
    required this.isDownloaded,
    required this.isDirectStream,
    required this.streamUrl,
  });

  final String url;
  final bool isLocalFile;
  final bool isDownloaded;
  final bool isDirectStream;
  final String? streamUrl;

  /// Jellyfin PlayMethod for reporting.
  String get playMethod =>
      isDownloaded ? 'DirectPlay' : (isDirectStream ? 'DirectStream' : 'Transcode');
}

/// Network type for auto quality selection
enum _NetworkType {
  wifi,     // WiFi or Ethernet - use original quality
  cellular, // Mobile data - use normal quality (192kbps)
  slow,     // Unknown/slow - use low quality (128kbps)
}
