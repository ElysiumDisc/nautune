import 'dart:async';
import 'dart:io';
import 'dart:math' show Random, sin;
import 'dart:ui' show AppLifecycleState;
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import 'audio_cache_service.dart';
import 'audio_handler.dart';
import 'download_service.dart';
import 'engine/engine_player.dart';
import 'essential_mix_service.dart';
import 'haptic_service.dart';
import 'image_prewarm_service.dart';
import 'listening_analytics_service.dart';
import 'lastfm_service.dart';
import 'listenbrainz_service.dart';
import 'lyrics_service.dart';
import 'playback_logic.dart';
import 'playback_reporting_service.dart';
import 'playback_state_store.dart';
import 'power_mode_service.dart';
import '../models/playback_state.dart';
import '../models/replay_gain_mode.dart';
import '../models/transcode_codec.dart';
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

/// Current track and playing flag, without position (see
/// [AudioPlayerService.trackPlayingStream]).
typedef TrackPlayingState = ({JellyfinTrack? track, bool isPlaying});

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

  /// Main player. Gapless: the next track is queued on this same player
  /// ([EnginePlayer.appendNext]) and starts with no gap.
  EnginePlayer _player = _createPlayer();

  /// Upper bound for preparing a source (AVPlayerItem readyToPlay). Also keeps
  /// [_withPlayerLock] from being held forever if the native call never
  /// returns.
  static const Duration _sourceLoadTimeout = Duration(seconds: 30);

  /// just_audio player behind [EnginePlayer]. Its position stream ticks
  /// every 200 ms on a Dart timer, so it keeps running with the screen
  /// locked (pre-load, crossfade, scrobbling, A-B loop, Jellyfin progress).
  static EnginePlayer _createPlayer() => EnginePlayer();

  StreamSubscription<void>? _advanceSub;
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

  /// Queue order before shuffling, so turning shuffle off can restore it.
  /// Null when the order isn't known (e.g. a shuffled session restored
  /// after a relaunch).
  List<JellyfinTrack>? _unshuffledQueue;
  bool _hasRestored = false;
  PlaybackState? _pendingState;

  // Track if current playback is from local file (download or cache)
  bool _isCurrentTrackLocal = false;

  // Cancellable waveform extraction subscription
  StreamSubscription? _waveformExtractionSub;

  // Pre-loading support for gapless playback
  JellyfinTrack? _preloadedTrack;
  _ResolvedSource? _preloadedSource;
  /// Queue slot of [_preloadedTrack] (may skip ahead offline).
  int? _preloadedIndex;
  bool _isPreloading = false;
  // Bumped by _clearPreload so an in-flight pre-load can't publish a track
  // (or a source) that was invalidated while it was loading.
  int _preloadGeneration = 0;
  String? _preloadingTrackId;
  bool _gaplessPlaybackEnabled = true;

  // Audio cache service for pre-caching album tracks
  final AudioCacheService _audioCacheService = AudioCacheService.instance;

  // Image pre-warm service for pre-caching album art
  ImagePrewarmService? _imagePrewarmService;

  // Lyrics service for pre-fetching lyrics
  LyricsService? _lyricsService;
  LyricsService? get lyricsService => _lyricsService;
  bool _lyricsPrefetched = false;

  // Play-count / scrobble tracking. Both fire once the track has actually been
  // listened to for the scrobble threshold (not when it starts, and not by
  // seeking past the threshold).
  bool _hasScrobbled = false;
  bool _playCountPending = false;
  final ListenedTimeTracker _listenedTime = ListenedTimeTracker();
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
  // Request id of the playTrack still resolving/loading its source (null
  // when none). While set, pause/seek apply to the incoming track and a
  // racing gapless advance must not pick a track of its own.
  int? _playInFlight;
  // stop() is running (it clears the queue after its awaits).
  bool _stopping = false;
  // Serialises player source/resume operations across overlapping requests.
  Future<void> _playerOpLock = Future<void>.value();
  // Request id of the operation holding [_playerOpLock] (null when free).
  int? _playerOpLockOwner;
  // Non-null while a source is being prepared on the main player. Seeks are
  // deferred meanwhile: AVPlayerItem raises an exception when asked to seek
  // before it is readyToPlay.
  Object? _sourceLoadToken;
  // Seek requested while the source was loading; applied once it is ready.
  Duration? _pendingSeek;
  // pause() arrived while the source was loading: load it, don't start it.
  bool _pauseRequestedDuringLoad = false;
  // Bumped by every pause, so a resume that had to load its track first can
  // tell it was paused (or the headphones were unplugged) meanwhile.
  int _pauseSerial = 0;
  // Bumped by every fade-in/out so an older fade stops touching the volume
  // (and a fade-out doesn't pause after the user already pressed play).
  int _fadeGeneration = 0;
  // Where the main player's current source came from (for FFT / caching).
  String? _currentSourceUrl;
  bool _currentSourceIsLocal = false;
  // Serialises playback start/stop reports so a slow "stopped" for the old
  // track can't null the session id of the track that started after it.
  Future<void> _reportChain = Future<void>.value();
  // Track whose playback start was last reported to Jellyfin (null once its
  // stop has been reported).
  JellyfinTrack? _reportedTrack;

  // "Deferred" track: the current track is shown but hasn't started playing
  // (session restore, paused while loading, failed to load, sleep timer
  // stopped at a track boundary). Begin-track bookkeeping runs on the first
  // resume.
  bool _restoreBeginPending = false;
  // Whether that deferred begin counts as a new play (false for a restored
  // session, which was counted when it originally started).
  bool _restoreCountsPlay = false;
  String? _restoreSessionId;
  // The deferred track's source isn't loaded into the player yet; load it on
  // resume (or in the background after a session restore).
  bool _restoreSourcePending = false;
  Future<bool>? _restorePrepareFuture;

  // Audio interruptions (phone calls, Siri, other apps)
  bool _wasPlayingBeforeInterruption = false;
  bool _isDucked = false;

  // Crossfade support
  EnginePlayer? _crossfadePlayer;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  bool _isCrossfading = false;
  // The crossfade player's source is being prepared; stopping it now would
  // reset the item under the pending native call.
  bool _crossfadeLoading = false;

  // Upcoming-track pre-cache, started a few seconds after a track begins so
  // it doesn't compete with the new stream's initial buffering.
  Timer? _preCacheTimer;

  // FFT consumers currently on screen (see retainVisualizer): every
  // BaseVisualizer and the Essential Mix screen retain/release.
  int _visualizerViewers = 0;
  // A visualizer appeared while paused: start FFT on the next resume().
  bool _fftStartOnResume = false;
  // URL this service last pointed the FFT shadow player at.
  String? _fftUrl;

  // Mid-stream stall recovery (see _recoverFromStall). Checked by a
  // periodic timer while playing: the position stream drops repeated
  // positions, so a frozen position never shows up there.
  final PlaybackStallDetector _stallDetector = PlaybackStallDetector();
  Timer? _stallTimer;
  int _stallRecoveries = 0;
  bool _stallRecoveryInFlight = false;
  static const int _maxStallRecoveriesPerTrack = 3;
  StreamSubscription<EnginePlaybackError>? _playerErrorSub;

  // Whether the device has a network transport (from ConnectivityService).
  // While it hasn't, buffering is an outage to wait out, not a stall.
  bool _networkAvailable = true;

  // A reload during a network outage failed while playback was wanted: the
  // track (by id) resumes by itself once the connection is back (see
  // _armResumeAfterOutage). Cleared by any user play/pause/track change.
  String? _resumeAfterOutageTrackId;
  DateTime? _outageSince;
  Timer? _outageRetryTimer;
  int _outageRetryAttempt = 0;
  static const Duration _maxOutageWait = Duration(minutes: 30);

  // _gaplessTransition is running (including its awaits before
  // _isTransitioning is set): a second one would advance twice.
  bool _advanceInFlight = false;

  // Bumped when a new queue replaces the current one (user play of another
  // list, reorder, stop, restore) — not for advances within the same queue,
  // which copy the list. Infinite Radio drops results for a replaced queue.
  int _queueGeneration = 0;

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
  // playTrack switched _currentTrack but the new source isn't loaded yet:
  // _lastPosition still comes from the outgoing track's player.
  bool _positionFromPreviousTrack = false;
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

  ReplayGainMode _replayGainMode = ReplayGainMode.track;
  double _replayGainPreampDb = 0;

  ReplayGainMode get replayGainMode => _replayGainMode;
  double get replayGainPreampDb => _replayGainPreampDb;

  /// Volume multiplier for [track] under the current ReplayGain settings.
  double _gainFor(JellyfinTrack? track) {
    if (track == null) return 1.0;
    return replayGainMultiplier(
      mode: _replayGainMode,
      trackGainDb: track.normalizationGain,
      albumGainDb: track.albumNormalizationGain,
      preampDb: _replayGainPreampDb,
    );
  }

  /// Change ReplayGain settings and re-apply volume to the live players.
  Future<void> setReplayGain({ReplayGainMode? mode, double? preampDb}) async {
    _replayGainMode = mode ?? _replayGainMode;
    _replayGainPreampDb = (preampDb ?? _replayGainPreampDb).clamp(-15.0, 0.0);
    await _player.setVolume((_volume * _gainFor(_currentTrack)).clamp(0.0, 1.0));
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

  TranscodeCodec _transcodeCodec = TranscodeCodec.mp3;
  TranscodeCodec get transcodeCodec => _transcodeCodec;

  /// Codec for server-side transcodes; applies from the next track loaded.
  void setTranscodeCodec(TranscodeCodec codec) {
    _transcodeCodec = codec;
    debugPrint('🎵 Transcode codec: ${codec.label}');
  }

  StreamingQuality get streamingQuality => _streamingQuality;

  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
    // Subscribe to connectivity changes for immediate quality adaptation
    _connectivitySubscription?.cancel();
    _connectivitySubscription = service.onStatusChange.listen((connected) {
      final wasAvailable = _networkAvailable;
      _networkAvailable = connected;
      unawaited(_updateNetworkType(service));
      // Back online: a track waiting out the outage resumes now.
      if (connected && !wasAvailable) _retryAfterOutageSoon();
    });
    // Prime the network type now: until the first check, auto quality assumes
    // Wi-Fi and would stream the original file over cellular.
    _lastNetworkCheck = DateTime.now();
    unawaited(_updateNetworkType(service));
    unawaited(service.hasNetworkTransport().then((connected) {
      if (!_disposed) _networkAvailable = connected;
    }));
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
    // Streaming — cache (when allowed) then extract
    final (streamUrl, _) = _getStreamUrl(track);
    if (streamUrl != null) {
      await _maybeCacheStreamingCopy(track, streamUrl);
    }
  }

  PlaybackReportingService? get reportingService => _reportingService;

  /// Gets the appropriate stream URL based on quality setting.
  /// Returns (url, isDirectStream) tuple — isDirectStream means the server
  /// is expected to send the original file untouched (reported as
  /// DirectStream; a load failure then retries with a forced transcode).
  ///
  /// All qualities go through `/Audio/{id}/universal`, which serves the
  /// original file when AVPlayer can play it within the bitrate cap and
  /// transcodes to MP3 otherwise. `/Items/{id}/Download` is avoided: it needs
  /// the download permission (403), logs a "downloaded" activity entry per
  /// play, and hands AVPlayer formats it can't decode.
  (String? url, bool isDirectStream) _getStreamUrl(JellyfinTrack track, {String? sessionId}) {
    final quality = _streamingQuality;

    // For original/lossless quality: original file when AVPlayer-native.
    if (quality == StreamingQuality.original) {
      debugPrint('🎵 Stream URL: original');
      return _originalQualityUrl(track);
    }

    // For auto mode, check network type and switch quality accordingly
    if (quality == StreamingQuality.auto) {
      return _getAutoQualityStreamUrl(track, sessionId: sessionId);
    }

    // Capped quality: lossy files under the cap as-is, others transcoded.
    final bitrate = quality.maxBitrate ?? 320000;
    debugPrint('🎵 Stream URL: capped ${bitrate ~/ 1000}kbps');
    return _cappedQualityUrl(track, bitrate, sessionId: sessionId);
  }

  (String? url, bool isDirectStream) _originalQualityUrl(JellyfinTrack track) {
    final url = track.originalQualityStreamUrl(
      deviceId: _deviceId,
      transcodeCodec: _transcodeCodec,
    );
    if (url != null) {
      return (url, track.streamUrlOverride != null || track.isAvPlayerNativeFormat);
    }
    // universal needs the track's userId; last resort is the raw file.
    return (track.directDownloadUrl(), true);
  }

  (String? url, bool isDirectStream) _cappedQualityUrl(
    JellyfinTrack track,
    int maxBitrate, {
    String? sessionId,
  }) {
    final url = track.cappedStreamUrl(
      deviceId: _deviceId,
      maxBitrate: maxBitrate,
      transcodeCodec: _transcodeCodec,
    );
    if (url != null) {
      final bitrate = track.bitrate;
      final servedAsIs = track.streamUrlOverride != null ||
          (track.isAvPlayerNativeFormat && bitrate != null && bitrate <= maxBitrate);
      return (url, servedAsIs);
    }
    // No userId for universal: force a transcode linked to our session.
    return (
      track.transcodedStreamUrl(
        deviceId: _deviceId,
        audioBitrate: maxBitrate,
        audioCodec: _transcodeCodec.audioCodec,
        container: _transcodeCodec.container,
        playSessionId: sessionId,
      ),
      false,
    );
  }

  // Cached network type for auto quality mode
  _NetworkType _cachedNetworkType = _NetworkType.wifi;
  DateTime? _lastNetworkCheck;
  // In-flight network-type check (awaited before resolving an auto-quality
  // stream so the first track after launch isn't picked with a stale type).
  Future<void>? _networkTypeRefresh;

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
        debugPrint('🎵 Stream URL: auto/Wi-Fi (original)');
        return _originalQualityUrl(track);

      case _NetworkType.cellular:
        debugPrint('🎵 Stream URL: auto/cellular (192kbps)');
        return _cappedQualityUrl(track, 192000, sessionId: sessionId);

      case _NetworkType.slow:
        debugPrint('🎵 Stream URL: auto/slow (128kbps)');
        return _cappedQualityUrl(track, 128000, sessionId: sessionId);
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

  /// Update cached network type from connectivity service (concurrent calls
  /// share one check).
  Future<void> _updateNetworkType(ConnectivityService connectivity) {
    final existing = _networkTypeRefresh;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _doUpdateNetworkType(connectivity).whenComplete(() {
      if (identical(_networkTypeRefresh, future)) _networkTypeRefresh = null;
    });
    _networkTypeRefresh = future;
    return future;
  }

  Future<void> _doUpdateNetworkType(ConnectivityService connectivity) async {
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
    _isCrossfading = false;
    // Don't dispose - reuse the player instance. While its source is still
    // loading, _startCrossfade stops it itself once the load returns
    // (stopping now would orphan the pending native load).
    if (!_crossfadeLoading) {
      unawaited(_crossfadePlayer?.stop());
    }
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
    _lyricsService = LyricsService(jellyfinService: service)
      ..setOffline(_isOffline);
    _loadPlayStats();
    if (_pendingState != null && !_hasRestored) {
      unawaited(applyStoredState(_pendingState!));
    }
  }

  /// Offline mode (user toggle or no network). While offline only
  /// downloaded / cached tracks are played: nothing is streamed, and
  /// tracks without a local copy are skipped (see
  /// [_skipUnavailableOffline]). Lyrics return expired cache entries.
  void setOfflineMode(bool offline) {
    _lyricsService?.setOffline(offline);
    if (offline == _isOffline) return;
    _isOffline = offline;
    _offlineCachedIds = null; // re-read the audio cache on next use
    _offlineMissKey = null;
    // Back online: a track waiting out the outage resumes now.
    if (!offline) _retryAfterOutageSoon();
    // A pre-loaded *stream* for the next track would die mid-swap.
    final preloaded = _preloadedSource;
    if (offline && preloaded != null && !preloaded.isLocalFile) {
      _clearPreload();
    }
  }

  bool _isOffline = false;
  bool get isOfflineMode => _isOffline;

  // Track ids in the audio cache, as last read for offline skipping
  // (refreshed at most every [_offlineCachedIdsTtl]).
  Set<String>? _offlineCachedIds;
  DateTime _offlineCachedIdsAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _offlineCachedIdsTtl = Duration(seconds: 30);
  // "<track id>@<index>/<queue length>" for which the offline pre-load found
  // nothing playable, so the once-per-second check doesn't rescan the queue.
  String? _offlineMissKey;

  Future<Set<String>> _offlineCachedTrackIds() async {
    final memo = _offlineCachedIds;
    final now = DateTime.now();
    if (memo != null && now.difference(_offlineCachedIdsAt) < _offlineCachedIdsTtl) {
      return memo;
    }
    Set<String> ids;
    try {
      await _audioCacheService.initialize();
      ids = (await _audioCacheService.getCachedTrackIds()).toSet();
    } catch (e) {
      debugPrint('⚠️ Could not read audio cache index: $e');
      ids = memo ?? <String>{};
    }
    _offlineCachedIds = ids;
    _offlineCachedIdsAt = now;
    return ids;
  }

  /// Whether [track] has a local source (download, audio cache, bundled
  /// asset). Record-based: [_resolvePlaybackSource] still verifies the file.
  bool _hasLocalCopy(JellyfinTrack track, Set<String> cachedIds) =>
      track.assetPathOverride != null ||
      (_downloadService?.isDownloaded(track.id) ?? false) ||
      cachedIds.contains(track.id);

  /// Offline: the next queue slot after [from] in [direction] that has a
  /// local copy (wrapping under repeat-all), or -1.
  Future<int> _nextOfflinePlayableIndex(int from, int direction) async {
    final cachedIds = await _offlineCachedTrackIds();
    final queue = _queue;
    return nextPlayableIndex(
      length: queue.length,
      from: from,
      direction: direction,
      wrap: _repeatMode == RepeatMode.all,
      isPlayable: (i) => _hasLocalCopy(queue[i], cachedIds),
    );
  }

  static String _skippedMessage(JellyfinTrack track, int skipped) => skipped <= 1
      ? '“${track.name}” isn\'t downloaded — skipped'
      : 'Skipped $skipped tracks that aren\'t downloaded';

  /// Enable or disable image prewarming (called by offline mode gate).
  void setImagePrewarmEnabled(bool enabled) {
    _imagePrewarmService?.enabled = enabled;
  }
  
  // Streams
  final StreamController<JellyfinTrack?> _currentTrackController = BehaviorSubject<JellyfinTrack?>();
  final StreamController<bool> _playingController = BehaviorSubject<bool>.seeded(false);
  
  // Use BehaviorSubject to ensure new listeners get the latest value immediately
  final BehaviorSubject<Duration> _positionController = BehaviorSubject<Duration>.seeded(Duration.zero);
  /// How far the current source has buffered (streams fill in as they
  /// download; local files are fully buffered).
  final BehaviorSubject<Duration> _bufferedController = BehaviorSubject<Duration>.seeded(Duration.zero);
  StreamSubscription<Duration>? _bufferedSub;
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

  /// Position, buffered position and duration in one snapshot, for
  /// progress bars.
  ///
  /// Multi-listener and always the same stream: widgets may cache it and
  /// listen, cancel and listen again (e.g. when they remount); every new
  /// listener immediately gets the latest value.
  Stream<PositionData> get positionDataStream => _positionDataRelay.stream;

  late final LatestValueRelay<PositionData> _positionDataRelay =
      LatestValueRelay<PositionData>(
    Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
      _positionController.stream,
      _bufferedController.stream.distinct(),
      _durationController.stream,
      (position, buffered, duration) =>
          PositionData(position, buffered, duration ?? Duration.zero),
    ),
  );

  /// Track + playing state only, for UI that must not rebuild on every
  /// position tick (give the progress UI its own [positionDataStream]
  /// builder). Emits only when the track object or the playing flag
  /// changes; a favourite toggle ([updateCurrentTrack]) is a new object.
  ///
  /// Multi-listener, cached and replaying like [positionDataStream].
  Stream<TrackPlayingState> get trackPlayingStream => _trackPlayingRelay.stream;

  late final LatestValueRelay<TrackPlayingState> _trackPlayingRelay =
      LatestValueRelay<TrackPlayingState>(
    Rx.combineLatest2<JellyfinTrack?, bool, TrackPlayingState>(
      _currentTrackController.stream,
      _playingController.stream,
      (track, isPlaying) => (track: track, isPlaying: isPlaying),
    ),
    equals: (a, b) => identical(a.track, b.track) && a.isPlaying == b.isPlaying,
  );

  JellyfinTrack? get currentTrack => _currentTrack;
  bool get isPlaying => _player.state == EngineState.playing;
  Duration get currentPosition => _lastPosition;
  List<JellyfinTrack> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  RepeatMode get repeatMode => _repeatMode;
  double get volume => _volume;
  bool get shuffleEnabled => _isShuffleEnabled;
  bool get isSleepTimerActive => _sleepTimer != null || _sleepTracksRemaining > 0;
  Duration get sleepTimeRemaining => _sleepTimeRemaining;
  int get sleepTracksRemaining => _sleepTracksRemaining;
  LoopState get loopState => _loopState;

  /// Replace the stored copy of [track] (e.g. after a favourite toggle).
  ///
  /// Callers often pass a copy of the track they captured before an await;
  /// if playback moved on meanwhile, only that track's queue entries are
  /// updated and the new current track is left alone.
  void updateCurrentTrack(JellyfinTrack track) {
    final isCurrent = _currentTrack?.id == track.id;
    var changed = false;
    if (isCurrent) {
      _currentTrack = track;
      _currentTrackController.add(track);
      if (_currentIndex >= 0 &&
          _currentIndex < _queue.length &&
          _queue[_currentIndex].id == track.id) {
        _queue[_currentIndex] = track;
        changed = true;
      }
    }
    // Other entries of the same track (duplicates, or a track that is no
    // longer current).
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == track.id && !identical(_queue[i], track)) {
        _queue[i] = track;
        changed = true;
      }
    }
    if (changed) _onQueueContentChanged(publish: false);
    if (!isCurrent && !changed) return;
    unawaited(_stateStore.savePlaybackSnapshot(
      currentTrack: isCurrent ? track : null,
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
    ));
  }

  // ---- Queue change tracking ----
  // The queue is pushed to the lock screen / CarPlay (audio_service) and to
  // disk only when its contents changed, not on every track change.
  int _queueVersion = 0;
  int _publishedQueueVersion = -1;
  int _persistedQueueVersion = -1;

  /// The queue's contents changed: tell listeners, the audio handler
  /// ([publish]) and the next snapshot save.
  void _onQueueContentChanged({bool publish = true}) {
    _queueVersion++;
    _queueController.add(List<JellyfinTrack>.unmodifiable(_queue));
    if (publish) _publishQueue();
  }

  /// Push the queue to audio_service if it changed since the last push.
  void _publishQueue() {
    final handler = _audioHandler;
    if (handler == null || _publishedQueueVersion == _queueVersion) return;
    _publishedQueueVersion = _queueVersion;
    handler.updateNautuneQueue(_queue);
  }

  /// The queue for a snapshot save: null (keep the stored one) when it
  /// hasn't changed since it was last saved.
  List<JellyfinTrack>? _queueToPersist() {
    if (_persistedQueueVersion == _queueVersion) return null;
    _persistedQueueVersion = _queueVersion;
    return _queue;
  }
  
  Future<void> setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    _volume = clamped.toDouble();
    _volumeController.add(_volume);

    // Apply ReplayGain normalization if available
    final currentMultiplier = _gainFor(_currentTrack);
    final adjustedVolume = (_volume * currentMultiplier).clamp(0.0, 1.0);
    await _player.setVolume(adjustedVolume);
    unawaited(_stateStore.savePlaybackSnapshot(volume: _volume));
  }
  
  AudioPlayerService() {
    _initAudioSession();
    _attachPlayerListeners(_player);
    _initAudioHandler();
    _player.setVolume(_volume);
    _volumeController.add(_volume);
    _emitIdleVisualizer();

    // Initialize reusable crossfade player
    _crossfadePlayer = _createPlayer();

    // Subscribe the shared UI streams now so they always hold the latest
    // value, whenever a widget starts listening.
    _positionDataRelay.hasValue;
    _trackPlayingRelay.hasValue;

    // Partial stream-cache files left by a previous run (killed mid-download).
    unawaited(_cleanStaleStreamCache());
  }

  String get _deviceId {
    // Prefer persistent device ID from session if available
    final sessionDeviceId = _jellyfinService?.session?.deviceId;
    if (sessionDeviceId != null) return sessionDeviceId;
    
    // Fallback to platform-based ID (legacy/offline without session)
    return 'nautune-${Platform.operatingSystem}';
  }

  Future<void> _initAudioHandler() async {
    // Initialize AudioService for lock screen / Control Center media controls.
    try {
      _audioHandler = await audio_service.AudioService.init(
        builder: () => NautuneAudioHandler(
          player: _player,
          onPlay: () => resume(),
          onPause: () => pause(),
          onStop: () => stop(),
          onSkipToNext: () => skipToNext(),
          onSkipToPrevious: () => skipToPrevious(),
          onSeek: (position) => unawaited(seek(position).catchError(
                (Object e) => debugPrint('⚠️ Lock screen seek failed: $e'),
              )),
          onSetShuffle: (on) {
            if (on != _isShuffleEnabled) toggleShuffle();
          },
          onSetRepeat: (mode) => setRepeatMode(switch (mode) {
            audio_service.AudioServiceRepeatMode.one => RepeatMode.one,
            audio_service.AudioServiceRepeatMode.none => RepeatMode.off,
            _ => RepeatMode.all,
          }),
        ),
        config: const audio_service.AudioServiceConfig(
          // Android notification fields are ignored on iOS; kept for plugin defaults.
          androidNotificationChannelId: 'com.elysiumdisc.nautune.channel.audio',
          androidNotificationChannelName: 'Nautune Audio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
      debugPrint('✅ Audio service initialized for media controls');
      _publishModes();
      _audioHandler?.updateSpeed(_speed);
      _shuffleController.stream.listen((_) => _publishModes());
      _repeatModeController.stream.listen((_) => _publishModes());
      // A session restore may have finished before the handler existed;
      // publish its track now so the lock screen / CarPlay aren't blank.
      final restored = _currentTrack;
      if (restored != null) {
        await _publishMediaItem(restored);
        _publishQueue();
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
        (_) {
          // Headphones gone: a track waiting out an outage must not come
          // back on the speaker.
          _cancelResumeAfterOutage();
          if (isPlaying ||
              _sourceLoadToken != null ||
              _playInFlight != null ||
              _restorePrepareFuture != null) {
            unawaited(pause());
          }
        },
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
          final multiplier = _gainFor(_currentTrack);
          unawaited(_player.setVolume((_volume * multiplier * 0.3).clamp(0.0, 1.0)));
        }
        return;
      }
      // pause / unknown: remember whether we were audible, then pause.
      // (A second "begin" while already paused must not clear the flag; it
      // is cleared by the end event or by an explicit user play/pause.)
      final wasPlaying = isPlaying || _lastPlayingState;
      if (wasPlaying) {
        _wasPlayingBeforeInterruption = true;
        unawaited(_pauseInternal(fromUser: false));
      } else if (_resumeAfterOutageTrackId != null) {
        // Waiting out a network outage: don't come back during the call;
        // resume when it ends (if the system says so), like a paused track.
        _cancelResumeAfterOutage();
        _wasPlayingBeforeInterruption = true;
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
    final multiplier = _gainFor(_currentTrack);
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
    _fftUrl = fileUrl;
    await fft.setAudioUrl(fileUrl);
    // The visualizer may have been hidden while this was being set up.
    if (foreground && _visualizerWanted) {
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
    final advance = _advanceSub;
    final errors = _playerErrorSub;
    _playerErrorSub = null;
    _playerPosSub = null;
    _playerDurSub = null;
    _playerStateSub = null;
    _playerCompleteSub = null;
    _advanceSub = null;
    if (advance != null) futures.add(advance.cancel());
    if (errors != null) futures.add(errors.cancel());
    if (pos != null) futures.add(pos.cancel());
    if (dur != null) futures.add(dur.cancel());
    if (state != null) futures.add(state.cancel());
    if (done != null) futures.add(done.cancel());
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  void _attachPlayerListeners(EnginePlayer player) {
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
      final playing = player.state == EngineState.playing;
      if (playing && !_batterySaverMode) {
        _emitVisualizerFrame(position);
      }
      if (playing) _listenedTime.onPosition(position, DateTime.now());
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
        // Count the play / scrobble once enough has been heard
        _checkPlayThreshold();
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
        final isPlaying = state == EngineState.playing;
        _playingController.add(isPlaying);
        // Time spent paused/stopped isn't a stall.
        _stallDetector.reset();

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
          _startStallChecks();
          _lastListenTimeRecord ??= DateTime.now();
          _startPositionSaving();
          unawaited(_stateStore.savePlaybackSnapshot(isPlaying: true));
          // FFT stopped by a pause: pick it up again.
          if (_fftStartOnResume && _visualizerWanted) {
            _fftStartOnResume = false;
            unawaited(_startFftForCurrentTrack().catchError(
              (Object e) => debugPrint('🎵 iOS FFT start failed: $e'),
            ));
          }
        } else {
          _stopStallChecks();
          _stopPositionSaving();
          _creditListenTime(stillPlaying: false);
          _emitIdleVisualizer();
          unawaited(_stateStore.savePlaybackSnapshot(isPlaying: false));
          _pauseFftCapture();
        }
      },
      onError: (e) => debugPrint('⚠️ Player state stream error: $e'),
    );

    // Track completion - gapless transition
    _playerCompleteSub = player.onPlayerComplete.listen(
      (_) async {
        if (_disposed) return;
        // During a crossfade the outgoing player completes mid-fade; the
        // crossfade itself advances the queue, so don't advance twice. A
        // play request (skip, tap) or stop made just before the end decides
        // what plays next: advancing from its index would skip a track.
        if (!_isTransitioning &&
            !_isCrossfading &&
            _playInFlight == null &&
            !_stopping) {
          try {
            await _gaplessTransition();
          } catch (e) {
            // playTrack already left the failed track paused and reloadable.
            debugPrint('❌ Track advance failed: $e');
            if (!_disposed) {
              _playbackErrorController.add('Could not play the next track.');
            }
          }
        }
      },
      onError: (e) => debugPrint('⚠️ Player complete stream error: $e'),
    );

    _bufferedSub?.cancel();
    _bufferedSub = player.bufferedPosition.listen((buffered) {
      if (!_disposed) _bufferedController.add(buffered);
    });

    // Gapless: the queued next track started on this player.
    _advanceSub = player.onAdvanced.listen((_) {
      if (_disposed) return;
      unawaited(_onGaplessAdvance().catchError(
        (Object e) => debugPrint('❌ Gapless advance bookkeeping failed: $e'),
      ));
    });

    // Errors after the source loaded (e.g. the stream failed mid-track).
    _playerErrorSub = player.onError.listen((error) {
      if (_disposed) return;
      _onPlayerError(player, error);
    });
  }

  /// The native player reported an error after loading. Load failures are
  /// handled where the source is loaded (setSource throws), so only errors
  /// while nothing is loading are handled here.
  void _onPlayerError(EnginePlayer player, EnginePlaybackError error) {
    if (!identical(player, _player)) return;
    debugPrint('⚠️ Player error: $error');
    if (_currentTrack == null ||
        _sourceLoadToken != null ||
        _playInFlight != null ||
        _restoreSourcePending ||
        _isCrossfading) {
      return;
    }
    final index = error.index;
    final current = player.currentIndex;
    if (index != null && current != null && index > current) {
      // The gapless next track failed to load: take it off the player so
      // the end of this track goes through the normal (retrying) advance.
      debugPrint('⚠️ Queued next track failed - it will be loaded normally');
      _clearPreload();
      return;
    }
    // just_audio keeps "playing" set through an error; only a pause clears it.
    final wasPlaying = player.wantsToPlay || _lastPlayingState;
    unawaited(_recoverFromStall(resume: wasPlaying, fromError: true));
  }

  void _startStallChecks() {
    if (_stallTimer != null) return;
    _stallDetector.reset();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkStall());
  }

  void _stopStallChecks() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _stallDetector.reset();
  }

  void _checkStall() {
    if (_disposed) return;
    final player = _player;
    if (player.state != EngineState.playing ||
        _sourceLoadToken != null ||
        _playInFlight != null ||
        _restoreSourcePending ||
        _isCrossfading ||
        _isTransitioning ||
        _advanceInFlight ||
        _stallRecoveryInFlight) {
      _stallDetector.reset();
      return;
    }
    final stalled = _stallDetector.onTick(
      player.position,
      DateTime.now(),
      buffering: player.isBuffering,
      networkAvailable: _networkAvailable && !_isOffline,
      duration: player.duration,
    );
    if (stalled) {
      _stallDetector.reset();
      unawaited(_recoverFromStall());
    }
  }

  /// The next track, queued on the main player by [_preloadNextTrack], has
  /// just started playing (no gap). Do the per-track bookkeeping that
  /// [_gaplessTransition] does for a normal advance.
  Future<void> _onGaplessAdvance() async {
    final nextTrack = _preloadedTrack;
    final preloaded = _preloadedSource;
    var nextIndex = _preloadedIndex;
    // Safety net for a slot moved by a queue edit: the queued track is
    // still the one after the current slot.
    if (nextTrack != null &&
        nextIndex != null &&
        _queue.isNotEmpty &&
        (nextIndex >= _queue.length || _queue[nextIndex].id != nextTrack.id)) {
      final slot = _currentIndex + 1 < _queue.length ? _currentIndex + 1 : 0;
      if (_queue[slot].id == nextTrack.id) nextIndex = slot;
    }
    _preloadedTrack = null;
    _preloadedSource = null;
    _preloadedIndex = null;
    if (nextTrack == null ||
        preloaded == null ||
        nextIndex == null ||
        nextIndex >= _queue.length ||
        _queue[nextIndex].id != nextTrack.id) {
      // A play request (skip, tap) or stop took over while the queued track
      // started: that request decides what plays, not a resync from here
      // (which would skip one track past the one requested).
      if (_playInFlight != null ||
          _stopping ||
          _currentTrack == null ||
          _restoreSourcePending) {
        debugPrint('⚡ Gapless advance superseded by a newer request');
        return;
      }
      // The queue changed under the queued track; play what the queue says.
      debugPrint('⚠️ Gapless advance out of sync with the queue - resyncing');
      final target = _currentIndex + 1;
      if (target < _queue.length) {
        await playTrack(_queue[target], queueContext: _queue, fromShuffle: _isShuffleEnabled, queueIndex: target);
      }
      return;
    }

    // Close out the finished track: listening time + Jellyfin "stopped".
    _recordActualListeningTime();
    _reportOutgoingStopped();

    // A newer request (tap mid-transition) wins over this bookkeeping.
    ++_playRequestId;

    if (_isSleepTimerByTracks && _sleepTracksRemaining > 0) {
      _sleepTracksRemaining--;
      _sleepTimerController.add(Duration(seconds: -_sleepTracksRemaining));
    }

    debugPrint('⚡ Gapless: ${nextTrack.name}');
    _creditListenTime(stillPlaying: true);
    _currentIndex = nextIndex;
    _currentTrack = nextTrack;
    _currentTrackController.add(_currentTrack);
    _isCurrentTrackLocal = preloaded.isLocalFile;
    _setCurrentSource(preloaded.url, isLocal: preloaded.isLocalFile);
    _analyzeTrackForVisualizer(nextTrack);
    _playingController.add(true);
    _lastPlayingState = true;
    unawaited(_player.setVolume((_volume * _gainFor(nextTrack)).clamp(0.0, 1.0)));

    _onTrackBegan(nextTrack, playMethod: preloaded.playMethod);
    _afterTrackStarted(nextTrack);
    unawaited(_audioHandler?.forcePlayingState());

    if (_infiniteRadioEnabled) unawaited(_checkInfiniteRadio());
    if (!_batterySaverMode) {
      _imagePrewarmService?.prewarmQueueImages(_queue, _currentIndex);
    }
    _saveCurrentPosition();
  }
  
  Future<void> _gaplessTransition() async {
    // One advance at a time: resume() on a finished track, a cancelled
    // crossfade or the stall check may ask while one is still awaiting
    // (Infinite Radio fetch, offline lookup) — a second would move on from
    // the index the first just set and skip a track.
    if (_advanceInFlight) return;
    _advanceInFlight = true;
    try {
      await _advanceToNextTrack();
    } finally {
      _advanceInFlight = false;
    }
  }

  Future<void> _advanceToNextTrack() async {
    // A play request or stop already decides what plays (the track ended
    // while it was loading).
    if (_playInFlight != null || _stopping) return;
    // Any request after this point (the user playing something while the
    // Infinite Radio fetch runs) wins over this advance.
    final requestId = _playRequestId;
    final queueGeneration = _queueGeneration;
    bool superseded() =>
        _disposed ||
        requestId != _playRequestId ||
        queueGeneration != _queueGeneration ||
        _playInFlight != null ||
        _stopping;

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
        await _stopForSleepAtTrackEnd();
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
        if (superseded()) return;
      }
    }

    // Offline: jump straight to the next downloaded/cached track (so a
    // gapless pre-load of it can be used). Wrap-around and "nothing left"
    // are handled by playTrack's offline skip below.
    var nextIndex = _currentIndex + 1;
    if (_isOffline && nextIndex < _queue.length) {
      final fromIndex = _currentIndex;
      final fromTrack = _currentTrack;
      final target = await _nextOfflinePlayableIndex(fromIndex, 1);
      if (superseded() ||
          _currentTrack?.id != fromTrack?.id ||
          _currentIndex != fromIndex) {
        return; // the user moved on meanwhile
      }
      if (target > nextIndex && target < _queue.length) {
        final skipped = target - nextIndex;
        _playbackErrorController.add(_skippedMessage(_queue[nextIndex], skipped));
        nextIndex = target;
      }
    }

    // Move to next track
    if (nextIndex < _queue.length) {
      _isTransitioning = true;
      try {
        // Reaching here means the next track wasn't queued on the player
        // (gapless off, pre-load not ready, offline skip): load it now.
        // Queued tracks advance by themselves (_onGaplessAdvance).
        final nextTrack = _queue[nextIndex];
        debugPrint('🎵 Advancing to: ${nextTrack.name}');
        await playTrack(
          nextTrack,
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: nextIndex,
        );
      } catch (e) {
        debugPrint('❌ Track advance failed: $e');
        // playTrack returns (rather than throws) when superseded, so an error
        // here is always the latest request's.
        if (_disposed) return;
        // One recovery attempt: the next track may just be broken (404,
        // unsupported file). Bounded, so a queue that fails entirely (e.g.
        // network gone) doesn't skip through every track.
        if (_currentIndex + 1 < _queue.length) {
          final retryIndex = _currentIndex + 1;
          _playbackErrorController.add('Track failed to load, skipping...');
          try {
            await playTrack(
              _queue[retryIndex],
              queueContext: _queue,
              fromShuffle: _isShuffleEnabled,
              queueIndex: retryIndex,
            );
          } catch (retryError) {
            debugPrint('❌ Recovery also failed: $retryError');
            // playTrack left this track paused and reloadable (play retries
            // it); keep the queue instead of wiping it with stop().
            if (!_disposed) {
              _playbackErrorController.add('Playback failed. Check your connection and press play to retry.');
            }
          }
        } else if (!_disposed) {
          _playbackErrorController.add('Playback failed. Press play to retry.');
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
        // The user played something else while it was fetching: theirs
        // plays (don't skip past it, don't stop it).
        if (superseded()) return;

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

  /// Track-count sleep timer ran out as a track finished: stop here, but
  /// keep the queue and park on the next track (paused, loaded on play) so
  /// pressing play continues with it instead of silently re-"resuming" the
  /// finished, already-released player.
  Future<void> _stopForSleepAtTrackEnd() async {
    final requestId = _playRequestId;
    await _fadeOutAndStop();
    // A track the user started during the fade-out stays.
    if (_disposed || requestId != _playRequestId || _playInFlight != null) return;
    final nextIndex = _currentIndex + 1 < _queue.length
        ? _currentIndex + 1
        : (_repeatMode == RepeatMode.all && _queue.isNotEmpty ? 0 : -1);
    if (nextIndex == -1) {
      // End of the queue: nothing to continue with.
      await stop();
      return;
    }
    _parkOnQueueIndex(nextIndex);
  }

  /// Make [index] the current track without playing it. Its source is loaded
  /// and its begin-track bookkeeping runs on the next resume().
  void _parkOnQueueIndex(int index) {
    if (index < 0 || index >= _queue.length) return;
    _playRequestId++; // supersede anything in flight
    _cancelResumeAfterOutage();
    final track = _queue[index];
    _creditListenTime(stillPlaying: false);
    _clearPreload();
    _currentIndex = index;
    _currentTrack = track;
    _currentTrackController.add(track);
    _resetPerTrackState(track);
    _analyzeTrackForVisualizer(track);
    _trackStartTime = null;
    _lastPosition = Duration.zero;
    _positionController.add(Duration.zero);
    _currentSourceUrl = null;
    _isCurrentTrackLocal = false;
    _restoreSourcePending = true;
    _restoreBeginPending = true;
    _restoreCountsPlay = true;
    _restoreSessionId = null;
    _lastPlayingState = false;
    _playingController.add(false);
    unawaited(_publishMediaItem(track));
    unawaited(_audioHandler?.forceBroadcastCurrentState());
    unawaited(_stateStore.savePlaybackSnapshot(
      currentTrack: track,
      position: Duration.zero,
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      isPlaying: false,
    ));
  }
  
  Future<void> hydrateFromPersistence(PlaybackState? state) async {
    if (state == null) {
      return;
    }
    _pendingState = state;
    await _attemptRestoreFromPending();
  }

  /// Forget a saved queue still waiting to be restored (it waits for a
  /// Jellyfin session). Call on logout / account switch, so the previous
  /// account's queue isn't restored into the next one.
  void clearPendingRestore() {
    _pendingState = null;
    _restoreGeneration++;
  }

  // Bumped by clearPendingRestore/stop: a restore still loading its queue
  // then drops it.
  int _restoreGeneration = 0;

  Future<void> applyStoredState(PlaybackState state) async {
    _pendingState = state;
    await _attemptRestoreFromPending(force: true);
  }

  Future<void> _attemptRestoreFromPending({bool force = false}) async {
    if (_hasRestored && !force) return;
    // Captured before any await: if the user starts playback while the
    // saved queue is still being loaded (possibly from the server), their
    // request wins.
    final requestId = _playRequestId;
    final generation = _restoreGeneration;
    final state = _pendingState ?? await _stateStore.load();
    if (generation != _restoreGeneration) return;
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

      // Logged out / stopped meanwhile: this queue is no longer wanted.
      if (generation != _restoreGeneration) return;

      if (state.queueIds.isNotEmpty && queue.isEmpty) {
      // Wait until we can resolve queue items (likely requires Jellyfin session).
      _pendingState = state;
      return;
    }

    await _applyStateFromStorage(state, queue, requestId);
    _pendingState = null;
    _hasRestored = true;
    } catch (e, stack) {
      debugPrint('⚠️ Failed to restore playback state: $e\n$stack');
      // Don't rethrow - we want app to continue even if restore fails
    }
  }

  Future<List<JellyfinTrack>> _buildQueueFromState(PlaybackState state) async {
    if (state.queueSnapshot.isNotEmpty) {
      final tracks = state.toQueueTracks();
      // Essential Mix tracks carry an absolute file path that goes stale when
      // an iOS update moves the app container: rebuild them against today's
      // download. One that's no longer downloaded is kept as is (it fails to
      // play like any missing file) so queue indices stay valid.
      if (!tracks.any(
        (t) => EssentialMixService.isEssentialMixTrackId(t.id),
      )) {
        return tracks;
      }
      return [
        for (final track in tracks)
          await EssentialMixService.instance.resolveRestoredTrack(track) ??
              track,
      ];
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
    int requestId,
  ) async {
    // If the user started playback while we were restoring, their request
    // wins (only the volume / repeat preferences are restored then).
    bool superseded() => _disposed || requestId != _playRequestId;

    _volume = state.volume.clamp(0.0, 1.0);
    await _applyUserVolumeToPlayer();
    _volumeController.add(_volume);

    _repeatMode = RepeatMode.values.firstWhere(
      (mode) => mode.name == state.repeatMode,
      orElse: () => RepeatMode.off,
    );
    _repeatModeController.add(_repeatMode);

    if (queue.isEmpty || superseded()) {
      return;
    }

    _isShuffleEnabled = state.shuffleEnabled;
    _shuffleController.add(_isShuffleEnabled);

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
    _queueGeneration++;
    _onQueueContentChanged(publish: false);
    _isCurrentTrackLocal = false;

    // Publish the restored track to the lock screen / CarPlay (paused). If
    // the audio handler isn't up yet, _initAudioHandler publishes it.
    unawaited(_publishMediaItem(track));
    _publishQueue();

    // Begin-track bookkeeping (start time, Jellyfin start report, now
    // playing) is deferred to the first resume(). It is a continuation of
    // the play counted by the previous launch.
    _trackStartTime = null;
    _restoreBeginPending = true;
    _restoreCountsPlay = false;
    _restoreSessionId = null;
    _restorePlayMethod = 'DirectPlay';
    // The source is prepared in the background (below); resume() waits for
    // it or loads it itself.
    _restoreSourcePending = true;
    _currentSourceUrl = null;

    final position = Duration(milliseconds: state.positionMs);
    _positionController.add(position);
    _lastPosition = position;

    // Always restore in paused state - user must explicitly resume
    // This prevents unexpected audio playback on app launch
    _playingController.add(false);

    // Update media controls to show paused state (on top of the published
    // state: a fresh one would drop the shuffle/repeat modes and the
    // shuffle/repeat/stop commands until the next state change).
    _audioHandler?.showPaused(position: position, queueIndex: clampedIndex);

    // Prepare the audio source without playing, in the background: app
    // startup must not wait on the network (an unreachable server used to
    // hold it for up to 10 s). Deferred one event-loop turn so the caller
    // can apply the streaming-quality/session settings it sets right after
    // hydrating.
    Timer.run(() {
      if (superseded() || !_restoreSourcePending) return;
      unawaited(_prepareRestoredSource());
    });
  }

  String _restorePlayMethod = 'DirectPlay';

  /// Resolve where [track] plays from, in playback priority order:
  /// downloaded file → audio cache → stream → asset/path override.
  /// Returns null if no source is available.
  Future<_ResolvedSource?> _resolvePlaybackSource(
    JellyfinTrack track, {
    String? sessionId,
  }) async {
    // Auto quality: don't pick the URL with a network type that is being
    // re-checked right now (e.g. first track after launch).
    final networkCheck = _networkTypeRefresh;
    if (!_isOffline &&
        _streamingQuality == StreamingQuality.auto &&
        networkCheck != null) {
      await networkCheck.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    final (streamUrl, isDirectStream) = _getStreamUrl(track, sessionId: sessionId);

    // Both lookups are independent: start them together (time-to-first-audio).
    // Online, only a copy at the streaming quality (or better) is used;
    // offline, any cached copy beats nothing.
    final cacheVariant =
        _isOffline || streamUrl == null ? null : cacheVariantForUrl(streamUrl);
    final cachedFileFuture = _audioCacheService
        .getCachedFile(track.id, variant: cacheVariant)
        .catchError((Object _) => null);

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
    final cachedFile = await cachedFileFuture;
    if (cachedFile != null) {
      debugPrint('✅ Found in cache: ${cachedFile.path}');
      return _ResolvedSource(
        url: cachedFile.path,
        isLocalFile: true,
        isDownloaded: false,
        isDirectStream: isDirectStream,
        streamUrl: streamUrl,
      );
    }

    // 3) Stream, based on quality preference. Never while offline: the
    // request would only hang until the load timeout.
    if (streamUrl != null && !_isOffline) {
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

  /// Engine source for a resolved URL/path. Untranscoded streams of [track]
  /// are cached while they play (one download, see [_streamCacheFileFor]).
  Future<EngineSource> _sourceFor(
    String url, {
    required bool isLocalFile,
    JellyfinTrack? track,
    bool isDirectStream = false,
  }) async {
    if (url.startsWith('assets/')) return EngineSource.asset(url);
    if (isLocalFile) return EngineSource.file(url);
    final cacheFile = track != null && isDirectStream ? await _streamCacheFileFor(track, url) : null;
    return EngineSource.url(url, cacheFile: cacheFile);
  }

  /// Run [op] (on behalf of request [owner]) after any in-flight player
  /// source/resume operation finishes.
  ///
  /// A holder that has been superseded by a newer request is not waited for:
  /// it may be stuck in a slow setSource (or one that never returns — the
  /// native call is orphaned if its item is reset by stop()), and every op
  /// re-checks its own staleness after each await, so running over it is
  /// safe. Waiting on a current holder is capped as a last resort.
  Future<T> _withPlayerLock<T>(int owner, Future<T> Function() op) {
    final previous = _playerOpLock;
    final previousOwner = _playerOpLockOwner;
    final done = Completer<void>();
    _playerOpLock = done.future;
    _playerOpLockOwner = owner;
    final Future<void> ready =
        previousOwner != null && previousOwner != _playRequestId
            ? Future<void>.value()
            : previous.timeout(
                _sourceLoadTimeout + const Duration(seconds: 5),
                onTimeout: () =>
                    debugPrint('⚠️ Player lock wait timed out - proceeding'),
              );
    return ready.then((_) => op()).whenComplete(() {
      done.complete();
      if (identical(_playerOpLock, done.future)) _playerOpLockOwner = null;
    });
  }

  /// setSource on [player] (the main player), bounded by [_sourceLoadTimeout]
  /// and flagged so seeks/pauses arriving meanwhile are deferred.
  Future<void> _loadMainSource(EnginePlayer player, EngineSource source) async {
    final token = Object();
    _sourceLoadToken = token;
    try {
      await player.setSource(source).timeout(_sourceLoadTimeout);
    } finally {
      if (identical(_sourceLoadToken, token)) _sourceLoadToken = null;
    }
  }

  /// Whether the main player's position is the current track's. Not while
  /// the track isn't loaded (restored session, failed load or reload) or is
  /// still loading: the player then reports 0 or the previous track's
  /// position, and [_lastPosition] holds where to resume.
  bool get _playerPositionIsCurrent =>
      !_restoreSourcePending &&
      !_positionFromPreviousTrack &&
      _sourceLoadToken == null &&
      _playInFlight == null &&
      !_stallRecoveryInFlight;

  void _setCurrentSource(String url, {required bool isLocal}) {
    _currentSourceUrl = url;
    _currentSourceIsLocal = isLocal;
    _positionFromPreviousTrack = false;
  }

  // ========== PER-TRACK BOOKKEEPING ==========

  /// State that must be reset the moment the current track changes (before
  /// any await), so position ticks can't act on the previous track's state.
  void _resetPerTrackState(JellyfinTrack track) {
    _hasScrobbled = false;
    _listenedTime.reset();
    _lyricsPrefetched = false;
    _positionFromPreviousTrack = false; // playTrack sets it again
    _fftStartOnResume = false; // the new track's start sets FFT up
    _pendingSeek = null; // a seek queued for the previous track's load
    _stallDetector.reset();
    _stallRecoveries = 0;
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
    unawaited(_adoptFinishedStreamCaches());
    // The player may know the real length better than metadata (and a
    // pre-loaded player's duration event fired before we attached).
    unawaited(_refreshDurationFromPlayer(track));

    // Counted by _checkPlayThreshold once the track has really been heard.
    _playCountPending = countPlay;

    // "Now playing" is live-only (not queued): offline it would only fail.
    if (!_isOffline) {
      unawaited(ListenBrainzService().submitNowPlaying(track));
      unawaited(LastFmService.instance.updateNowPlaying(track));
    }

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

    // Pre-cache upcoming tracks (user settings), a few seconds in so it
    // doesn't compete with this track's initial buffering.
    _preCacheTimer?.cancel();
    _preCacheTimer = Timer(const Duration(seconds: 5), () {
      if (_disposed || _currentTrack?.id != track.id) return;
      unawaited(_smartPreCacheUpcoming().catchError(
        (Object e) => debugPrint('📦 Pre-cache failed: $e'),
      ));
    });
  }

  /// Work that follows a track actually starting on the main player: iOS FFT
  /// (only when a visualizer wants it), waveform extraction, and a background
  /// copy of a streamed track (only when allowed, see
  /// [shouldCacheStreamingCopy]).
  void _afterTrackStarted(JellyfinTrack track) {
    final url = _currentSourceUrl;
    if (url == null || _currentTrack?.id != track.id) return;
    final isAsset = url.startsWith('assets/');
    if (_currentSourceIsLocal) {
      if (Platform.isIOS && _visualizerWanted && !isAsset) {
        unawaited(_startIOSFFTFor('file://$url', restart: true).catchError(
          (Object e) => debugPrint('🎵 iOS FFT start failed: $e'),
        ));
      }
      if (WaveformService.instance.isAvailable && !_batterySaverMode && !isAsset) {
        _extractWaveformForLocalFile(track, url);
      }
      return;
    }
    if (Platform.isIOS) {
      // Don't keep analysing the previous track while this one is cached.
      unawaited(IOSFFTService.instance.stopCapture());
      IOSFFTService.instance.resetUrl();
    }
    unawaited(_maybeCacheStreamingCopy(track, url).catchError(
      (Object e) => debugPrint('📥 Background copy failed: $e'),
    ));
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
        _audioHandler?.updateCurrentDuration(track.id, duration);
      }
    } catch (e) {
      debugPrint('⚠️ Duration refresh failed: $e');
    }
  }

  Future<void> _publishMediaItem(JellyfinTrack track) async {
    final offlineArtUri = await _getOfflineArtworkUri(track.id);
    if (_disposed || _currentTrack?.id != track.id) return;
    _audioHandler?.updateNautuneMediaItem(
      track,
      offlineArtUri: offlineArtUri,
      // The player's length beats metadata once this track is loaded (after
      // a gapless advance or crossfade its duration event came earlier).
      duration: _playerPositionIsCurrent ? _player.duration : null,
    );
  }

  Future<void> playTrack(
    JellyfinTrack track, {
    List<JellyfinTrack>? queueContext,
    String? albumId,
    String? albumName,
    bool reorderQueue = false,
    bool fromShuffle = false,
    int? queueIndex,
  }) =>
      _playTrack(
        track,
        queueContext: queueContext,
        albumId: albumId,
        albumName: albumName,
        reorderQueue: reorderQueue,
        fromShuffle: fromShuffle,
        queueIndex: queueIndex,
      );

  /// [playTrack] body. [direction] is where to look for a playable track if
  /// [track] has no local copy while offline (-1 for "previous");
  /// [offlineSkipBudget] bounds how many such skips one request chains.
  Future<void> _playTrack(
    JellyfinTrack track, {
    List<JellyfinTrack>? queueContext,
    String? albumId,
    String? albumName,
    bool reorderQueue = false,
    bool fromShuffle = false,
    int? queueIndex,
    int direction = 1,
    int? offlineSkipBudget,
  }) async {
    // Newest request wins: every await below re-checks this token.
    final requestId = ++_playRequestId;
    _playInFlight = requestId;
    try {
      await _playTrackRequest(
        track,
        requestId: requestId,
        queueContext: queueContext,
        reorderQueue: reorderQueue,
        fromShuffle: fromShuffle,
        queueIndex: queueIndex,
        direction: direction,
        offlineSkipBudget: offlineSkipBudget,
      );
    } finally {
      if (_playInFlight == requestId) _playInFlight = null;
    }
  }

  Future<void> _playTrackRequest(
    JellyfinTrack track, {
    required int requestId,
    List<JellyfinTrack>? queueContext,
    bool reorderQueue = false,
    bool fromShuffle = false,
    int? queueIndex,
    int direction = 1,
    int? offlineSkipBudget,
  }) async {
    bool isStale() => _disposed || requestId != _playRequestId;

    // A crossfade in progress would swap players underneath this request.
    if (_isCrossfading) _cancelCrossfade();
    // A new request replaces any automatic resume after an outage.
    _cancelResumeAfterOutage();

    // Close out the OUTGOING track before switching, so its listening time
    // and Jellyfin "stopped" are credited to it rather than to [track].
    _recordActualListeningTime();
    _creditListenTime(stillPlaying: isPlaying);
    _reportOutgoingStopped();
    _restoreBeginPending = false;
    _restoreSourcePending = false;
    _restorePrepareFuture = null;
    _pauseRequestedDuringLoad = false;
    _wasPlayingBeforeInterruption = false;
    _preCacheTimer?.cancel();

    _isShuffleEnabled = fromShuffle;
    _shuffleController.add(_isShuffleEnabled);
    if (!fromShuffle) _unshuffledQueue = null;

    // Cancel any in-flight waveform extraction from the previous track
    _waveformExtractionSub?.cancel();
    _waveformExtractionSub = null;

    // Queue + index are updated synchronously so rapid skips see them.
    // (Skips pass the current queue back in: same contents, no re-publish.)
    var queueChanged = true;
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
        queueChanged = !isInternalQueue || reorderQueue;
      }
    } else {
      _queue = <JellyfinTrack>[track];
      _currentIndex = 0;
    }

    _currentTrack = track;
    _currentTrackController.add(track);
    _resetPerTrackState(track);
    _positionFromPreviousTrack = true;
    _analyzeTrackForVisualizer(track); // Configure visualizer for track

    if (queueChanged) {
      // A different queue (not an advance within this one).
      _queueGeneration++;
      _onQueueContentChanged(publish: false);
    }

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

    // Generate a session ID to link the stream and the reporting
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    // Time-to-first-audio: the audio-session activation, the offline-artwork
    // lookup and the source resolution are independent, so run them
    // concurrently instead of back to back before the player is touched.
    //
    // CRITICAL: the audio session must be active before resume() (iOS can
    // deactivate it in the background or after interruptions).
    final sessionReady = _ensureSessionActiveForPlayback();
    _publishQueue();
    // Lock screen metadata as early as possible (the artwork lookup is local
    // and resolves well before a network source is ready).
    unawaited(_getOfflineArtworkUri(track.id)
        .catchError((Object _) => null)
        .then((offlineArtUri) {
      if (isStale()) return;
      _audioHandler?.updateNautuneMediaItem(track, offlineArtUri: offlineArtUri);
    }));

    // RESOLVE SOURCE BEFORE TOUCHING THE PLAYER
    // This minimizes "dead air" time which causes iOS background suspension
    final _ResolvedSource? resolved;
    try {
      resolved = await _resolvePlaybackSource(track, sessionId: sessionId);
    } catch (e) {
      if (isStale()) return;
      _onLoadFailed(track);
      rethrow;
    }
    await sessionReady;
    if (isStale()) return;

    if (resolved == null) {
      if (_isOffline) {
        // Not downloaded/cached and we can't stream: move on to the next
        // track that is, instead of failing (or hanging on a stream).
        await _skipUnavailableOffline(
          track,
          direction: direction,
          budget: offlineSkipBudget ?? _queue.length,
          isStale: isStale,
        );
        return;
      }
      _onLoadFailed(track);
      throw PlatformException(
        code: 'no_source',
        message: 'Unable to play ${track.name}. File may be unavailable.',
      );
    }

    final isDirectStream = resolved.isDirectStream;

    // Store whether this track is playing from local storage (for A-B loop support)
    _isCurrentTrackLocal = resolved.isLocalFile;

    // NOW we touch the player (serialised with other requests).
    // We don't explicitly call stop() because setSource will handle it,
    // and we want to minimize the gap.
    Future<_LoadOutcome> applySourceAndPlay(
      String url, {
      required bool isLocalFile,
      bool directStream = false,
    }) =>
        _withPlayerLock(requestId, () async {
          if (isStale()) return _LoadOutcome.superseded;
          final player = _player;
          final source = await _sourceFor(
            url,
            isLocalFile: isLocalFile,
            track: track,
            isDirectStream: directStream,
          );
          if (isStale()) return _LoadOutcome.superseded;
          await _loadMainSource(player, source);
          if (isStale()) return _LoadOutcome.superseded;
          _setCurrentSource(url, isLocal: isLocalFile);
          _isCurrentTrackLocal = isLocalFile;

          // A seek the user made while the source was loading.
          final seekTo = _pendingSeek;
          _pendingSeek = null;
          if (seekTo != null && seekTo > Duration.zero) {
            await player.seek(seekTo);
            if (isStale()) return _LoadOutcome.superseded;
          }

          // Apply ReplayGain normalization
          final adjustedVolume = _volume * _gainFor(track);
          await player.setVolume(adjustedVolume.clamp(0.0, 1.0));
          if (track.normalizationGain != null) {
            debugPrint('🔊 Applied ReplayGain: ${track.normalizationGain} dB');
          }
          if (isStale()) return _LoadOutcome.superseded;

          // The user paused while it was loading: leave it loaded, paused.
          if (_pauseRequestedDuringLoad) {
            _pauseRequestedDuringLoad = false;
            return _LoadOutcome.loadedPaused;
          }

          await player.resume();
          return isStale() ? _LoadOutcome.superseded : _LoadOutcome.started;
        });

    String playMethod = resolved.playMethod;
    _LoadOutcome outcome;
    try {
      try {
        outcome = await applySourceAndPlay(
          resolved.url,
          isLocalFile: resolved.isLocalFile,
          directStream: !resolved.isLocalFile && isDirectStream,
        );
      } on PlatformException {
        if (isStale()) return;
        final String? fallbackUrl;
        var fallbackIsDirect = false;
        if (resolved.isLocalFile && !resolved.isDownloaded && resolved.streamUrl != null &&
            !_isOffline &&
            !resolved.url.startsWith('assets/') && resolved.url != track.assetPathOverride) {
          // A pre-cached copy AVPlayer can't open (e.g. an Opus/Vorbis file
          // cached from the raw-file endpoint by an older build): drop it and
          // stream instead.
          debugPrint('⚠️ Cached copy failed to load, discarding it and streaming...');
          unawaited(_audioCacheService.removeFromCache(track.id));
          fallbackUrl = resolved.streamUrl;
          fallbackIsDirect = isDirectStream;
          playMethod = isDirectStream ? 'DirectStream' : 'Transcode';
        } else if (!resolved.isLocalFile && isDirectStream) {
          // The original file was served but AVPlayer couldn't open it:
          // force a server-side transcode (linked to our session id).
          debugPrint('⚠️ Direct stream failed, trying transcoded stream...');
          fallbackUrl = track.transcodedStreamUrl(
            deviceId: _deviceId,
            audioBitrate: 320000,
            audioCodec: _transcodeCodec.audioCodec,
            container: _transcodeCodec.container,
            playSessionId: sessionId,
          );
          playMethod = 'Transcode';
        } else {
          fallbackUrl = null;
        }
        if (fallbackUrl == null) rethrow;
        outcome = await applySourceAndPlay(
          fallbackUrl,
          isLocalFile: false,
          directStream: fallbackIsDirect,
        );
      }
    } catch (e) {
      // A superseded request's failure is irrelevant (e.g. its load was cut
      // off by the newer request).
      if (isStale()) return;
      _onLoadFailed(track);
      rethrow;
    }
    if (outcome == _LoadOutcome.superseded) return;

    if (outcome == _LoadOutcome.loadedPaused) {
      // Loaded but paused by the user mid-load: start-of-track bookkeeping
      // runs when they press play.
      _lastPlayingState = false;
      _playingController.add(false);
      _restoreBeginPending = true;
      _restoreCountsPlay = true;
      _restorePlayMethod = playMethod;
      _restoreSessionId = sessionId;
      unawaited(_audioHandler?.forceBroadcastCurrentState());
      await _stateStore.savePlaybackSnapshot(
        currentTrack: _currentTrack,
        position: _lastPosition,
        queue: _queueToPersist(),
        currentQueueIndex: _currentIndex,
        isPlaying: false,
        repeatMode: _repeatMode.name,
        shuffleEnabled: _isShuffleEnabled,
      );
      return;
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

    // FFT (visualizer), waveform, and — only when allowed — a background
    // copy of a streamed track. Started only now that audio is playing, so it
    // never competes with the stream's initial buffering.
    _afterTrackStarted(track);

    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: Duration.zero,
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      isPlaying: true,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
    );
  }

  /// Offline, [track] (the current queue slot) has no local copy: play the
  /// next slot in [direction] that has one (wrapping under repeat-all) and
  /// say what was skipped. When there is none, [track] is left paused (play
  /// retries) with a message. Each hop spends one of [budget], so tracks
  /// whose local copy vanished can't make this loop.
  Future<void> _skipUnavailableOffline(
    JellyfinTrack track, {
    required int direction,
    required int budget,
    required bool Function() isStale,
  }) async {
    final from = _currentIndex;
    final cachedIds = await _offlineCachedTrackIds();
    if (isStale()) return;
    final queue = _queue;
    bool playable(int i) => _hasLocalCopy(queue[i], cachedIds);
    final target = budget <= 0
        ? -1
        : nextPlayableIndex(
            length: queue.length,
            from: from,
            direction: direction,
            wrap: _repeatMode == RepeatMode.all,
            isPlayable: playable,
          );
    if (target == -1) {
      _onLoadFailed(track);
      // Anything playable at all (ignoring direction / repeat)?
      final anyPlayable = nextPlayableIndex(
            length: queue.length,
            from: from,
            direction: 1,
            wrap: true,
            isPlayable: playable,
          ) !=
          -1;
      final String reason;
      if (!anyPlayable) {
        reason = 'nothing in the queue is available offline';
      } else if (budget <= 0) {
        reason = 'couldn\'t open the downloaded tracks after it';
      } else {
        reason = direction > 0
            ? 'no more downloaded tracks in the queue'
            : 'no earlier downloaded tracks in the queue';
      }
      _playbackErrorController.add('“${track.name}” isn\'t downloaded — $reason');
      return;
    }
    final skipped = queueStepsBetween(
      length: _queue.length,
      from: from,
      target: target,
      direction: direction,
    );
    debugPrint('📴 Offline: skipping $skipped unavailable track(s) → ${_queue[target].name}');
    _playbackErrorController.add(_skippedMessage(track, skipped));
    await _playTrack(
      _queue[target],
      queueContext: _queue,
      fromShuffle: _isShuffleEnabled,
      queueIndex: target,
      direction: direction,
      offlineSkipBudget: budget - 1,
    );
  }

  /// A load for the current [track] failed: leave a coherent, resumable
  /// state instead of a player that claims to be playing silence. Nothing is
  /// loaded, so show paused and (re)load it on the next play.
  void _onLoadFailed(JellyfinTrack track) {
    if (_disposed || _currentTrack?.id != track.id) return;
    _lastPlayingState = false;
    _playingController.add(false);
    _currentSourceUrl = null;
    _positionFromPreviousTrack = false;
    _restoreSourcePending = true;
    _restoreBeginPending = true;
    _restoreCountsPlay = true;
    _restoreSessionId = null;
    unawaited(() async {
      try {
        // Updates the Dart-side state (isPlaying, lock screen) — the native
        // player has no item after the failure.
        await _player.pause();
        await _audioHandler?.forceBroadcastCurrentState();
      } catch (e) {
        debugPrint('⚠️ Could not settle player after load failure: $e');
      }
    }());
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
    // Upcoming tracks are pre-cached from _onTrackBegan (all play paths).
  }

  /// Pre-cache the next [_preCacheTrackCount] queue slots (user setting,
  /// Wi-Fi-only honoured), skipping downloaded tracks, at the user's
  /// streaming quality so a pre-cached track costs no more data than
  /// streaming it would.
  Future<void> _smartPreCacheUpcoming() async {
    final count = _preCacheTrackCount;
    if (count <= 0 || _batterySaverMode || _isOffline) return;
    if (PowerModeService.instance.isLowPowerMode) return;
    final queue = List<JellyfinTrack>.of(_queue);
    final start = _currentIndex + 1;
    final end = (start + count).clamp(0, queue.length);
    final seen = <String>{};
    final candidates = <JellyfinTrack>[];
    for (var i = start; i < end; i++) {
      final track = queue[i];
      if (!seen.add(track.id)) continue;
      if (track.assetPathOverride != null) continue;
      if (await _downloadService?.getLocalPath(track.id) != null) continue;
      candidates.add(track);
    }
    if (candidates.isEmpty) return;
    await _audioCacheService.smartPreCacheQueue(
      tracks: candidates,
      urlFor: (t) => _getStreamUrl(t).$1,
      wifiOnly: _wifiOnlyCaching,
      connectivityService: _connectivityService,
    );
  }
  
  Future<void> pause() => _pauseInternal();

  /// [fromUser]: an explicit pause (UI, lock screen, headphones unplugged)
  /// cancels any pending auto-resume after an interruption; the interruption
  /// handler's own pause doesn't. [fade]: 400 ms fade-out first.
  Future<void> _pauseInternal({bool fromUser = true, bool fade = true}) async {
    _pauseSerial++;
    if (fromUser) {
      HapticService.lightTap();
      _wasPlayingBeforeInterruption = false;
      _cancelResumeAfterOutage();
    }
    // A track is still being resolved or (re)loaded: make sure it doesn't
    // start once ready.
    if (_sourceLoadToken != null ||
        _playInFlight != null ||
        _stallRecoveryInFlight ||
        _restorePrepareFuture != null) {
      _pauseRequestedDuringLoad = true;
    }
    // The incoming crossfade player isn't the one being paused: drop the
    // crossfade (it re-triggers after resume if still near the end).
    if (_isCrossfading) _cancelCrossfade();
    // Returns false if resume() took over during the fade-out.
    if (!await _fadeOutAndPause(fade: fade)) return;
    if (_playerPositionIsCurrent) {
      final position = await _player.getCurrentPosition();
      if (position != null) _lastPosition = position;
    }
    _emitIdleVisualizer();
    // Ensure OS has correct paused state with updated position so lock screen
    // controls remain interactive after pausing from the app
    await _audioHandler?.forceBroadcastCurrentState();
    // Save full playback state including queue so user can resume at exact position
    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: _lastPosition,
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      isPlaying: false,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
      volume: _volume,
    );
  }
  
  Future<void> resume() async {
    HapticService.lightTap();
    // The user's play supersedes an automatic resume after an outage.
    _cancelResumeAfterOutage();
    await _resumeInternal();
  }

  /// [resume] body. Returns false if the deferred track couldn't be loaded.
  /// [afterOutage]: an automatic retry once the network is back (see
  /// [_armResumeAfterOutage]) — no offline skipping, no error message.
  Future<bool> _resumeInternal({bool afterOutage = false}) async {
    // Nothing loaded (stopped / queue finished): "playing" would be a lie.
    if (_currentTrack == null) return true;
    _wasPlayingBeforeInterruption = false;
    _pauseRequestedDuringLoad = false;
    // A track is being resolved/loaded: it starts by itself once ready
    // (resuming now would only restart the outgoing track for a moment).
    if (_playInFlight != null) return true;
    await _ensureSessionActiveForPlayback();
    // Deferred track (restored session, failed or interrupted load, sleep
    // timer stop): load its source now, or wait for the background load.
    if (_restoreSourcePending) {
      final track = _currentTrack;
      final pauseSerial = _pauseSerial;
      if (!await _prepareRestoredSource()) {
        if (afterOutage) return false;
        if (!_disposed && track != null && _currentTrack?.id == track.id) {
          if (_isOffline &&
              !_hasLocalCopy(track, await _offlineCachedTrackIds()) &&
              _currentTrack?.id == track.id) {
            // Offline and this track was never downloaded: continue with
            // the next one that was.
            final requestId = ++_playRequestId;
            await _skipUnavailableOffline(
              track,
              direction: 1,
              budget: _queue.length,
              isStale: () => _disposed || requestId != _playRequestId,
            );
            return true;
          }
          _playbackErrorController.add('Unable to play ${track.name}. Check your connection.');
        }
        return false;
      }
      // Paused / headphones unplugged / call started while it loaded: leave
      // it loaded and paused.
      if (afterOutage && _resumeAfterOutageTrackId == null) return true;
      if (_pauseSerial != pauseSerial || _pauseRequestedDuringLoad) {
        _pauseRequestedDuringLoad = false;
        return true;
      }
    }
    // The track already ended while paused (e.g. paused during a crossfade
    // after the outgoing track finished): continue with the next one.
    if (_player.state == EngineState.completed) {
      // (An advance already under way starts the next track itself.)
      if (!_isTransitioning && !_advanceInFlight) await _gaplessTransition();
      return true;
    }
    await _resumeAndFadeIn();
    final fftDeferred = _fftStartOnResume;
    _fftStartOnResume = false;
    if (_restoreBeginPending) {
      // _beginRestoredTrack starts FFT itself (_afterTrackStarted).
      _restoreBeginPending = false;
      final track = _currentTrack;
      if (track != null) _beginRestoredTrack(track);
    } else if (fftDeferred && _visualizerWanted && isPlaying) {
      unawaited(_startFftForCurrentTrack().catchError(
        (Object e) => debugPrint('🎵 iOS FFT start failed: $e'),
      ));
    }
    await _stateStore.savePlaybackSnapshot(isPlaying: true);
    await _audioHandler?.forceBroadcastCurrentState();
    return true;
  }

  /// Load the deferred current track's source (see [_restoreSourcePending]).
  /// Concurrent callers (background restore + play button, play pressed
  /// twice) share one load.
  Future<bool> _prepareRestoredSource() {
    final existing = _restorePrepareFuture;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _doPrepareRestoredSource().whenComplete(() {
      if (identical(_restorePrepareFuture, future)) _restorePrepareFuture = null;
    });
    _restorePrepareFuture = future;
    return future;
  }

  Future<bool> _doPrepareRestoredSource() async {
    final track = _currentTrack;
    if (track == null) return false;
    final requestId = _playRequestId;
    bool superseded() =>
        _disposed || requestId != _playRequestId || _currentTrack?.id != track.id;
    try {
      final resolved = await _resolvePlaybackSource(track);
      if (superseded()) return false;
      if (resolved == null) return false;
      final loaded = await _withPlayerLock(requestId, () async {
        if (superseded()) return false;
        final player = _player;
        // _lastPosition holds the restored position and any seek made
        // since. Read it before loading: the load reports position 0.
        final resumeAt = _lastPosition;
        await _loadMainSource(
          player,
          await _sourceFor(
            resolved.url,
            isLocalFile: resolved.isLocalFile,
            track: track,
            isDirectStream: !resolved.isLocalFile && resolved.isDirectStream,
          ),
        );
        if (superseded()) return false;
        _setCurrentSource(resolved.url, isLocal: resolved.isLocalFile);
        _isCurrentTrackLocal = resolved.isLocalFile;
        _restorePlayMethod = resolved.playMethod;
        _restoreSourcePending = false;
        // A seek made while it loaded wins.
        final seekTo = _pendingSeek ?? resumeAt;
        _pendingSeek = null;
        if (seekTo > Duration.zero) {
          _lastPosition = seekTo;
          _positionController.add(seekTo);
          await player.seek(seekTo);
        }
        if (!superseded()) {
          await player.setVolume(
            (_volume * _gainFor(track)).clamp(0.0, 1.0),
          );
        }
        return true;
      });
      return loaded && !superseded();
    } catch (e) {
      debugPrint('⚠️ Failed to load deferred track: $e');
      return false;
    }
  }

  /// First resume of a deferred track (see [_restoreBeginPending]).
  ///
  /// For a restored session the play count is NOT incremented: it was
  /// counted when the track originally started, and this is a continuation
  /// of that play. Listening time/history, the Jellyfin start report and
  /// "now playing" do run, since the previous launch never closed them out.
  /// If the restored position is already past the scrobble point, the
  /// previous launch scrobbled it, so it is not scrobbled again.
  void _beginRestoredTrack(JellyfinTrack track) {
    final countsPlay = _restoreCountsPlay;
    _onTrackBegan(
      track,
      playMethod: _restorePlayMethod,
      sessionId: _restoreSessionId,
      countPlay: countsPlay,
      resetState: false,
      publishMediaItem: true,
    );
    _restoreCountsPlay = false;
    _restoreSessionId = null;
    final duration = track.duration ?? _cachedDuration;
    if (countsPlay) {
      // A track that never started (parked, failed load): only what is
      // heard from now on counts, not a position seeked to before playing.
      _listenedTime.reset();
    } else if (duration != null &&
        duration > Duration.zero &&
        _lastPosition.inSeconds >= scrobbleThresholdSeconds(duration)) {
      _hasScrobbled = true;
    } else {
      // Credit what the previous launch already played of this track.
      _listenedTime.reset(_lastPosition);
    }
    _afterTrackStarted(track);
  }
  
  // Fade helpers
  Future<bool> _fadeOutAndPause({bool fade = true}) async {
    final generation = ++_fadeGeneration;
    final player = _player;

    if (fade) {
      // Quick fade out (400ms total, 20Hz) from the player's *current*
      // volume — it may already be lowered (sleep-timer fade, mid-crossfade),
      // and fading from the user volume would first jump back up.
      const steps = 8;
      const stepDuration = Duration(milliseconds: 50);
      final startVolume = player.volume;
      for (int i = 0; i < steps; i++) {
        // Stop fading if resume() took over or the players were swapped;
        // the pause below still applies to whatever is current.
        if (generation != _fadeGeneration || !identical(player, _player)) break;
        await player.setVolume((startVolume * (1.0 - ((i + 1) / steps))).clamp(0.0, 1.0));
        await Future.delayed(stepDuration);
      }
    }

    // The user pressed play during the fade-out: don't pause after all.
    if (generation != _fadeGeneration) return false;
    await _player.pause();
    // Restore the user's volume (with ReplayGain) for the next play.
    await _applyUserVolumeToPlayer();
    return true;
  }

  Future<void> _resumeAndFadeIn() async {
    final generation = ++_fadeGeneration;
    final player = _player;

    // Start silent
    await player.setVolume(0.0);
    await player.resume();

    // Quick fade in (gentler: 400ms total, 20Hz update rate)
    const steps = 8;
    const stepDuration = Duration(milliseconds: 50);
    final targetVolume = _volume;
    final currentMultiplier = _gainFor(_currentTrack);

    for (int i = 1; i <= steps; i++) {
      // A pause (or another fade) took over.
      if (generation != _fadeGeneration || !identical(player, _player)) return;
      await Future.delayed(stepDuration);
      if (generation != _fadeGeneration || !identical(player, _player)) return;
      final vol = targetVolume * (i / steps);
      await player.setVolume((vol * currentMultiplier).clamp(0.0, 1.0));
    }
  }
  
  Future<void> seek(Duration position) async {
    // Clamp position to valid range to prevent seeking beyond track bounds
    final duration = _cachedDuration ?? _currentTrack?.duration;
    final clampedPosition = duration != null
        ? Duration(milliseconds: position.inMilliseconds.clamp(0, duration.inMilliseconds))
        : position;

    // A crossfade into the next track was started from the old position:
    // the user moved away from the end, so call it off (it re-triggers when
    // the end comes around again). The outgoing volume is restored by the
    // crossfade's abort path.
    if (_isCrossfading) _cancelCrossfade();

    // Let the once-per-second threshold checks (preload, crossfade,
    // scrobble, lyrics) run on the next tick, including after backward seeks.
    _lastThresholdCheckMs = clampedPosition.inMilliseconds - 1000;
    _stallDetector.reset();

    // Update position immediately for responsive UI (before player confirms)
    _lastPosition = clampedPosition;
    // After a seek, the next periodic save should write the new position.
    _lastSavedPositionMs = null;
    _positionController.add(clampedPosition);

    if (_sourceLoadToken != null ||
        _playInFlight != null ||
        _restoreSourcePending ||
        !_player.hasSource) {
      // The source is still being resolved or loading (AVPlayerItem throws
      // if asked to seek before it is ready), not loaded yet (deferred
      // track), or already
      // released (finished track). Apply it once loaded instead.
      _pendingSeek = clampedPosition;
    } else {
      // Perform the actual seek
      await _player.seek(clampedPosition);
    }
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
    // (not awaited: it must not delay the skip).
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.stopCapture());
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

  /// "Previous" from the app, lock screen or CarPlay: restarts the current
  /// track when more than 3 s in, otherwise goes to the previous track (see
  /// [resolvePreviousAction]).
  Future<void> skipToPrevious() async {
    HapticService.mediumTap();

    final action = resolvePreviousAction(
      // Mid-switch the position still belongs to the outgoing track.
      position: _positionFromPreviousTrack ? Duration.zero : _lastPosition,
      currentIndex: _currentIndex,
      queueLength: _currentTrack == null ? 0 : _queue.length,
      repeatAll: _repeatMode == RepeatMode.all,
    );
    final int targetIndex;
    switch (action) {
      case PreviousAction.none:
        return;
      case PreviousAction.restartCurrent:
        final canReload = _currentIndex >= 0 && _currentIndex < _queue.length;
        if (!_isCrossfading || !canReload) {
          // Same track keeps playing: no listen-time record, FFT stays
          // running (seek re-syncs it).
          await seek(Duration.zero);
          return;
        }
        // Mid-crossfade the next track is already fading in: reload this
        // one from the start instead (playTrack cancels the crossfade).
        targetIndex = _currentIndex;
      case PreviousAction.previousTrack:
        targetIndex = _currentIndex - 1;
      case PreviousAction.wrapToLast:
        targetIndex = _queue.length - 1;
    }

    // Record actual listening time before skipping
    _recordActualListeningTime();

    // Stop FFT before switching tracks to prevent concurrent shadow players
    // (not awaited: it must not delay the skip).
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.stopCapture());
    }

    try {
      _currentIndex = targetIndex;
      await _playTrack(
        _queue[_currentIndex],
        queueContext: _queue,
        fromShuffle: _isShuffleEnabled,
        queueIndex: _currentIndex,
        // Offline, skip back past tracks that aren't downloaded.
        direction: action == PreviousAction.restartCurrent ? 1 : -1,
      );
    } catch (e) {
      debugPrint('❌ Skip to previous failed: $e');
      rethrow;
    }
  }

  // ========== VISUALIZER DEMAND / BACKGROUND COPY ==========

  /// Whether the iOS FFT shadow player is wanted: only while something that
  /// renders FFT is on screen (see [retainVisualizer]).
  bool get _visualizerWanted => _visualizerViewers > 0;

  /// A visualizer became visible. Visualizer widgets should call this in
  /// initState (and [releaseVisualizer] in dispose) so the FFT shadow player
  /// — and the extra download it needs for streamed tracks — only runs while
  /// one is on screen.
  void retainVisualizer() {
    final before = _visualizerViewers;
    _visualizerViewers = before + 1;
    if (before != 0) return;
    if (isPlaying) {
      unawaited(_startFftForCurrentTrack().catchError(
        (Object e) => debugPrint('🎵 iOS FFT start failed: $e'),
      ));
    } else {
      _fftStartOnResume = true;
    }
  }

  /// The main player paused (or finished): stop the FFT shadow player too,
  /// or it keeps decoding (and looping its last second) while nothing
  /// plays. Not while a track is being (re)loaded — the new track's start
  /// sets FFT up itself. It restarts on the next play.
  void _pauseFftCapture() {
    if (!Platform.isIOS || !_visualizerWanted) return;
    final fft = IOSFFTService.instance;
    // Only our own capture: an Easter egg may have pointed it elsewhere.
    if (!fft.isCapturing || fft.currentUrl == null || fft.currentUrl != _fftUrl) {
      return;
    }
    if (_playInFlight != null || _sourceLoadToken != null || _stallRecoveryInFlight) {
      return;
    }
    _fftStartOnResume = _visualizerWanted;
    unawaited(IOSFFTService.instance.stopCapture());
  }

  /// A visualizer was hidden/disposed (see [retainVisualizer]).
  void releaseVisualizer() {
    final after = (_visualizerViewers - 1).clamp(0, 1 << 30);
    _visualizerViewers = after;
    if (after == 0) {
      _fftStartOnResume = false;
      if (Platform.isIOS) unawaited(IOSFFTService.instance.stopCapture());
    }
  }

  /// Point the FFT shadow player at the current track (local file, cached
  /// copy, or — when allowed — a fresh background copy).
  Future<void> _startFftForCurrentTrack() async {
    if (!Platform.isIOS || !_visualizerWanted) return;
    final track = _currentTrack;
    final url = _currentSourceUrl;
    if (track == null || url == null) return;
    if (_currentSourceIsLocal) {
      if (!url.startsWith('assets/')) {
        await _startIOSFFTFor('file://$url', restart: true);
      }
      return;
    }
    final cached = await _audioCacheService.getCachedFile(track.id);
    if (cached != null) {
      await _startFftFromFile(track, cached.path);
      return;
    }
    await _maybeCacheStreamingCopy(track, url);
  }

  /// Download a background copy of the *streaming* [track] when something
  /// needs it — iOS FFT (visualizer on screen), or the audio cache (A-B loop,
  /// waveform, offline replay; off when the user set pre-cache to 0) — and
  /// only on Wi-Fi outside Low Power Mode / battery saver. The stream itself
  /// already downloads this audio, so the copy doubles the bandwidth; on
  /// cellular it used to be made for every streamed track.
  Future<void> _maybeCacheStreamingCopy(JellyfinTrack track, String streamUrl) async {
    final wantFft = Platform.isIOS && _visualizerWanted;
    // The stream itself is being saved while it plays: use that file
    // instead of downloading the track a second time.
    final streamCache = _streamCacheFiles[track.id];
    if (streamCache != null) {
      final file = await _awaitStreamCache(track, streamCache);
      if (file == null || _disposed || _currentTrack?.id != track.id) return;
      _isCurrentTrackLocal = true; // A-B loop can use the complete copy
      if (wantFft) await _startFftFromFile(track, file.path);
      return;
    }
    final wanted = wantFft || _preCacheTrackCount > 0;
    if (!wanted) return;
    final connectivity = _connectivityService;
    final onWifi = connectivity != null && await connectivity.isOnWifi();
    final allowed = shouldCacheStreamingCopy(
      wanted: wanted,
      onWifi: onWifi,
      lowPowerMode: PowerModeService.instance.isLowPowerMode,
      batterySaver: _batterySaverMode,
    );
    if (!allowed) {
      debugPrint('📥 Skipping background copy of ${track.name} (not on Wi-Fi / power saving)');
      return;
    }
    if (_disposed || _currentTrack?.id != track.id) return;

    final cachedFile = await _audioCacheService.cacheTrack(track, streamUrl: streamUrl);
    if (cachedFile == null) {
      debugPrint('⚠️ Background copy failed for ${track.name}');
      return;
    }
    if (_disposed || _currentTrack?.id != track.id) return;
    // A-B loop needs a local copy.
    _isCurrentTrackLocal = true;
    if (Platform.isIOS && _visualizerWanted) {
      await _startFftFromFile(track, cachedFile.path);
    }
  }

  // ---------------------------------------------------------------------------
  // Stream cache: untranscoded streams are saved while they play
  // (just_audio LockCachingAudioSource), then moved into the audio cache.
  // ---------------------------------------------------------------------------

  /// Stream-cache file per track id, for tracks loaded in this session.
  final Map<String, File> _streamCacheFiles = {};
  Directory? _streamCacheDir;

  Future<Directory> _streamCacheDirectory() async {
    final existing = _streamCacheDir;
    if (existing != null) return existing;
    final dir = Directory('${(await getTemporaryDirectory()).path}/nautune_stream_cache');
    await dir.create(recursive: true);
    return _streamCacheDir = dir;
  }

  /// File to save [track]'s stream from [url] into while it plays, or null
  /// when caching is off (pre-cache set to 0 and no visualizer showing) or
  /// not allowed right now ([shouldSaveStreamWhilePlaying]): for the
  /// pre-cache and for tracks loaded ahead, the background-copy policy
  /// (Wi-Fi only, not in Low Power Mode / battery saver) — a saved stream
  /// keeps downloading to the end even after the track is skipped, so on
  /// cellular it would cost the whole file for every skipped track. The
  /// track playing now is also saved off Wi-Fi while an iOS visualizer is
  /// on screen: the FFT needs a local copy of it.
  ///
  /// Every load gets its own file (`<encoded key>~<unique>`): two loads of
  /// the same track (skip back, repeat) must never write the same partial
  /// file at once. [_adoptFinishedStreamCaches] recovers the key.
  Future<File?> _streamCacheFileFor(JellyfinTrack track, String url) async {
    final visualizerWanted = Platform.isIOS && _visualizerWanted;
    final wantedForCache = _preCacheTrackCount > 0;
    if ((!wantedForCache && !visualizerWanted) || _isOffline) return null;
    final networkCheck = _networkTypeRefresh;
    if (networkCheck != null) {
      await networkCheck.timeout(const Duration(seconds: 1), onTimeout: () {});
    }
    final allowed = shouldSaveStreamWhilePlaying(
      wantedForCache: wantedForCache,
      visualizerWanted: visualizerWanted,
      isCurrentTrack: _currentTrack?.id == track.id,
      onWifi: _connectivityService != null && _cachedNetworkType == _NetworkType.wifi,
      lowPowerMode: PowerModeService.instance.isLowPowerMode,
      batterySaver: _batterySaverMode,
    );
    if (!allowed) return null;
    try {
      final dir = await _streamCacheDirectory();
      final key = audioCacheKey(track.id, cacheVariantForUrl(url));
      final unique = '${DateTime.now().microsecondsSinceEpoch}${_streamCacheSerial++}';
      final file = File('${dir.path}/${streamCacheFileName(key, unique)}');
      _streamCacheFiles[track.id] = file;
      return file;
    } catch (e) {
      debugPrint('⚠️ Stream cache unavailable: $e');
      return null;
    }
  }

  int _streamCacheSerial = 0;
  bool _adoptingStreamCaches = false;

  /// Remove partial downloads (and their `.mime` files) left behind by a
  /// previous run that was killed mid-download; nothing else ever finishes
  /// or deletes them.
  Future<void> _cleanStaleStreamCache() async {
    try {
      final dir = await _streamCacheDirectory();
      final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        try {
          if (path.endsWith('.part')) {
            if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
          } else if (path.endsWith('.mime')) {
            final base = path.substring(0, path.length - '.mime'.length);
            if (!await File(base).exists() && !await File('$base.part').exists()) {
              await entity.delete();
            }
          }
        } catch (e) {
          debugPrint('⚠️ Stream cache cleanup skipped $path: $e');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Stream cache cleanup failed: $e');
    }
  }

  /// Wait until [track]'s stream has been saved completely (while it is
  /// still the current track).
  Future<File?> _awaitStreamCache(JellyfinTrack track, File file) async {
    for (var i = 0; i < 900; i++) {
      if (await file.exists()) return file;
      if (_disposed || _currentTrack?.id != track.id) return null;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// Move completely saved streams of tracks that are no longer playing or
  /// queued into the audio cache (counted in its 2 GiB budget, LRU).
  Future<void> _adoptFinishedStreamCaches() async {
    final dir = _streamCacheDir;
    // One pass at a time (two would adopt and delete the same file).
    if (dir == null || _adoptingStreamCaches) return;
    _adoptingStreamCaches = true;
    try {
      if (!await dir.exists()) return;
      final live = {
        for (final id in [_currentTrack?.id, _preloadedTrack?.id])
          if (id != null && _streamCacheFiles[id] != null) _streamCacheFiles[id]!.path,
      };
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final path = entity.path;
        if (path.endsWith('.part') || path.endsWith('.mime') || live.contains(path)) {
          continue;
        }
        try {
          final key = streamCacheKeyFromFileName(path.split('/').last);
          final mimeFile = File('$path.mime');
          final mime = await mimeFile.exists() ? await mimeFile.readAsString() : '';
          await _audioCacheService.adoptFile(key, entity, audioExtensionForMime(mime));
          await entity.delete();
          if (await mimeFile.exists()) await mimeFile.delete();
          _streamCacheFiles.removeWhere((_, f) => f.path == path);
        } catch (e) {
          debugPrint('⚠️ Adopting $path failed: $e');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Adopting stream cache failed: $e');
    } finally {
      _adoptingStreamCaches = false;
    }
  }

  /// Start FFT capture from a local copy of the playing [track], synced to
  /// the current position. Capture only starts in the foreground.
  Future<void> _startFftFromFile(JellyfinTrack track, String filePath) async {
    if (!Platform.isIOS) return;
    final trackId = track.id;
    final fft = IOSFFTService.instance;
    _fftUrl = 'file://$filePath';
    await fft.setAudioUrl('file://$filePath');
    if (_currentTrack?.id != trackId) return;

    // Sync to current playback position BEFORE starting capture
    final currentPosMs = _lastPosition.inMilliseconds.toDouble() / 1000.0;
    await fft.syncPosition(currentPosMs);

    // Don't start the shadow player while backgrounded (the URL is set so it
    // resumes on return to foreground) or when no visualizer is showing.
    if (_currentTrack?.id != trackId || !_isAppInForeground || !_visualizerWanted) {
      return;
    }
    await fft.startCapture();

    // Sync again after a short delay to ensure accuracy
    await Future.delayed(const Duration(milliseconds: 100));
    if (_currentTrack?.id == trackId) {
      final updatedPos = _lastPosition.inMilliseconds.toDouble() / 1000.0;
      await fft.syncPosition(updatedPos);
    }
    debugPrint('🎵 iOS FFT: Started from local copy of ${track.name}');
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
    _stopping = true;
    try {
      await _stopInternal();
    } finally {
      _stopping = false;
    }
  }

  Future<void> _stopInternal() async {
    // Supersede any in-flight playTrack/gapless request so it can't resume
    // audio after we stop.
    final stopId = ++_playRequestId;
    // A play request made while this awaits below wins: don't clear the
    // track and queue it just set up.
    bool superseded() => _disposed || stopId != _playRequestId;
    _playInFlight = null;
    // A deferred restore must not bring the queue back.
    _pendingState = null;
    _restoreGeneration++;
    _cancelResumeAfterOutage();
    _restoreBeginPending = false;
    _restoreSourcePending = false;
    _restorePrepareFuture = null;
    _pauseRequestedDuringLoad = false;
    _wasPlayingBeforeInterruption = false;
    _pendingSeek = null;
    _preCacheTimer?.cancel();
    if (_isCrossfading) _cancelCrossfade();
    // Don't leave the next track buffering in the background.
    _clearPreload();

    // Record actual listening time before stopping
    _recordActualListeningTime();
    _creditListenTime(stillPlaying: false);

    // Report stop to Jellyfin (only for tracks whose start was reported).
    // Queued behind/ahead of other reports so it can't clear the session id
    // of a track started after it. Position captured before stopping.
    _reportOutgoingStopped();

    // 1. Stop audio immediately
    await _player.stop();
    if (superseded()) return;

    // Stop FFT capture
    if (Platform.isIOS) {
      await IOSFFTService.instance.stopCapture();
      if (superseded()) return;
    }

    // 2. CLEAR persistence so app starts fresh on next launch
    try {
      debugPrint('🧹 Clearing playback state on stop');
      await _stateStore.clearPlaybackData();
    } catch (e) {
      debugPrint('Error clearing playback state: $e');
    }
    // The new track saves its own state (after this clear, in call order).
    if (superseded()) return;

    // 3. CLEAR active memory state
    _currentTrack = null;
    _currentTrackController.add(null);
    _queue = [];
    _currentIndex = 0;
    _queueGeneration++;
    _onQueueContentChanged(publish: false);
    // The store's queue was just cleared.
    _persistedQueueVersion = _queueVersion;
    _lastPosition = Duration.zero;
    _isShuffleEnabled = false;
    _unshuffledQueue = null;
    _isCurrentTrackLocal = false;
    _currentSourceUrl = null;
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
    if (state == EngineState.playing) {
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
    _currentIndex = currentIndexAfterMove(
      currentIndex: _currentIndex,
      from: oldIndex,
      to: newIndex,
    );

    // The next track may have changed.
    _onQueueEdited();
    _onQueueContentChanged();
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      currentTrack: _currentTrack,
    ));
  }
  
  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    if (_queue.length == 1) return; // Don't remove last track

    final lengthBefore = _queue.length;
    _queue.removeAt(index);

    // Update current index if affected
    final removedCurrent = index == _currentIndex;
    // The playing track was the last one: nothing takes its slot. Repeat-all
    // continues from the top; otherwise the queue has ended, so the new last
    // (already played) track is shown paused instead of replayed.
    final removedLast = removedCurrent && index == lengthBefore - 1;
    final wrap = _repeatMode == RepeatMode.all;
    _currentIndex = currentIndexAfterRemoval(
      currentIndex: _currentIndex,
      removedIndex: index,
      lengthBefore: lengthBefore,
      wrap: wrap,
    );
    // The next track may have changed (playTrack below clears it anyway).
    _onQueueEdited();
    _onQueueContentChanged();
    if (removedCurrent && _queue.isNotEmpty) {
      final wasPlaying = (isPlaying || _lastPlayingState || _playInFlight != null) &&
          !(removedLast && !wrap);
      if (wasPlaying) {
        // Removing the playing track: play the one that took its slot.
        unawaited(playTrack(
          _queue[_currentIndex],
          queueContext: _queue,
          fromShuffle: _isShuffleEnabled,
          queueIndex: _currentIndex,
        ).catchError((Object e) {
          debugPrint('❌ Playing after removal failed: $e');
          _playbackErrorController.add('Could not play ${_currentTrack?.name ?? 'the next track'}.');
        }));
      } else {
        // Paused (or the queue ended): show the track that took its slot,
        // paused.
        if (_isCrossfading) _cancelCrossfade();
        if (isPlaying) unawaited(_player.pause());
        _recordActualListeningTime();
        _reportOutgoingStopped();
        _parkOnQueueIndex(_currentIndex);
      }
    }

    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
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
    _currentIndex = currentIndexAfterInsert(
      currentIndex: _currentIndex,
      insertIndex: index,
    );

    _onQueueEdited();
    _onQueueContentChanged();

    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
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

    // The pre-loaded next track is no longer next
    _onQueueEdited();

    _onQueueContentChanged();

    debugPrint('▶️ Play Next: Added ${tracks.length} track(s) at position $insertIndex');

    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
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

    // Only matters if the current track was the last one
    _onQueueEdited();

    _onQueueContentChanged();

    debugPrint('➕ Add to Queue: Added ${tracks.length} track(s) to end of queue');

    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
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
  void _publishModes() {
    _audioHandler?.updateModes(
      shuffle: _isShuffleEnabled,
      repeat: switch (_repeatMode) {
        RepeatMode.off => audio_service.AudioServiceRepeatMode.none,
        RepeatMode.all => audio_service.AudioServiceRepeatMode.all,
        RepeatMode.one => audio_service.AudioServiceRepeatMode.one,
      },
    );
  }

  void setRepeatMode(RepeatMode mode) {
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    _clearPreload(); // the queued next track may no longer be next
    _repeatModeController.add(_repeatMode);
    unawaited(_stateStore.savePlaybackSnapshot(repeatMode: _repeatMode.name));
  }

  void toggleRepeatMode() {
    _clearPreload(); // the queued next track may no longer be next
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

  double _speed = 1.0;
  double get playbackSpeed => _speed;

  /// Playback speed (0.5-2.0); kept across tracks and applied to the
  /// crossfade player as well.
  Future<void> setPlaybackSpeed(double speed) async {
    _speed = speed.clamp(0.5, 2.0);
    _audioHandler?.updateSpeed(_speed);
    await _player.setSpeed(_speed);
  }

  bool _smartShuffle = true;
  bool get smartShuffleEnabled => _smartShuffle;
  void setSmartShuffleEnabled(bool enabled) => _smartShuffle = enabled;

  /// Shuffled copy of [tracks], smart (recency + artist spread) when
  /// enabled. [keepFirst] stays at the front.
  List<JellyfinTrack> _shuffled(List<JellyfinTrack> tracks, {int keepFirst = -1}) {
    if (!_smartShuffle) {
      return shuffleKeepingCurrent<JellyfinTrack>(tracks, keepFirst, Random());
    }
    return smartShuffle<JellyfinTrack>(
      tracks,
      lastPlayedOf: (t) => _playStats.getStats(t.id)?.lastPlayed,
      artistOf: (t) => t.displayArtist,
      random: Random(),
      now: DateTime.now(),
      keepFirst: keepFirst,
    );
  }

  /// Shuffle on/off for the current queue (the player's shuffle button).
  void toggleShuffle() {
    if (_isShuffleEnabled) {
      unshuffleQueue();
    } else {
      shuffleQueue();
    }
  }

  /// Turn shuffle off, restoring the pre-shuffle order when it is known.
  /// The current track keeps playing.
  void unshuffleQueue() {
    final original = _unshuffledQueue;
    if (original != null && _queue.isNotEmpty) {
      final hasCurrent = _currentIndex >= 0 && _currentIndex < _queue.length;
      final restored = restoreQueueOrder<JellyfinTrack>(
        original,
        _queue,
        hasCurrent ? _currentIndex : -1,
        (t) => t.id,
      );
      _queue = restored.queue;
      if (hasCurrent) _currentIndex = restored.index;
      _onQueueEdited();
      _onQueueContentChanged();
    }
    _unshuffledQueue = null;
    _isShuffleEnabled = false;
    _shuffleController.add(false);
    debugPrint('🌊 Shuffle off${original != null ? ', order restored' : ''}');
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      shuffleEnabled: false,
    ));
  }

  void shuffleQueue() {
    if (_queue.isEmpty) return;
    // Remember the order to restore (a re-shuffle keeps the first one).
    if (!_isShuffleEnabled || _unshuffledQueue == null) {
      _unshuffledQueue = List<JellyfinTrack>.of(_queue);
    }
    
    // Current track first, the rest shuffled. Only the current *slot* is
    // pulled out, so duplicates of the current track stay in the queue.
    final hasCurrent = _currentTrack != null &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length;
    _queue = _shuffled(_queue, keepFirst: hasCurrent ? _currentIndex : -1);
    if (hasCurrent) _currentIndex = 0;
    _onQueueEdited();
    _onQueueContentChanged();

    _isShuffleEnabled = true;
    _shuffleController.add(true);
    debugPrint('🌊 Queue shuffled: ${_queue.length} tracks');
    unawaited(_stateStore.savePlaybackSnapshot(
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      shuffleEnabled: _isShuffleEnabled,
    ));
  }
  
  Future<void> playShuffled(List<JellyfinTrack> tracks) async {
    if (tracks.isEmpty) return;
    
    final shuffled = _shuffled(tracks);
    _unshuffledQueue = List<JellyfinTrack>.of(tracks);
    await playTrack(
      shuffled.first,
      queueContext: shuffled,
      fromShuffle: true,
    );
    debugPrint('🌊 Playing shuffled: ${shuffled.length} tracks');
  }
  
  /// Check if we need to fetch more tracks for infinite radio mode
  Future<void> _checkInfiniteRadio() async {
    // Needs the server; offline it would only wait for a timeout.
    if (_isOffline) return;
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
    if (_isOffline) return;
    if (_infiniteRadioFetchCompleter != null || _jellyfinService == null || _currentTrack == null) {
      return;
    }

    _infiniteRadioFetchCompleter = Completer<void>();
    // Results for a queue the user has since replaced (played another
    // album/playlist, stopped) must not be appended to the new one. Advances
    // and skips within the same queue don't count (see _queueGeneration).
    final generation = _queueGeneration;
    bool queueReplaced() =>
        _disposed || !_infiniteRadioEnabled || _queueGeneration != generation;

    try {
      // Use current track to find similar tracks
      final mixTracks = await _jellyfinService!.getInstantMix(
        itemId: _currentTrack!.id,
        limit: 20, // Fetch 20 tracks at a time
      );
      if (queueReplaced()) return;

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
        if (queueReplaced()) return;
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
      _onQueueContentChanged();

      // Save updated queue
      unawaited(_stateStore.savePlaybackSnapshot(
        queue: _queueToPersist(),
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
  
  /// Credit the wall time played since the last credit to the *current*
  /// track's listen-time stats. Called periodically while playing, when
  /// playback pauses/stops, and right before the current track changes (so
  /// the tail of a track isn't credited to the next one). [stillPlaying]:
  /// keep timing from now on; otherwise timing restarts on the next play.
  void _creditListenTime({required bool stillPlaying}) {
    final since = _lastListenTimeRecord;
    final now = DateTime.now();
    _lastListenTimeRecord = stillPlaying ? now : null;
    final track = _currentTrack;
    if (since == null || track == null) return;
    final elapsed = now.difference(since);
    if (elapsed <= Duration.zero) return;
    _playStats.addListenTime(track.id, elapsed);
    _accumulatedTime += elapsed;
    if (_accumulatedTime.inSeconds >= 60) {
      _accumulatedTime = Duration.zero;
      unawaited(_savePlayStats());
    }
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

    // Time actually heard (position ticks while playing), not wall time
    // since the start: paused time and seeked-over parts don't count.
    final listened = _listenedTime.listened;
    final actualDurationMs = listened.inMilliseconds;
    // A play once heard for the play-count threshold (a restored track that
    // was scrobbled before the relaunch counts too); otherwise a skip.
    final duration = track.duration ?? _cachedDuration;
    final countsAsPlay = _hasScrobbled ||
        duration == null ||
        duration <= Duration.zero ||
        listened.inSeconds >= scrobbleThresholdSeconds(duration);

    // Record to analytics with actual duration
    // Jellyfin already counts reported plays (the Stopped report, queued
    // while offline), so only unreported plays are left for the analytics
    // sync to push with markPlayed.
    unawaited(ListeningAnalyticsService().recordPlay(
      track,
      actualDurationMs: actualDurationMs,
      playStartTime: startTime,
      reportedToServer: _reportingService != null && track.serverUrl != null,
      countsAsPlay: countsAsPlay,
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
    _creditListenTime(stillPlaying: true);

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

    if (_playerPositionIsCurrent) {
      final position = await _player.getCurrentPosition();
      if (position != null) _lastPosition = position;
    }


    await _stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: _lastPosition,
      queue: _queueToPersist(),
      currentQueueIndex: _currentIndex,
      isPlaying: isPlaying,
      repeatMode: _repeatMode.name,
      shuffleEnabled: _isShuffleEnabled,
      volume: _volume,
    );
    // Writes are coalesced; the app may be suspended any moment now.
    await _stateStore.flush();
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

  /// Whether the transition into [next] will be a crossfade (so the gapless
  /// pre-load of the same track would be a wasted second download).
  bool _crossfadeWillHandle(JellyfinTrack next) {
    if (!_crossfadeEnabled || _crossfadeDurationSeconds == 0) return false;
    if (_repeatMode == RepeatMode.one) return false;
    // Track-count sleep timer on its last track: let it end, don't fade in
    // the next one.
    if (_isSleepTimerByTracks && _sleepTracksRemaining <= 1) return false;
    final current = _currentTrack;
    if (current == null) return false;
    // SMART: Don't crossfade within same album (respect artist intent)
    final currentAlbumId = current.albumId;
    final nextAlbumId = next.albumId;
    if (currentAlbumId != null &&
        nextAlbumId != null &&
        currentAlbumId == nextAlbumId) {
      return false;
    }
    return true;
  }

  /// Check if we should trigger crossfade based on current position
  Future<void> _checkCrossfadeTrigger(Duration position) async {
    if (!_crossfadeEnabled || _isCrossfading || _crossfadeDurationSeconds == 0) {
      return;
    }
    // Repeat-one replays the same track; crossfading into itself is wrong and
    // the completion handler already restarts it.
    if (_repeatMode == RepeatMode.one) return;
    // An A-B loop keeps playback inside the track (its B marker may lie in
    // the crossfade window).
    if (_loopState.isActive) return;
    if (_isTransitioning) return;
    // Nothing (or not the right thing) is playing yet.
    if (_sourceLoadToken != null || _restoreSourcePending) return;

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

    if (!_crossfadeWillHandle(nextTrack)) return;

    // Offline and the next track isn't on the device: no crossfade; the
    // end-of-track transition skips to the next downloaded one.
    if (_isOffline && !_hasLocalCopy(nextTrack, await _offlineCachedTrackIds())) {
      return;
    }
    if (_isCrossfading || _disposed || _currentTrack == null) return;

    // Trigger crossfade
    debugPrint('🌊 Starting crossfade: ${_currentTrack!.name} → ${nextTrack.name}');
    unawaited(_startCrossfade(nextTrack, resolvedIndex));
  }

  /// Start crossfade to next track
  Future<void> _startCrossfade(JellyfinTrack nextTrack, int nextIndex) async {
    final incoming = _crossfadePlayer;
    if (_isCrossfading || incoming == null) return;
    _isCrossfading = true;
    // Claim the player; a user-initiated playTrack during the fade wins.
    final requestId = ++_playRequestId;
    final fadeGeneration = _fadeGeneration;
    bool aborted() =>
        _disposed || !_isCrossfading || requestId != _playRequestId;

    try {
      // Prepare next track from the same source playback would use
      // (download → cache → stream at the user's quality).
      final resolved = await _resolvePlaybackSource(nextTrack);
      if (aborted()) {
        _settleAfterCrossfadeAbort(requestId, fadeGeneration);
        return;
      }
      if (resolved == null) {
        throw Exception('No source for ${nextTrack.name}');
      }
      _crossfadeLoading = true;
      try {
        final source = await _sourceFor(
          resolved.url,
          isLocalFile: resolved.isLocalFile,
          track: nextTrack,
          isDirectStream: !resolved.isLocalFile && resolved.isDirectStream,
        );
        await incoming.setSource(source).timeout(_sourceLoadTimeout);
      } finally {
        _crossfadeLoading = false;
      }
      if (aborted()) {
        // Cancelled while loading: _cancelCrossfade skipped the stop.
        if (!_disposed) unawaited(incoming.stop());
        _settleAfterCrossfadeAbort(requestId, fadeGeneration);
        return;
      }

      // Execute the crossfade
      await _executeCrossfade(
        incoming,
        nextTrack,
        nextIndex,
        requestId,
        resolved,
        fadeGeneration,
      );
    } catch (e) {
      debugPrint('❌ Crossfade failed: $e');
      final wasOurs = _playRequestId == requestId;
      _cancelCrossfade();
      if (wasOurs && !_disposed) {
        // Restore the outgoing track's volume in case we were mid-fade.
        unawaited(_applyUserVolumeToPlayer());
        // The outgoing player may already have completed while the
        // completion handler was suppressed for the crossfade: advance now.
        if (_player.state == EngineState.completed && !_isTransitioning) {
          unawaited(_gaplessTransition().catchError(
            (Object e) => debugPrint('❌ Track advance after crossfade failure: $e'),
          ));
        }
      }
    }
  }

  /// A crossfade was called off without a new play request taking over
  /// (paused, crossfade turned off). The outgoing track may be partly faded
  /// or may already have finished — its completion event was ignored during
  /// the crossfade — so restore its volume and, if it finished while still
  /// meant to play, advance now.
  void _settleAfterCrossfadeAbort(int requestId, int fadeGeneration) {
    if (_disposed || requestId != _playRequestId || _stopping) return;
    // A pause/resume fade owns the volume now.
    if (fadeGeneration == _fadeGeneration) {
      unawaited(_applyUserVolumeToPlayer());
    }
    if (_player.state == EngineState.completed &&
        _player.wantsToPlay &&
        !_isTransitioning &&
        !_advanceInFlight) {
      unawaited(_gaplessTransition().catchError(
        (Object e) => debugPrint('❌ Track advance after cancelled crossfade: $e'),
      ));
    }
  }

  /// Execute the crossfade (Concurrent overlap)
  Future<void> _executeCrossfade(
    EnginePlayer incoming,
    JellyfinTrack nextTrack,
    int nextIndex,
    int requestId,
    _ResolvedSource source,
    int fadeGeneration,
  ) async {
    bool aborted() =>
        _disposed || !_isCrossfading || requestId != _playRequestId;

    final steps = 25; // More steps for smoother concurrent transition
    final stepDuration = Duration(milliseconds: (_crossfadeDurationSeconds * 1000) ~/ steps);
    // ReplayGain for each side of the fade
    final outgoing = _player;
    final outMultiplier = _gainFor(_currentTrack);
    final inMultiplier = _gainFor(nextTrack);

    // Start the next track at volume 0.0 immediately
    await incoming.setVolume(0.0);
    await incoming.setSpeed(_speed);
    if (aborted()) {
      if (!_disposed) await incoming.stop();
      _settleAfterCrossfadeAbort(requestId, fadeGeneration);
      return;
    }
    await incoming.resume();

    // Concurrent Fade loop
    for (int i = 0; i <= steps; i++) {
      if (aborted()) break;

      final progress = i / steps;
      // Quadratic curves for natural logarithmic volume perception
      final fadeOut = 1.0 - (progress * progress);
      final fadeIn = progress * progress;

      // Update both volumes simultaneously
      unawaited(outgoing.setVolume((_volume * fadeOut * outMultiplier).clamp(0.0, 1.0)));
      unawaited(incoming.setVolume((_volume * fadeIn * inMultiplier).clamp(0.0, 1.0)));

      if (i < steps) {
        await Future.delayed(stepDuration);
      }
    }

    // Cancelled (e.g. user picked another track or paused): the main player
    // belongs to whoever took over — don't stop it or swap players under it.
    if (aborted()) {
      if (!_disposed) await incoming.stop();
      _settleAfterCrossfadeAbort(requestId, fadeGeneration);
      return;
    }

    // Complete the transition (stops the faded-out old player)
    await _completeCrossfadeTransition(incoming, nextTrack, nextIndex, source);
  }

  /// Complete crossfade and switch to next track.
  ///
  /// The swap and state switch happen synchronously (no await in between)
  /// so a playTrack arriving now can't be overwritten by this transition.
  Future<void> _completeCrossfadeTransition(
    EnginePlayer incoming,
    JellyfinTrack nextTrack,
    int nextIndex,
    _ResolvedSource source,
  ) async {
    // Close out the outgoing track (listening time + Jellyfin "stopped")
    // before any state switches to the new one.
    _recordActualListeningTime();
    _reportOutgoingStopped();

    _creditListenTime(stillPlaying: true);

    // SWAP: crossfade player becomes the new main player
    final outgoing = _player;
    _player = incoming;
    _crossfadePlayer = outgoing; // Reuse old player for next crossfade
    _audioHandler?.updatePlayer(_player);
    _attachPlayerListeners(_player); // also detaches the outgoing player

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
    _isCurrentTrackLocal = source.isLocalFile;
    _setCurrentSource(source.url, isLocal: source.isLocalFile);
    _analyzeTrackForVisualizer(nextTrack);

    // Explicitly emit playing state
    _playingController.add(true);
    _lastPlayingState = true;

    _isCrossfading = false;
    _clearPreload();

    // The outgoing track finished (by fading out): count it for a
    // track-count sleep timer. The trigger never crossfades out of the last
    // counted track, so this can't reach zero unless the timer was changed
    // mid-fade.
    if (_isSleepTimerByTracks && _sleepTracksRemaining > 0) {
      _sleepTracksRemaining--;
      _sleepTimerController.add(Duration(seconds: -_sleepTracksRemaining));
      if (_sleepTracksRemaining <= 0) unawaited(_fadeOutAndStop());
    }

    // Per-track bookkeeping (scrobble/history/report/duration/loop/media item)
    _onTrackBegan(nextTrack, playMethod: source.playMethod);
    _afterTrackStarted(nextTrack);

    // Stop the faded-out old player and reset its volume for reuse.
    try {
      await outgoing.stop();
      await outgoing.setVolume(1.0);
    } catch (e) {
      debugPrint('⚠️ Crossfade cleanup failed: $e');
    }

    // Force OS media controls update
    await _audioHandler?.forcePlayingState();

    unawaited(_stateStore.savePlaybackSnapshot(
      currentTrack: _currentTrack,
      position: Duration.zero,
      queue: _queueToPersist(),
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
    // Repeat-one restarts the same track via playTrack; pre-loading it would
    // download it a second time for nothing.
    if (_repeatMode == RepeatMode.one) return;
    // A queued track starts by itself, so a track-count sleep timer ending
    // with this track must see it finish instead.
    if (_isSleepTimerByTracks && _sleepTracksRemaining <= 1) return;
    if (_sourceLoadToken != null || _restoreSourcePending) return;

    // Use cached duration to avoid async getDuration() call on every position update
    final duration = _cachedDuration;
    if (duration == null || duration.inMilliseconds == 0) return;

    // Pre-load when we're 70% through the current track
    final preloadThreshold = duration * 0.7;
    if (position < preloadThreshold) return;

    // Get next track
    var nextTrack = _getNextTrack();
    if (nextTrack == null) return;
    var nextIndex = _currentIndex + 1 < _queue.length ? _currentIndex + 1 : 0;
    var skipsAhead = false;

    if (_isOffline) {
      // Pre-load the next track that is actually on the device (the one
      // _gaplessTransition will skip to); never a stream.
      final current = _currentTrack;
      final missKey = '${current?.id}@$_currentIndex/${_queue.length}';
      if (_offlineMissKey == missKey) return;
      final fromIndex = _currentIndex;
      final target = await _nextOfflinePlayableIndex(fromIndex, 1);
      if (_disposed || _currentIndex != fromIndex || _currentTrack?.id != current?.id) {
        return;
      }
      // Only forward targets: a wrap-around goes through playTrack.
      if (target <= fromIndex || target >= _queue.length) {
        _offlineMissKey = missKey;
        return;
      }
      skipsAhead = target != fromIndex + 1;
      nextTrack = _queue[target];
      nextIndex = target;
    }

    // Don't pre-load if already loaded
    if (_preloadedTrack?.id == nextTrack.id) return;

    // A crossfade will load it into the crossfade player instead (never
    // across skipped offline tracks, see _checkCrossfadeTrigger).
    if (!skipsAhead && _crossfadeWillHandle(nextTrack)) return;

    // Pre-load the next track
    await _preloadNextTrack(nextTrack, nextIndex);
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

  /// Once the current track has been listened to for the scrobble threshold
  /// (50% or 4 minutes, whichever is less), count the play and scrobble it.
  void _checkPlayThreshold() {
    final track = _currentTrack;
    if (track == null || (_hasScrobbled && !_playCountPending)) return;

    // Use cached duration to avoid async getDuration() call on every tick
    final duration = track.duration ?? _cachedDuration;
    if (duration == null || duration.inMilliseconds == 0) return;
    final thresholdSeconds = scrobbleThresholdSeconds(duration);
    if (_listenedTime.listened.inSeconds < thresholdSeconds) return;

    if (_playCountPending) {
      _playCountPending = false;
      _playStats.incrementPlayCount(track.id);
      unawaited(_savePlayStats());
    }

    // Scrobbled in battery saver / offline too: the services queue it and
    // send when they can (sending is throttled there).
    if (_hasScrobbled) return;
    final listenBrainz = ListenBrainzService();
    final lastFm = LastFmService.instance;
    final startTime = _trackStartTime;
    if (startTime == null ||
        (!listenBrainz.isScrobblingEnabled && !lastFm.isScrobblingEnabled)) {
      return;
    }
    _hasScrobbled = true;
    debugPrint('🎵 Scrobbling "${track.name}" '
        '(${_listenedTime.listened.inSeconds}s heard >= ${thresholdSeconds}s)');
    if (listenBrainz.isScrobblingEnabled) {
      unawaited(listenBrainz.submitListen(track, startTime).catchError((Object e) {
        debugPrint('🎵 ListenBrainz scrobble failed: $e');
        return false;
      }));
    }
    if (lastFm.isScrobblingEnabled) {
      unawaited(lastFm.scrobble(track, startTime));
    }
  }

  /// Queue the next track on the main player (just_audio playlist window)
  /// so it starts with no gap; [_onGaplessAdvance] runs when it does.
  Future<void> _preloadNextTrack(JellyfinTrack track, int index) async {
    if (_isPreloading) return;
    _isPreloading = true;
    _preloadingTrackId = track.id;
    final generation = _preloadGeneration;
    final queueVersion = _queueVersion;
    final player = _player;
    // _clearPreload (queue edit, new track, stop, repeat/sleep change) or a
    // crossfade swapping the main player invalidates this pre-load.
    bool stale() =>
        _disposed || generation != _preloadGeneration || !identical(player, _player);

    try {
      debugPrint('⏩ Queueing next track: ${track.name}');

      // Same priority as playback: downloaded file → cache → stream.
      final resolved = await _resolvePlaybackSource(track);
      if (stale()) return;
      if (resolved == null) {
        debugPrint('⚠️ Failed to pre-load (no source): ${track.name}');
        return;
      }
      final source = await _sourceFor(
        resolved.url,
        isLocalFile: resolved.isLocalFile,
        track: track,
        isDirectStream: !resolved.isLocalFile && resolved.isDirectStream,
      );
      if (stale()) return;
      // Record it before queueing: the advance can fire as soon as the
      // track is on the player. A queue edit while it was resolving (that
      // kept it as the next track) may have moved its slot.
      if (_queueVersion != queueVersion) {
        final slot = resolveQueueIndex<JellyfinTrack>(
          _queue,
          track.id,
          (t) => t.id,
          requestedIndex: index,
          nearIndex: index,
        );
        if (slot == -1) return;
        index = slot;
      }
      _preloadedTrack = track;
      _preloadedSource = resolved;
      _preloadedIndex = index;
      await player.appendNext(source).timeout(_sourceLoadTimeout);
      if (stale()) {
        // Invalidated while queueing: take it off the player again.
        if (!_disposed && identical(player, _player) && _preloadedTrack == null) {
          unawaited(player.removeNext());
        }
        return;
      }
      debugPrint('✅ Queued (${resolved.isLocalFile ? 'local' : resolved.playMethod}): ${track.name}');
    } catch (e) {
      debugPrint('⚠️ Error pre-loading track: $e');
      if (!stale()) {
        _preloadedTrack = null;
        _preloadedSource = null;
        _preloadedIndex = null;
        unawaited(player.removeNext());
      }
    } finally {
      _isPreloading = false;
      _preloadingTrackId = null;
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
    _preloadGeneration++;
    _preloadedTrack = null;
    _preloadedSource = null;
    _preloadedIndex = null;
    // Take the queued track off the player (a pre-load still in progress
    // notices the generation change and removes it itself).
    if (!_isPreloading) {
      unawaited(_player.removeNext().catchError(
        (Object e) => debugPrint('⚠️ Removing queued track failed: $e'),
      ));
    }
  }

  /// The queue was edited: drop the pre-load only if the next track changed.
  void _onQueueEdited() {
    final nextId = _getNextTrack()?.id;
    final preparedId = _preloadedTrack?.id ?? _preloadingTrackId;
    if (preparedId != null && preparedId == nextId) {
      // Still the next track, but edits before it (a removed, inserted or
      // moved track) may have moved its slot: _onGaplessAdvance must find
      // it there, or it reloads the track that just started.
      if (_preloadedTrack != null) {
        _preloadedIndex = _currentIndex + 1 < _queue.length ? _currentIndex + 1 : 0;
      }
      return;
    }
    _clearPreload();
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

  // ========== STALL RECOVERY ==========

  /// The player says "playing" but makes no progress (position frozen, or
  /// buffering for a long time with the network up), or it reported an
  /// error ([fromError]): typically a stream whose connection died
  /// mid-track. Reload the source at the current position — which also
  /// switches to a local copy if one finished caching meanwhile. If the
  /// reload fails during a network outage, the track resumes by itself once
  /// the connection is back ([_armResumeAfterOutage]); otherwise it shows
  /// paused with an error and play retries. [resume]: whether playback is
  /// wanted afterwards (default: whether the player is playing).
  Future<void> _recoverFromStall({bool? resume, bool fromError = false}) async {
    final track = _currentTrack;
    if (track == null ||
        _disposed ||
        _stallRecoveryInFlight ||
        _isTransitioning ||
        _advanceInFlight ||
        _isCrossfading ||
        _sourceLoadToken != null ||
        _restoreSourcePending) {
      return;
    }
    final player = _player;
    final wanted = resume ?? player.state == EngineState.playing;
    if (_stallRecoveries >= _maxStallRecoveriesPerTrack) {
      if (fromError) {
        // Out of retries: settle as paused (play reloads it) — or, if the
        // network is gone, wait for it to come back.
        await _settleAfterFailedReload(
          track,
          wanted: wanted,
          networkOutage: !_isCurrentTrackLocal && (_isOffline || !_networkAvailable),
          outOfRetries: true,
        );
      }
      return;
    }
    // Still playing past the reported end (an estimated duration that is
    // too short): the completion event ends the track, don't cut it off.
    final playerDuration = player.duration;
    if (!fromError &&
        player.wantsToPlay &&
        !player.isBuffering &&
        playerDuration != null &&
        playerDuration > Duration.zero &&
        player.position >= playerDuration) {
      _stallDetector.reset();
      return;
    }
    // Frozen within the last couple of seconds: the end-of-track
    // notification was lost (seen with VBR files whose estimated duration
    // overshoots). Advance instead of reloading.
    final duration = _cachedDuration;
    if (resume != false &&
        duration != null &&
        duration > const Duration(seconds: 5) &&
        _lastPosition >= duration - const Duration(seconds: 2)) {
      debugPrint('⚠️ Playback stuck at the end of "${track.name}" - advancing');
      _stallDetector.reset();
      try {
        await _gaplessTransition();
      } catch (e) {
        debugPrint('❌ Advance after stuck end failed: $e');
      }
      return;
    }
    _stallRecoveryInFlight = true;
    final requestId = _playRequestId;
    bool superseded() =>
        _disposed || requestId != _playRequestId || _currentTrack?.id != track.id;
    final resumeAt = _lastPosition;
    var reloadIsLocal = false;
    try {
      if (!fromError && player.isBuffering) {
        // Waiting for data: only worth a reload when there is a network to
        // reload from. In an outage, let AVPlayer keep buffering — it
        // continues by itself when the connection is back.
        final connectivity = _connectivityService;
        final connected = _networkAvailable &&
            !_isOffline &&
            (connectivity == null || await connectivity.hasNetworkTransport());
        if (superseded()) return;
        if (!connected) {
          debugPrint('📶 Buffering during a network outage - waiting, not reloading');
          _stallDetector.reset();
          return;
        }
      }
      _stallRecoveries++;
      debugPrint('⚠️ Playback ${fromError ? 'failed' : 'stalled'} at ${resumeAt.inSeconds}s '
          'on "${track.name}" - reloading '
          '(attempt $_stallRecoveries/$_maxStallRecoveriesPerTrack)');
      final resolved = await _resolvePlaybackSource(track);
      if (superseded()) return;
      if (resolved == null) throw StateError('no source');
      reloadIsLocal = resolved.isLocalFile;
      await _withPlayerLock(requestId, () async {
        if (superseded()) return;
        final player = _player;
        await _loadMainSource(
          player,
          await _sourceFor(
            resolved.url,
            isLocalFile: resolved.isLocalFile,
            track: track,
            isDirectStream: !resolved.isLocalFile && resolved.isDirectStream,
          ),
        );
        if (superseded()) return;
        _setCurrentSource(resolved.url, isLocal: resolved.isLocalFile);
        _isCurrentTrackLocal = resolved.isLocalFile;
        final seekTo = _pendingSeek ?? resumeAt;
        _pendingSeek = null;
        if (seekTo > Duration.zero) await player.seek(seekTo);
        if (superseded()) return;
        // Paused while we were reloading: stay paused.
        if (_pauseRequestedDuringLoad || !wanted) {
          _pauseRequestedDuringLoad = false;
          return;
        }
        await player.setVolume(
          (_volume * _gainFor(track)).clamp(0.0, 1.0),
        );
        await player.resume();
      });
      _stallDetector.reset();
    } catch (e) {
      if (superseded()) return;
      debugPrint('❌ Stall recovery failed: $e');
      // The failed load reported position 0: keep where the track was (or
      // a seek made meanwhile), so the retry continues from there.
      final keepAt = _pendingSeek ?? resumeAt;
      _pendingSeek = null;
      _lastPosition = keepAt;
      _positionController.add(keepAt);
      // A stream (or no source at all, e.g. offline) that failed to load:
      // most likely the network. A local file failing is not.
      await _settleAfterFailedReload(
        track,
        wanted: wanted && !_pauseRequestedDuringLoad,
        networkOutage: !reloadIsLocal,
      );
    } finally {
      _stallRecoveryInFlight = false;
    }
  }

  /// Nothing playable is loaded after a failed reload: show paused and
  /// reload on the next play (the track already began, so no begin
  /// bookkeeping is pending). With [networkOutage] and playback [wanted],
  /// it also resumes by itself once the connection is back.
  Future<void> _settleAfterFailedReload(
    JellyfinTrack track, {
    required bool wanted,
    required bool networkOutage,
    bool outOfRetries = false,
  }) async {
    _currentSourceUrl = null;
    _restoreSourcePending = true;
    _pauseRequestedDuringLoad = false;
    _lastPlayingState = false;
    _playingController.add(false);
    if (wanted && networkOutage) {
      _playbackErrorController.add('Connection lost. Playback resumes when the connection is back.');
      _armResumeAfterOutage(track);
    } else {
      _playbackErrorController.add(outOfRetries
          ? 'Playback failed. Press play to retry.'
          : 'Connection lost. Press play to retry.');
    }
    try {
      await _player.pause();
      await _audioHandler?.forceBroadcastCurrentState();
    } catch (_) {}
  }

  // ---- Resume after a network outage ----

  /// [track]'s reload failed during an outage while it was playing: retry
  /// (backing off, see [outageRetryDelay]) and right away when connectivity
  /// or online mode returns, for up to [_maxOutageWait]. Any user
  /// play/pause, a track change, headphones unplugged or a call cancels it.
  void _armResumeAfterOutage(JellyfinTrack track) {
    if (_resumeAfterOutageTrackId != track.id) {
      _outageSince = DateTime.now();
      _outageRetryAttempt = 0;
    }
    _resumeAfterOutageTrackId = track.id;
    _scheduleOutageRetry();
  }

  void _cancelResumeAfterOutage() {
    _resumeAfterOutageTrackId = null;
    _outageSince = null;
    _outageRetryAttempt = 0;
    _outageRetryTimer?.cancel();
    _outageRetryTimer = null;
  }

  void _scheduleOutageRetry([Duration? delay]) {
    if (_resumeAfterOutageTrackId == null || _disposed) return;
    _outageRetryTimer?.cancel();
    _outageRetryTimer = Timer(delay ?? outageRetryDelay(_outageRetryAttempt++), () {
      _outageRetryTimer = null;
      unawaited(_retryAfterOutage());
    });
  }

  /// The connection (or online mode) is back.
  void _retryAfterOutageSoon() {
    if (_resumeAfterOutageTrackId == null) return;
    // Give the new route a moment to settle.
    _scheduleOutageRetry(const Duration(seconds: 1));
  }

  bool _outageRetryRunning = false;

  Future<void> _retryAfterOutage() async {
    final id = _resumeAfterOutageTrackId;
    if (id == null || _disposed || _outageRetryRunning) return;
    if (_currentTrack?.id != id || !_restoreSourcePending || isPlaying) {
      // Something else loaded or played the track meanwhile.
      _cancelResumeAfterOutage();
      return;
    }
    final since = _outageSince;
    if (since != null && DateTime.now().difference(since) > _maxOutageWait) {
      debugPrint('📶 Gave up waiting for the connection; play retries');
      _cancelResumeAfterOutage();
      return;
    }
    if (_isOffline || !_networkAvailable || _playInFlight != null || _stallRecoveryInFlight) {
      _scheduleOutageRetry();
      return;
    }
    debugPrint('📶 Retrying playback after the outage');
    _outageRetryRunning = true;
    var resumed = false;
    try {
      resumed = await _resumeInternal(afterOutage: true);
    } catch (e) {
      debugPrint('⚠️ Resume after outage failed: $e');
    } finally {
      _outageRetryRunning = false;
    }
    if (_resumeAfterOutageTrackId != id) return; // cancelled meanwhile
    if (resumed) {
      _cancelResumeAfterOutage();
    } else {
      _scheduleOutageRetry();
    }
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
      if (_player.state != EngineState.playing) return;

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
        final gain = _gainFor(_currentTrack);
        _player.setVolume((fadedVolume * gain).clamp(0.0, 1.0));
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
    // Playback must stop at a track end, which a queued next track skips.
    if (trackCount <= 1) _clearPreload();
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

    // Fade out from wherever the (sleep-faded) volume is now and pause. The
    // fade starts from the player's current volume, so there's no jump back
    // up to full volume; the pause then restores the user's volume for the
    // next play.
    await _pauseInternal(fromUser: false);
    _sleepFadeApplied = false;

    debugPrint('😴 Sleep timer: Playback stopped, volume restored to $_volume');
  }

  void dispose() {
    // Set flag FIRST: player listener callbacks check this to short-circuit
    // before touching controllers that are about to close below. Without it,
    // the unawaited _detachListeners() race would let a queued onPositionChanged
    // call _positionController.add() after close() and throw "Bad state".
    _disposed = true;
    _positionSaveTimer?.cancel();
    _preCacheTimer?.cancel();
    _sleepTimer?.cancel();
    _stallTimer?.cancel();
    _outageRetryTimer?.cancel();
    _interruptionSubscription?.cancel();
    _becomingNoisySubscription?.cancel();
    _waveformExtractionSub?.cancel();
    _connectivitySubscription?.cancel();
    unawaited(_detachListeners());
    _audioHandler?.dispose();
    unawaited(_player.dispose());
    unawaited(_crossfadePlayer?.dispose());
    _currentTrackController.close();
    _playingController.close();
    _positionController.close();
    _bufferedSub?.cancel();
    _bufferedController.close();
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
    unawaited(_positionDataRelay.close());
    unawaited(_trackPlayingRelay.close());
    unawaited(_stateStore.flush());
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

/// Result of loading a source into the main player.
enum _LoadOutcome {
  /// A newer request took over; do nothing more.
  superseded,
  /// Loaded and playing.
  started,
  /// Loaded, but the user paused while it was loading.
  loadedPaused,
}

/// Network type for auto quality selection
enum _NetworkType {
  wifi,     // WiFi or Ethernet - use original quality
  cellular, // Mobile data - use normal quality (192kbps)
  slow,     // Unknown/slow - use low quality (128kbps)
}
