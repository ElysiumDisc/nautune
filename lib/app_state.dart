import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive_flutter/hive_flutter.dart';

import 'demo/demo_content.dart';
import 'jellyfin/jellyfin_album.dart';
import 'jellyfin/jellyfin_artist.dart';
import 'jellyfin/jellyfin_genre.dart';
import 'jellyfin/jellyfin_exceptions.dart';
import 'jellyfin/jellyfin_library.dart';
import 'jellyfin/jellyfin_credentials.dart';
import 'jellyfin/jellyfin_playlist.dart';
import 'jellyfin/jellyfin_playlist_store.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'jellyfin/jellyfin_track.dart';
import 'jellyfin/robust_http_client.dart';
import 'providers/demo_mode_provider.dart';
import 'services/audio_player_service.dart';
import 'services/bootstrap_service.dart';
import 'services/listening_analytics_service.dart';
import 'services/lastfm_service.dart';
import 'services/listenbrainz_service.dart';
import 'services/profile_stats_cache.dart';
import 'services/carplay_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/hive_init.dart';
import 'services/local_cache_service.dart';
import 'services/pending_report_store.dart';
import 'services/remote_control_service.dart';
import 'services/playback_reporting_service.dart';
import 'services/playback_state_store.dart';
import 'services/playlist_membership_store.dart';
import 'services/playlist_sync_queue.dart';
import 'services/app_icon_service.dart';
import 'services/power_mode_service.dart';

// Import SessionProvider - this is new
import 'providers/session_provider.dart';

// Import repository layer for offline UI parity
import 'models/playback_state.dart';
import 'models/replay_gain_mode.dart';
import 'models/transcode_codec.dart';
import 'repositories/music_repository.dart';
import 'repositories/repository_factory.dart';

import 'providers/library_data_provider.dart';
import 'providers/sync_status_provider.dart';

class NautuneAppState extends ChangeNotifier {
  NautuneAppState({
    required JellyfinService jellyfinService,
    required JellyfinSessionStore sessionStore,
    required PlaybackStateStore playbackStateStore,
    required LocalCacheService cacheService,
    required BootstrapService bootstrapService,
    required ConnectivityService connectivityService,
    required DownloadService downloadService,
    JellyfinPlaylistStore? playlistStore,
    PlaylistSyncQueue? syncQueue,
    DemoModeProvider? demoModeProvider,
    SessionProvider? sessionProvider,
    LibraryDataProvider? libraryDataProvider, // New parameter
    SyncStatusProvider? syncStatusProvider,
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore,
        _playbackStateStore = playbackStateStore,
        _cacheService = cacheService,
        _bootstrapService = bootstrapService,
        _connectivityService = connectivityService,
        _playlistStore = playlistStore ?? JellyfinPlaylistStore(),
        _syncQueue = syncQueue ?? PlaylistSyncQueue(),
        _demoModeProvider = demoModeProvider,
        _sessionProvider = sessionProvider,
        _libraryDataProvider = libraryDataProvider, // Initialize
        _syncStatusProvider = syncStatusProvider,
        _downloadService = downloadService {
    _audioPlayerService = AudioPlayerService();

    // Listen to LibraryDataProvider changes if available
    if (_libraryDataProvider != null) {
      _libraryDataProvider.addListener(notifyListeners);
      _libraryDataProvider.offlineCheck = () => isOfflineMode;
    }
    
    // Link download service to audio player for offline playback
    _audioPlayerService.setDownloadService(_downloadService);
    _audioPlayerService.setJellyfinService(_jellyfinService);
    _audioPlayerService.setLocalCacheService(_cacheService);
    // Share lyrics service with download service for offline lyrics pre-caching
    if (_audioPlayerService.lyricsService != null) {
      _downloadService.setLyricsService(_audioPlayerService.lyricsService!);
    }
    // CarPlay service is only available on iOS; initialize early for CarPlay to work
    // even when app is launched from CarPlay (phone app not open)
    if (Platform.isIOS) {
      scheduleMicrotask(() async {
        try {
          _carPlayService = CarPlayService(appState: this);
          // Initialize CarPlay immediately so it shows up in CarPlay
          await _carPlayService?.initialize();
          debugPrint('✅ CarPlay service initialized early');
        } catch (error) {
          debugPrint('CarPlay service initialization failed: $error');
        }
      });
    }

    // Listen to demo mode provider changes
    _demoModeProvider?.addListener(_onDemoModeChanged);

    // Listen to session provider changes (Bridge for Phase 2)
    _sessionProvider?.addListener(_onSessionChanged);
    _onSessionChanged(); // Sync initial state
  }

  final JellyfinService _jellyfinService;
  final JellyfinSessionStore _sessionStore;
  final PlaybackStateStore _playbackStateStore;
  final LocalCacheService _cacheService;
  final BootstrapService _bootstrapService;
  final ConnectivityService _connectivityService;
  final JellyfinPlaylistStore _playlistStore;
  final PlaylistSyncQueue _syncQueue;
  final DemoModeProvider? _demoModeProvider;
  final SessionProvider? _sessionProvider;
  final LibraryDataProvider? _libraryDataProvider; // New field
  final SyncStatusProvider? _syncStatusProvider;
  late final AudioPlayerService _audioPlayerService;
  late final DownloadService _downloadService;
  CarPlayService? _carPlayService;
  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _periodicSyncTimer; // Syncs analytics every 10 minutes
  /// Runs while a bootstrap sync reported a genuine network failure; probes
  /// the server every 30 s and restores online state when it answers.
  Timer? _reachabilityTimer;
  bool _reachabilityProbeInFlight = false;
  static const Duration _reachabilityProbeInterval = Duration(seconds: 30);
  bool _connectivityMonitorInitialized = false;
  Map<String, double> _libraryScrollOffsets = {};
  int _restoredLibraryTabIndex = 0;
  List<int> _navTabOrder = const [0, 1, 2, 3, 4];
  bool _showVolumeBar = true;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  bool _infiniteRadioEnabled = false;
  bool _gaplessPlaybackEnabled = true;
  int _cacheTtlMinutes = 2; // User-configurable cache TTL
  StreamingQuality _streamingQuality = StreamingQuality.original; // Default to lossless
  bool _visualizerEnabled = true; // Effective: shown right now
  bool _visualizerEnabledByUser = true; // User's preference (the Settings switch)
  VisualizerType _visualizerType = VisualizerType.bioluminescent; // Current visualizer style
  VisualizerPosition _visualizerPosition = VisualizerPosition.controlsBar; // Where visualizer is displayed
  NowPlayingLayout _nowPlayingLayout = NowPlayingLayout.classic; // Now Playing screen layout
  StreamSubscription? _powerModeSub;
  /// Battery saver ("submarine mode"; offline or iOS Low Power Mode). While
  /// active, crossfade, gapless, pre-caching and the visualizer are paused.
  /// Only the applied values change: the user's preferences
  /// ([_crossfadeEnabled], [_gaplessPlaybackEnabled], [_preCacheTrackCount],
  /// [_visualizerEnabledByUser]) stay as chosen, and are what is persisted.
  bool _submarineModeEnabled = false;
  int _preCacheTrackCount = 3; // User's preference (0 = off)
  SortOption _albumSortBy = SortOption.name;
  SortOrder _albumSortOrder = SortOrder.ascending;
  SortOption _artistSortBy = SortOption.name;
  SortOrder _artistSortOrder = SortOrder.ascending;
  bool _isDemoMode = false;
  DemoContent? _demoContent;
  Map<String, JellyfinTrack> _demoTracks = {};
  Map<String, List<String>> _demoAlbumTrackMap = {};
  Map<String, List<String>> _demoPlaylistTrackMap = {};
  List<String> _demoRecentTrackIds = [];
  Set<String> _demoFavoriteTrackIds = <String>{};
  int _demoPlaylistCounter = 0;

  bool _initialized = false;
  JellyfinSession? _session;
  Object? _lastError;
  bool _isLoadingLibraries = false;
  Object? _librariesError;
  List<JellyfinLibrary>? _libraries;
  bool _isLoadingAlbums = false;
  Object? _albumsError;
  List<JellyfinAlbum>? _albums;
  bool _isLoadingMoreAlbums = false;
  bool _hasMoreAlbums = true;
  int _albumsPage = 0;
  int _albumsLoadId = 0;
  static const int _albumsPageSize = 50;
  
  bool _isLoadingArtists = false;
  Object? _artistsError;
  List<JellyfinArtist>? _artists;
  bool _isLoadingMoreArtists = false;
  bool _hasMoreArtists = true;
  int _artistsPage = 0;
  static const int _artistsPageSize = 50;
  bool _isLoadingPlaylists = false;
  Object? _playlistsError;
  List<JellyfinPlaylist>? _playlists;
  bool _isLoadingRecent = false;
  Object? _recentError;
  List<JellyfinTrack>? _recentTracks;
  bool _isLoadingRecentlyAdded = false;
  Object? _recentlyAddedError;
  List<JellyfinAlbum>? _recentlyAddedAlbums;
  bool _isLoadingFavorites = false;
  Object? _favoritesError;
  List<JellyfinTrack>? _favoriteTracks;
  bool _isLoadingGenres = false;
  Object? _genresError;
  List<JellyfinGenre>? _genres;
  bool _isLoadingRecentlyPlayed = false;
  List<JellyfinTrack>? _recentlyPlayedTracks;
  bool _isLoadingMostPlayedTracks = false;
  List<JellyfinTrack>? _mostPlayedTracks;
  bool _isLoadingMostPlayedAlbums = false;
  List<JellyfinAlbum>? _mostPlayedAlbums;
  bool _isLoadingLongestTracks = false;
  List<JellyfinTrack>? _longestTracks;
  bool _isLoadingDiscover = false;
  List<JellyfinTrack>? _discoverTracks;
  bool _isLoadingOnThisDay = false;
  List<JellyfinTrack>? _onThisDayTracks;
  bool _isLoadingRecommendations = false;
  List<JellyfinTrack>? _recommendationTracks;
  String? _recommendationSeedTrackName; // Name of track used for recommendations
  bool _userWantsOffline = false;  // User's explicit offline preference (persisted)
  bool _networkAvailable = true;  // Track network connectivity
  bool _handlingUnauthorizedSession = false;

  /// Bumped when the account or library changes (and on logout): home shelf
  /// loads started under an older value drop their results.
  int _shelvesGeneration = 0;

  bool get isInitialized => _initialized;
  bool get networkAvailable => _networkAvailable;
  bool get isDemoMode => _demoModeProvider?.isDemoMode ?? _isDemoMode;

  void _onDemoModeChanged() {
    // When demo mode changes, update our internal state and notify listeners
    final provider = _demoModeProvider;
    if (provider != null) {
      _isDemoMode = provider.isDemoMode;

      // If demo mode just started, sync data
      if (_isDemoMode) {
        _libraries = provider.library != null ? [provider.library!] : null;
        if (provider.library != null) {
          _session = JellyfinSession(
            serverUrl: 'demo://nautune',
            username: 'tester',
            credentials: const JellyfinCredentials(
              accessToken: 'demo-token',
              userId: 'demo-user',
            ),
            deviceId: 'demo-device',
            selectedLibraryId: provider.library!.id,
            selectedLibraryName: provider.library!.name,
            isDemo: true,
          );
          
          // Initialize reporting service for demo mode to prevent warnings
          _installReportingService(_session!);
        }
        _albums = provider.albums;
        _artists = provider.artists;
        _genres = provider.genres;
        _playlists = provider.playlists;
        _recentTracks = provider.recentTracks;
        _favoriteTracks = provider.favoriteTracks;
        // The demo library is complete: nothing to page in.
        _hasMoreAlbums = false;
        _hasMoreArtists = false;
      } else {
        if (_session != null && _session!.isDemo) {
          _session = null;
        }
      }

      notifyListeners();
    }
  }

  // Sync session from SessionProvider
  void _onSessionChanged() {
    if (_sessionProvider == null) return;
    final newSession = _sessionProvider.session;
    // Scope listening analytics to this account (no-op when unchanged), so
    // another account's plays are neither shown nor synced to this server.
    // Done before the init guard: initialize() already builds home shelves
    // ("On This Day") from the analytics.
    ListeningAnalyticsService().setCurrentAccount(
      serverUrl: newSession?.serverUrl,
      userId: newSession?.credentials.userId,
    );
    // Until initialize() has loaded the persisted preferences (offline mode,
    // remote control, battery saver) a session must not start any network
    // work: initialize() restores the stored session itself and calls this
    // again at the end to pick up anything that changed meanwhile.
    if (!_initialized) return;

    debugPrint('[NautuneAppState] _onSessionChanged called. Provider session: ${newSession?.selectedLibraryId}');

    if (_session != newSession) {
      debugPrint('[NautuneAppState] Updating local session. New Lib ID: ${newSession?.selectedLibraryId}');
      final previous = _session;
      _session = newSession;

      // If the new session is a demo session, prefer demo provider data and avoid
      // triggering network loads which may overwrite demo collections before the
      // DemoModeProvider listener fires.
      if (_session != null && (_session?.isDemo ?? false)) {
        final provider = _demoModeProvider;
        if (provider != null && provider.isDemoMode) {
          _isDemoMode = true;
          _demoContent = null; // demoContent is managed by provider
          _libraries = provider.library != null ? [provider.library!] : null;
          if (provider.library != null) {
            _session = JellyfinSession(
              serverUrl: 'demo://nautune',
              username: 'tester',
                          credentials: const JellyfinCredentials(
                            accessToken: 'demo-token',
                            userId: 'demo-user',
                          ),
                          deviceId: 'demo-device',
                          selectedLibraryId: provider.library!.id,
                          selectedLibraryName: provider.library!.name,
                          isDemo: true,
                        );
            _installReportingService(_session!);
          }

          _albums = provider.albums;
          _artists = provider.artists;
          _genres = provider.genres;
          _playlists = provider.playlists;
          _recentTracks = provider.recentTracks;
          _favoriteTracks = provider.favoriteTracks;
          _hasMoreAlbums = false;
          _hasMoreArtists = false;

          notifyListeners();
          return;
        }
      }

      // Normal (non-demo) session handling
      if (_session != null && !(_session?.isDemo ?? false)) {
        final session = _session!;
        final signedIn = previous == null || previous.isDemo;
        if (previous == null ||
            previous.isDemo ||
            previous.selectedLibraryId != session.selectedLibraryId ||
            _accountKey(previous) != _accountKey(session)) {
          _clearHomeShelves();
        }
        if (previous != null &&
            !previous.isDemo &&
            _accountKey(previous) != _accountKey(session)) {
          // Another account: a saved queue still waiting to be restored is
          // the previous account's (setJellyfinService would restore it).
          _audioPlayerService.clearPendingRestore();
        }
        // Ensure AudioPlayerService has the correct JellyfinService instance
        _audioPlayerService.setJellyfinService(_jellyfinService);
        // setJellyfinService starts a new image prewarmer (enabled): keep
        // it off while offline.
        _audioPlayerService.setImagePrewarmEnabled(!isOfflineMode);
        // Downloads: hydrate stored tracks with the new server/token and
        // resume the queue now rather than on the service's 2 s poll.
        _downloadService.onSessionChanged();

        // Install (or keep) the playback reporter for this session. Reuses
        // the existing one when nothing relevant changed (e.g. library
        // switch) so its progress timer and offline queue aren't leaked/lost.
        _installReportingService(session);

        // Start periodic analytics sync for the new session
        _startPeriodicSyncTimer();

        // LibraryDataProvider (when present) loads the libraries and the
        // library collections itself on this same session change; loading
        // them here too only duplicated every request. Offline, the legacy
        // loader still provides the downloads-based fallback.
        if (_libraryDataProvider == null || isOfflineMode) {
          unawaited(_loadLibraries());
        }
        if (session.selectedLibraryId != null) {
          unawaited(_loadLibraryDependentContent(forceRefresh: true));
        }
        if (signedIn) {
          // Signed in, or the stored session became readable after a
          // locked-keychain start: what initialize() does for a restored
          // session (bootstrap sync, which also detects an expired token;
          // analytics and offline-edit sync; the offline policy).
          _startSessionNetworkWork(session);
          unawaited(_reconcileScrobblerLinks(session));
        }
      } else if (_session == null) {
        // Session cleared - stop periodic sync
        _stopPeriodicSyncTimer();
        _clearLibraryCaches();
        _clearHomeShelves();
      }
    }
  }

  /// Account part of [session] ("server|user"), for per-account checks.
  String _accountKey(JellyfinSession session) =>
      _cacheService.cacheKeyForSession(session);

  /// Clears the home shelves the app state loads itself (they belong to one
  /// account and library). Loads still running belong to the previous
  /// account or library: bumping [_shelvesGeneration] drops their results
  /// (and they no longer clear the loading flags, reset here).
  void _clearHomeShelves() {
    _shelvesGeneration++;
    _recentlyAddedAlbums = null;
    _recentlyAddedError = null;
    _recentlyPlayedTracks = null;
    _mostPlayedTracks = null;
    _mostPlayedAlbums = null;
    _longestTracks = null;
    _discoverTracks = null;
    _onThisDayTracks = null;
    _recommendationTracks = null;
    _recommendationSeedTrackName = null;
    _isLoadingRecent = false;
    _isLoadingRecentlyAdded = false;
    _isLoadingRecentlyPlayed = false;
    _isLoadingMostPlayedTracks = false;
    _isLoadingMostPlayedAlbums = false;
    _isLoadingLongestTracks = false;
    _isLoadingDiscover = false;
    _isLoadingOnThisDay = false;
    _isLoadingRecommendations = false;
  }

  // --- End of _onSessionChanged ---

  /// Installs the playback reporter for [session] on the audio service.
  ///
  /// - Keeps the current reporter when it already matches (same server,
  ///   token, device, user) — no leak, no lost state.
  /// - Otherwise disposes the old reporter (cancelling its progress timer),
  ///   carrying its queued offline events and active session over when it
  ///   reported for the same server + user.
  /// - Never enables reporting while offline.
  // ---------------------------------------------------------------------------
  // Remote control (other Jellyfin clients driving this session)
  // ---------------------------------------------------------------------------

  RemoteControlService? _remoteControl;
  bool _remoteControlEnabled = true;
  bool get remoteControlEnabled => _remoteControlEnabled;

  void setRemoteControlEnabled(bool enabled) {
    if (_remoteControlEnabled == enabled) return;
    _remoteControlEnabled = enabled;
    unawaited(_playbackStateStore.saveUiState(remoteControlEnabled: enabled));
    if (enabled) {
      final session = _session;
      if (session != null) _startRemoteControl(session);
    } else {
      _stopRemoteControl();
    }
    notifyListeners();
  }

  void _startRemoteControl(JellyfinSession session) {
    if (!_remoteControlEnabled || session.isDemo || isOfflineMode) return;
    final existing = _remoteControl;
    if (existing != null &&
        existing.serverUrl == session.serverUrl &&
        existing.accessToken == session.credentials.accessToken) {
      unawaited(existing.start());
      return;
    }
    existing?.stop();
    _remoteControl = RemoteControlService(
      serverUrl: session.serverUrl,
      accessToken: session.credentials.accessToken,
      deviceId: session.deviceId,
      httpClient: _jellyfinService.jellyfinClient?.httpClient,
      onCommand: (command) => unawaited(_handleRemoteCommand(command)),
    );
    unawaited(_remoteControl!.start());
  }

  void _stopRemoteControl() {
    _remoteControl?.stop();
  }

  double _volumeBeforeMute = 1.0;

  Future<void> _handleRemoteCommand(RemoteCommand command) async {
    final player = _audioPlayerService;
    debugPrint('🎛️ Remote command: $command');
    try {
      switch (command) {
        case RemotePlaystate(:final command, :final seekPosition):
          switch (command) {
            case 'PlayPause':
              await player.playPause();
            case 'Pause':
              await player.pause();
            case 'Unpause':
              await player.resume();
            case 'Stop':
              await player.stop();
            case 'NextTrack':
              await player.next();
            case 'PreviousTrack':
              await player.previous();
            case 'Seek':
              if (seekPosition != null) await player.seek(seekPosition);
            case 'FastForward':
              await player.seek(player.currentPosition + const Duration(seconds: 15));
            case 'Rewind':
              final back = player.currentPosition - const Duration(seconds: 15);
              await player.seek(back.isNegative ? Duration.zero : back);
          }
        case RemotePlay(:final itemIds, :final playCommand, :final startIndex):
          if (playCommand == 'PlayInstantMix') {
            final mix = await _jellyfinService.getInstantMix(itemId: itemIds.first, limit: 50);
            if (mix.isNotEmpty) await player.playTrack(mix.first, queueContext: mix);
            return;
          }
          final tracks = await _jellyfinService.loadTracksByIds(itemIds);
          if (tracks.isEmpty) return;
          switch (playCommand) {
            case 'PlayNext':
              player.playNext(tracks);
            case 'PlayLast':
              player.addToQueue(tracks);
            case 'PlayShuffle':
              await player.playShuffled(tracks);
            default:
              final start = startIndex.clamp(0, tracks.length - 1);
              await player.playTrack(tracks[start], queueContext: tracks);
          }
        case RemoteGeneral(:final name, :final arguments):
          switch (name) {
            case 'SetVolume':
              final v = int.tryParse(arguments['Volume'] ?? '');
              if (v != null) await player.setVolume(v / 100);
            case 'VolumeUp':
              await player.setVolume(player.volume + 0.1);
            case 'VolumeDown':
              await player.setVolume(player.volume - 0.1);
            case 'Mute':
              _volumeBeforeMute = player.volume > 0 ? player.volume : _volumeBeforeMute;
              await player.setVolume(0);
            case 'Unmute':
              await player.setVolume(_volumeBeforeMute);
            case 'ToggleMute':
              if (player.volume > 0) {
                _volumeBeforeMute = player.volume;
                await player.setVolume(0);
              } else {
                await player.setVolume(_volumeBeforeMute);
              }
            case 'SetRepeatMode':
              player.setRepeatMode(switch (arguments['RepeatMode']) {
                'RepeatOne' => RepeatMode.one,
                'RepeatAll' => RepeatMode.all,
                _ => RepeatMode.off,
              });
            case 'SetShuffleQueue':
              final shuffle = arguments['ShuffleMode'] == 'Shuffle';
              if (shuffle != player.shuffleEnabled) player.toggleShuffle();
          }
        case RemoteKeepAlive():
          break;
      }
    } catch (e) {
      debugPrint('🎛️ Remote command failed: $e');
    }
  }

  void _installReportingService(JellyfinSession session) {
    final old = _audioPlayerService.reportingService;
    final deviceId = session.isDemo ? null : session.deviceId;
    PlaybackReportingService service;
    if (old != null &&
        old.matches(
          serverUrl: session.serverUrl,
          accessToken: session.credentials.accessToken,
          deviceId: deviceId,
          userId: session.credentials.userId,
        )) {
      service = old;
    } else {
      service = PlaybackReportingService(
        serverUrl: session.serverUrl,
        accessToken: session.credentials.accessToken,
        deviceId: deviceId,
        userId: session.credentials.userId,
        // Reuse the API client's keep-alive connections.
        httpClient: _jellyfinService.jellyfinClient?.httpClient,
        pendingStore: HivePendingReportStore(),
      );
      if (old != null) {
        if (service.isSameAccountAs(old)) {
          service.adoptStateFrom(old);
        }
        // A retired (logged-out) reporter disposes itself after its final
        // stop report; disposing it here could drop that report.
        if (!old.isRetired) old.dispose();
      }
    }
    service.setEnabled(!isOfflineMode);
    if (_submarineModeEnabled) {
      service.setProgressInterval(const Duration(seconds: 60));
    }
    if (!isOfflineMode) {
      unawaited(service.flushPendingReports());
    }
    _startRemoteControl(session);
    if (!identical(service, old)) {
      _audioPlayerService.setReportingService(service);
    }
  }

  /// Stop reporting for the current account (logout): drop queued offline
  /// events so they can't be sent later under another account, cancel the
  /// progress timer and refuse new sessions. The pending stop report for the
  /// track that logout just stopped is still delivered (the audio service
  /// sends it asynchronously), then the reporter disposes itself.
  void _retireReportingService() {
    _audioPlayerService.reportingService?.retire();
  }

  JellyfinSession? get session => _session;
  Object? get lastError => _lastError;

  /// The library data source for the getters below. In demo mode the demo
  /// collections (legacy fields, filled from DemoModeProvider) are served
  /// instead, so a provider error or stale real-account data can't hide them.
  LibraryDataProvider? get _libData => isDemoMode ? null : _libraryDataProvider;

  bool get isLoadingLibraries => _libData?.isLoadingLibraries ?? _isLoadingLibraries;
  Object? get librariesError => _libData?.librariesError ?? _librariesError;
  List<JellyfinLibrary>? get libraries => _libData?.libraries ?? _libraries;
  bool get isLoadingAlbums => _libData?.isLoadingAlbums ?? _isLoadingAlbums;
  Object? get albumsError => _libData?.albumsError ?? _albumsError;
  List<JellyfinAlbum>? get albums => _libData?.albums ?? _albums;
  bool get isLoadingMoreAlbums => _libData?.isLoadingMoreAlbums ?? _isLoadingMoreAlbums;
  bool get hasMoreAlbums => _libData?.hasMoreAlbums ?? _hasMoreAlbums;
  bool get isLoadingArtists => _libData?.isLoadingArtists ?? _isLoadingArtists;
  Object? get artistsError => _libData?.artistsError ?? _artistsError;
  List<JellyfinArtist>? get artists => _libData?.artists ?? _artists;
  bool get isLoadingMoreArtists => _libData?.isLoadingMoreArtists ?? _isLoadingMoreArtists;
  bool get hasMoreArtists => _libData?.hasMoreArtists ?? _hasMoreArtists;
  bool get isLoadingPlaylists => _libData?.isLoadingPlaylists ?? _isLoadingPlaylists;
  Object? get playlistsError => _libData?.playlistsError ?? _playlistsError;
  List<JellyfinPlaylist>? get playlists => _libData?.playlists ?? _playlists;
  bool get isLoadingRecent => _libData?.isLoadingRecent ?? _isLoadingRecent;
  Object? get recentError => _libData?.recentError ?? _recentError;
  List<JellyfinTrack>? get recentTracks => _libData?.recentTracks ?? _recentTracks;
  bool get isLoadingRecentlyAdded => _libData?.isLoadingRecentlyAdded ?? _isLoadingRecentlyAdded;
  Object? get recentlyAddedError => _libData?.recentlyAddedError ?? _recentlyAddedError;
  List<JellyfinAlbum>? get recentlyAddedAlbums => _libData?.recentlyAddedAlbums ?? _recentlyAddedAlbums;
  bool get isLoadingFavorites => _libData?.isLoadingFavorites ?? _isLoadingFavorites;
  Object? get favoritesError => _libData?.favoritesError ?? _favoritesError;
  List<JellyfinTrack>? get favoriteTracks => _libData?.favoriteTracks ?? _favoriteTracks;
  bool get isLoadingGenres => _libData?.isLoadingGenres ?? _isLoadingGenres;
  Object? get genresError => _libData?.genresError ?? _genresError;
  List<JellyfinGenre>? get genres => _libData?.genres ?? _genres;
  bool get isLoadingRecentlyPlayed => _isLoadingRecentlyPlayed;
  List<JellyfinTrack>? get recentlyPlayedTracks => _recentlyPlayedTracks;
  bool get isLoadingMostPlayedTracks => _isLoadingMostPlayedTracks;
  List<JellyfinTrack>? get mostPlayedTracks => _mostPlayedTracks;
  bool get isLoadingMostPlayedAlbums => _isLoadingMostPlayedAlbums;
  List<JellyfinAlbum>? get mostPlayedAlbums => _mostPlayedAlbums;
  bool get isLoadingLongestTracks => _isLoadingLongestTracks;
  List<JellyfinTrack>? get longestTracks => _longestTracks;
  bool get isLoadingDiscover => _isLoadingDiscover;
  List<JellyfinTrack>? get discoverTracks => _discoverTracks;
  bool get isLoadingOnThisDay => _isLoadingOnThisDay;
  List<JellyfinTrack>? get onThisDayTracks => _onThisDayTracks;
  bool get isLoadingRecommendations => _isLoadingRecommendations;
  List<JellyfinTrack>? get recommendationTracks => _recommendationTracks;
  String? get recommendationSeedTrackName => _recommendationSeedTrackName;
  /// Offline mode is active if user explicitly chose it OR network is unavailable.
  ///
  /// Auto-recovery semantics: when connectivity is restored, isOfflineMode flips
  /// back to false automatically (because `_networkAvailable` flips true) **unless**
  /// the user explicitly opted into offline mode via the settings toggle — in
  /// that case `_userWantsOffline` keeps it true until they toggle it off.
  ///
  /// The `repository` getter below is re-evaluated on every call, so consumers
  /// that fetch `appState.repository.<method>()` fresh (the pattern used by
  /// every screen and service today) automatically switch between online and
  /// offline implementations on the next Provider rebuild after
  /// notifyListeners() fires from _handleConnectivityStatusChange.
  bool get isOfflineMode => _userWantsOffline || !_networkAvailable;

  /// Whether user explicitly wants offline mode (persisted setting)
  bool get userWantsOffline => _userWantsOffline;

  /// Get the appropriate repository based on offline mode.
  /// Returns OfflineRepository when offline, OnlineRepository when online.
  MusicRepository get repository => RepositoryFactory.create(
        isOfflineMode: isOfflineMode,
        jellyfinService: _jellyfinService,
        downloadService: _downloadService,
        playlistStore: _playlistStore,
      );

  bool get showVolumeBar => _showVolumeBar;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeDurationSeconds => _crossfadeDurationSeconds;
  bool get infiniteRadioEnabled => _infiniteRadioEnabled;
  bool get gaplessPlaybackEnabled => _gaplessPlaybackEnabled;
  int get cacheTtlMinutes => _cacheTtlMinutes;
  StreamingQuality get streamingQuality => _streamingQuality;
  ReplayGainMode get replayGainMode => _audioPlayerService.replayGainMode;
  TranscodeCodec get transcodeCodec => _audioPlayerService.transcodeCodec;
  double get replayGainPreampDb => _audioPlayerService.replayGainPreampDb;
  /// Whether the visualizer is shown right now (the user's preference, unless
  /// Low Power Mode or the battery saver paused it). Rendering code reads this.
  bool get visualizerEnabled => _visualizerEnabled;

  /// The user's visualizer preference (the Settings switch value).
  bool get visualizerEnabledByUser => _visualizerEnabledByUser;

  /// True while the user wants the visualizer but Low Power Mode or the
  /// battery saver has paused it.
  bool get isVisualizerPausedByPowerSaving =>
      _visualizerEnabledByUser && !_visualizerEnabled;

  /// Whether the battery saver is active (offline or Low Power Mode):
  /// crossfade, gapless, pre-caching and the visualizer are paused, while
  /// [crossfadeEnabled], [gaplessPlaybackEnabled], [preCacheTrackCount] and
  /// [visualizerEnabledByUser] keep reporting the user's choices.
  bool get batterySaverActive => _submarineModeEnabled;

  /// The user's pre-cache preference (0 = off); paused while
  /// [batterySaverActive].
  int get preCacheTrackCount => _preCacheTrackCount;
  VisualizerType get visualizerType => _visualizerType;
  VisualizerPosition get visualizerPosition => _visualizerPosition;
  NowPlayingLayout get nowPlayingLayout => _nowPlayingLayout;
  bool get submarineModeEnabled => _userWantsOffline || !_networkAvailable;
  Duration get cacheTtl => Duration(minutes: _cacheTtlMinutes);
  SortOption get albumSortBy => _albumSortBy;
  SortOrder get albumSortOrder => _albumSortOrder;
  SortOption get artistSortBy => _artistSortBy;
  SortOrder get artistSortOrder => _artistSortOrder;
  int get initialLibraryTabIndex => _restoredLibraryTabIndex;
  List<int> get navTabOrder => _navTabOrder;
  double? scrollOffsetFor(String key) => _libraryScrollOffsets[key];
  String? get selectedLibraryId => _session?.selectedLibraryId;
  JellyfinLibrary? get selectedLibrary {
    final libs = libraries;
    final id = _session?.selectedLibraryId;
    if (libs == null || id == null) {
      return null;
    }
    for (final library in libs) {
      if (library.id == id) {
        return library;
      }
    }
    return null;
  }

  String? get _sessionCacheKey {
    final session = _session;
    if (session == null) {
      return null;
    }
    return _cacheService.cacheKeyForSession(session);
  }

  JellyfinService get jellyfinService => _jellyfinService;
  AudioPlayerService get audioPlayerService => _audioPlayerService;
  DownloadService get downloadService => _downloadService;
  List<JellyfinAlbum> get demoAlbums =>
      _demoContent?.albums ?? const <JellyfinAlbum>[];
  List<JellyfinArtist> get demoArtists =>
      _demoContent?.artists ?? const <JellyfinArtist>[];
  List<JellyfinTrack> get demoTracks {
    if (_demoModeProvider != null) {
      return _demoModeProvider.allTracks;
    }
    return _demoTracks.values.toList(growable: false);
  }

  List<JellyfinTrack> _demoTracksFromIds(List<String> ids) {
    if (!_isDemoMode) {
      return const [];
    }
    return ids
        .map((id) => _demoTracks[id])
        .whereType<JellyfinTrack>()
        .toList();
  }

  void _applyDemoCollections() {
    final content = _demoContent;
    if (!_isDemoMode || content == null) {
      return;
    }
    _libraries = [content.library];
    _albums = content.albums;
    _artists = content.artists;
    _genres = content.genres;
    _playlists = List<JellyfinPlaylist>.from(_playlists ?? content.playlists);
    _recentTracks = _demoTracksFromIds(_demoRecentTrackIds);
    _favoriteTracks =
        _demoTracksFromIds(_demoFavoriteTrackIds.toList());
    _hasMoreAlbums = false;
    _hasMoreArtists = false;
    _albumsError = null;
    _artistsError = null;
    _playlistsError = null;
    _recentError = null;
    _favoritesError = null;
    _genresError = null;
  }

  void _clearLibraryCaches() {
    _libraries = null;
    _albums = null;
    _artists = null;
    _playlists = null;
    _recentTracks = null;
    _favoriteTracks = null;
    _genres = null;
    _librariesError = null;
    _albumsError = null;
    _artistsError = null;
    _playlistsError = null;
    _recentError = null;
    _favoritesError = null;
    _genresError = null;
    _isLoadingAlbums = false;
    _isLoadingArtists = false;
    _isLoadingPlaylists = false;
    _isLoadingRecent = false;
    _isLoadingFavorites = false;
    _isLoadingGenres = false;
  }

  Future<void> _teardownDemoMode() async {
    if (_demoModeProvider != null) {
      await _demoModeProvider.stopDemoMode();
      // The provider listener will handle state updates
      return;
    }

    if (!_isDemoMode) {
      return;
    }
    try {
      await _audioPlayerService.stop();
    } catch (_) {
      // Ignore stop errors during teardown
    }
    await _downloadService.deleteDemoDownloads();
    await _playbackStateStore.clearPlaybackData();
    _downloadService.disableDemoMode();
    _isDemoMode = false;
    _demoContent = null;
    _demoTracks = {};
    _demoAlbumTrackMap = {};
    _demoPlaylistTrackMap = {};
    _demoFavoriteTrackIds.clear();
    _demoRecentTrackIds = [];
    _demoPlaylistCounter = 0;
    _clearLibraryCaches();
    notifyListeners();
  }

  Future<void> _setupDemoMode(
    DemoContent content,
    Uint8List offlineAudioBytes,
  ) async {
    // Legacy setup method - only used if DemoModeProvider is not available
    await _downloadService.deleteDemoDownloads();
    _downloadService.enableDemoMode(demoAudioBytes: offlineAudioBytes);

    _isDemoMode = true;
    _demoContent = content;
    _demoTracks = Map<String, JellyfinTrack>.from(content.tracks);
    _demoAlbumTrackMap = content.albumTrackIds.map(
      (key, value) => MapEntry(key, List<String>.from(value)),
    );
    _demoPlaylistTrackMap = content.playlistTrackIds.map(
      (key, value) => MapEntry(key, List<String>.from(value)),
    );
    _demoRecentTrackIds = List<String>.from(content.recentTrackIds);
    _demoFavoriteTrackIds = content.favoriteTrackIds.toSet();
    _demoPlaylistCounter = content.playlists.length;
    _networkAvailable = true;
    _userWantsOffline = false;
    _publishOfflineState();

    _session = JellyfinSession(
      serverUrl: 'demo://nautune',
      username: 'tester',
      credentials: const JellyfinCredentials(
        accessToken: 'demo-token',
        userId: 'demo-user',
      ),
      deviceId: 'demo-device',
      selectedLibraryId: content.library.id,
      selectedLibraryName: content.library.name,
      isDemo: true,
    );

    _playlists = List<JellyfinPlaylist>.from(content.playlists);
    _applyDemoCollections();

    final offlineTrack = _demoTracks[content.offlineTrackId];
    if (offlineTrack != null) {
      await _downloadService.seedDemoDownload(
        track: offlineTrack,
        bytes: offlineAudioBytes,
        extension: 'mp3',
      );
    }
  }

  void _replaceDemoPlaylist(JellyfinPlaylist playlist) {
    final current = _playlists ?? <JellyfinPlaylist>[];
    final index = current.indexWhere((p) => p.id == playlist.id);
    final updated = List<JellyfinPlaylist>.from(current);
    if (index >= 0) {
      updated[index] = playlist;
    } else {
      updated.add(playlist);
    }
    _playlists = updated;
  }

  void _removeDemoPlaylist(String playlistId) {
    final current = _playlists;
    if (current == null) return;
    _playlists =
        current.where((playlist) => playlist.id != playlistId).toList();
  }

  JellyfinPlaylist? _findPlaylist(String id) {
    final list = _playlists;
    if (list == null) return null;
    try {
      return list.firstWhere((playlist) => playlist.id == id);
    } catch (_) {
      return null;
    }
  }

  void toggleVolumeBar() {
    _showVolumeBar = !_showVolumeBar;
    unawaited(_playbackStateStore.saveUiState(showVolumeBar: _showVolumeBar));
    notifyListeners();
  }

  void setVolumeBarVisibility(bool visible) {
    if (_showVolumeBar == visible) return;
    _showVolumeBar = visible;
    unawaited(_playbackStateStore.saveUiState(showVolumeBar: _showVolumeBar));
    notifyListeners();
  }

  void toggleCrossfade(bool enabled) {
    _crossfadeEnabled = enabled;
    // The battery saver keeps it paused; the preference applies once it ends.
    _audioPlayerService.setCrossfadeEnabled(enabled && !_submarineModeEnabled);
    unawaited(_playbackStateStore.saveUiState(
      crossfadeEnabled: enabled,
      crossfadeDurationSeconds: _crossfadeDurationSeconds,
    ));
    notifyListeners();
  }

  void setCrossfadeDuration(int seconds) {
    _crossfadeDurationSeconds = seconds.clamp(0, 10);
    _audioPlayerService.setCrossfadeDuration(_crossfadeDurationSeconds);
    unawaited(_playbackStateStore.saveUiState(
      crossfadeEnabled: _crossfadeEnabled,
      crossfadeDurationSeconds: _crossfadeDurationSeconds,
    ));
    notifyListeners();
  }

  void toggleInfiniteRadio(bool enabled) {
    _infiniteRadioEnabled = enabled;
    _audioPlayerService.setInfiniteRadioEnabled(enabled);
    unawaited(_playbackStateStore.saveUiState(
      infiniteRadioEnabled: enabled,
    ));
    notifyListeners();
  }

  void toggleGaplessPlayback(bool enabled) {
    _gaplessPlaybackEnabled = enabled;
    _audioPlayerService
        .setGaplessPlaybackEnabled(enabled && !_submarineModeEnabled);
    unawaited(_playbackStateStore.saveUiState(
      gaplessPlaybackEnabled: enabled,
    ));
    notifyListeners();
  }

  double get playbackSpeed => _audioPlayerService.playbackSpeed;

  void setPlaybackSpeed(double speed) {
    unawaited(_audioPlayerService.setPlaybackSpeed(speed));
    unawaited(_playbackStateStore.saveUiState(playbackSpeed: _audioPlayerService.playbackSpeed));
    notifyListeners();
  }

  bool get smartShuffleEnabled => _audioPlayerService.smartShuffleEnabled;

  void setSmartShuffleEnabled(bool enabled) {
    _audioPlayerService.setSmartShuffleEnabled(enabled);
    unawaited(_playbackStateStore.saveUiState(smartShuffleEnabled: enabled));
    notifyListeners();
  }

  /// Set the codec used when the server has to transcode, and persist it.
  void setTranscodeCodec(TranscodeCodec codec) {
    if (_audioPlayerService.transcodeCodec == codec) return;
    _audioPlayerService.setTranscodeCodec(codec);
    unawaited(_playbackStateStore.saveUiState(transcodeCodec: codec));
    notifyListeners();
  }

  /// Set ReplayGain mode and/or preamp (dB, -15..0) and persist them.
  void setReplayGain({ReplayGainMode? mode, double? preampDb}) {
    unawaited(_audioPlayerService.setReplayGain(mode: mode, preampDb: preampDb));
    unawaited(_playbackStateStore.saveUiState(
      replayGainMode: _audioPlayerService.replayGainMode,
      replayGainPreampDb: _audioPlayerService.replayGainPreampDb,
    ));
    notifyListeners();
  }

  /// Set cache TTL in minutes (1-10080)
  void setCacheTtl(int minutes) {
    _cacheTtlMinutes = minutes.clamp(1, 10080);
    _jellyfinService.setCacheTtl(Duration(minutes: _cacheTtlMinutes));
    unawaited(_playbackStateStore.saveUiState(
      cacheTtlMinutes: _cacheTtlMinutes,
    ));
    notifyListeners();
  }

  /// Set streaming quality preference
  void setStreamingQuality(StreamingQuality quality) {
    if (_streamingQuality == quality) return;
    _streamingQuality = quality;
    _audioPlayerService.setStreamingQuality(quality);
    unawaited(_playbackStateStore.saveUiState(
      streamingQuality: quality,
    ));
    debugPrint('🎵 Streaming quality set to: ${quality.label}');
    notifyListeners();
  }

  /// Set visualizer enabled/disabled (for battery savings)
  void setVisualizerEnabled(bool enabled) {
    if (_visualizerEnabledByUser == enabled) return;
    // The user's preference; Low Power Mode / the battery saver may keep the
    // visualizer paused until they end.
    _visualizerEnabledByUser = enabled;
    _updateEffectiveVisualizer();
    notifyListeners();

    unawaited(_playbackStateStore.saveUiState(
      visualizerEnabled: enabled,
    ));
  }

  /// Visualizer shown = user's preference, unless Low Power Mode or the
  /// battery saver pauses it.
  void _updateEffectiveVisualizer() {
    _visualizerEnabled = _visualizerEnabledByUser &&
        !_submarineModeEnabled &&
        !PowerModeService.instance.isLowPowerMode;
  }

  /// Set visualizer type/style
  void setVisualizerType(VisualizerType type) {
    if (_visualizerType == type) return;
    _visualizerType = type;
    notifyListeners();

    unawaited(_playbackStateStore.saveUiState(
      visualizerType: type,
    ));
    debugPrint('🎨 Visualizer type set to: ${type.label}');
  }

  /// Set visualizer position (album art or controls bar)
  void setVisualizerPosition(VisualizerPosition position) {
    if (_visualizerPosition == position) return;
    _visualizerPosition = position;
    notifyListeners();

    unawaited(_playbackStateStore.saveUiState(
      visualizerPosition: position,
    ));
    debugPrint('🎨 Visualizer position set to: ${position.label}');
  }

  /// Set Now Playing screen layout
  void setNowPlayingLayout(NowPlayingLayout layout) {
    if (_nowPlayingLayout == layout) return;
    _nowPlayingLayout = layout;
    notifyListeners();

    unawaited(_playbackStateStore.saveUiState(
      nowPlayingLayout: layout,
    ));
    debugPrint('🎨 Now Playing layout set to: ${layout.label}');
  }

  /// Set pre-cache track count for smart caching
  void setPreCacheTrackCount(int count) {
    _preCacheTrackCount = count;
    // Paused (0) while the battery saver is active; applied once it ends.
    _audioPlayerService
        .setPreCacheTrackCount(_submarineModeEnabled ? 0 : count);
    unawaited(_playbackStateStore.saveUiState(
      preCacheTrackCount: count,
    ));
    debugPrint('📦 Pre-cache track count set to: $count');
  }

  /// Set WiFi-only caching
  void setWifiOnlyCaching(bool value) {
    _audioPlayerService.setWifiOnlyCaching(value);
    unawaited(_playbackStateStore.saveUiState(
      wifiOnlyCaching: value,
    ));
    debugPrint('📦 WiFi-only caching: $value');
  }

  /// Activate battery-saving features (called automatically when going offline).
  void _activateSubmarineFeatures() {
    if (_submarineModeEnabled) return; // Already active
    _submarineModeEnabled = true;
    _applyBatterySaverState();
    debugPrint('🚢 Battery saver: ENGAGED — running silent, running deep');
    // Only the flag is persisted: the preferences stay as the user chose,
    // and the overrides are re-applied at launch while the flag is set.
    unawaited(_playbackStateStore.saveUiState(submarineModeEnabled: true));
  }

  /// Deactivate battery-saving features (called when coming back online).
  void _deactivateSubmarineFeatures() {
    if (!_submarineModeEnabled) return; // Already inactive
    _submarineModeEnabled = false;
    _applyBatterySaverState();
    debugPrint('🚢 Battery saver: SURFACED — all systems restored');
    unawaited(_playbackStateStore.saveUiState(submarineModeEnabled: false));
  }

  /// Leave the battery saver only when nothing needs it any more: the app
  /// is online (and the user didn't choose offline) and iOS Low Power Mode
  /// is off.
  void _maybeDeactivateSubmarineFeatures() {
    if (isOfflineMode || PowerModeService.instance.isLowPowerMode) return;
    _deactivateSubmarineFeatures();
  }

  /// Push the battery-saver state to the services: while active, crossfade,
  /// gapless, pre-caching and the visualizer are paused and background work
  /// slows down; otherwise the user's preferences apply.
  void _applyBatterySaverState() {
    final saver = _submarineModeEnabled;
    _audioPlayerService.setCrossfadeEnabled(_crossfadeEnabled && !saver);
    _audioPlayerService.setGaplessPlaybackEnabled(_gaplessPlaybackEnabled && !saver);
    _audioPlayerService.setPreCacheTrackCount(saver ? 0 : _preCacheTrackCount);
    _audioPlayerService.setBatterySaverMode(saver);
    _audioPlayerService.reportingService?.setProgressInterval(
      Duration(seconds: saver ? 60 : 10),
    );
    // The analytics timer's interval follows the saver (30 / 10 min).
    if (_periodicSyncTimer != null) _startPeriodicSyncTimer();
    _updateEffectiveVisualizer();
  }

  /// Initialize Low Power Mode listener (iOS only)
  void _initPowerModeListener() {
    // Initial state: Low Power Mode pauses the visualizer.
    _updateEffectiveVisualizer();

    // Low Power Mode already on at launch: its initial event went out before
    // this listener existed, so apply the battery saver now.
    if (PowerModeService.instance.isLowPowerMode) {
      _activateSubmarineFeatures();
    }

    // Listen for CHANGES
    _powerModeSub = PowerModeService.instance.lowPowerModeStream.listen((isLowPower) {
      if (isLowPower) {
        // Entering Low Power Mode — activate battery saving features only,
        // keep network alive so user can still stream
        _activateSubmarineFeatures();
        debugPrint('🔋 Battery saver auto-enabled by iOS Low Power Mode');
      } else {
        // Exiting Low Power Mode - only deactivate submarine features if not offline
        _maybeDeactivateSubmarineFeatures();
      }
      _updateEffectiveVisualizer();
      notifyListeners();
    });
  }

  /// Set album sort options and reload
  Future<void> setAlbumSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_albumSortBy == sortBy && _albumSortOrder == sortOrder) return;
    _albumSortBy = sortBy;
    _albumSortOrder = sortOrder;
    unawaited(_saveLibrarySort());
    notifyListeners();
    if (_libraryDataProvider != null) {
      // Provider owns the displayed `albums` list (see getter at `albums`).
      // Route through it so the user-visible list actually re-fetches with
      // the new sort instead of writing to a shadow `_albums` field.
      await _libraryDataProvider.setAlbumSort(sortBy, sortOrder);
    } else {
      await _loadAlbumsForSelectedLibrary(forceRefresh: true);
    }
  }

  /// Set artist sort options and reload
  Future<void> setArtistSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_artistSortBy == sortBy && _artistSortOrder == sortOrder) return;
    _artistSortBy = sortBy;
    _artistSortOrder = sortOrder;
    unawaited(_saveLibrarySort());
    notifyListeners();
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.setArtistSort(sortBy, sortOrder);
    } else {
      await _loadArtistsForSelectedLibrary(forceRefresh: true);
    }
  }

  void updateLibraryTabIndex(int index) {
    if (_restoredLibraryTabIndex == index) return;
    _restoredLibraryTabIndex = index;
    unawaited(_playbackStateStore.saveUiState(libraryTabIndex: index));
  }

  void updateNavTabOrder(List<int> order) {
    _navTabOrder = List<int>.from(order);
    unawaited(_playbackStateStore.saveUiState(navTabOrder: order));
    notifyListeners();
  }

  void updateScrollOffset(String key, double offset) {
    _libraryScrollOffsets[key] = offset;
    unawaited(
      _playbackStateStore.saveUiState(scrollOffsets: {key: offset}),
    );
  }

  Future<void> _ensureConnectivityMonitoring() async {
    if (_connectivityMonitorInitialized) {
      return;
    }
    try {
      final isOnline = await _connectivityService.hasNetworkConnection();
      _networkAvailable = isOnline;
      // Note: isOfflineMode getter now returns true when !_networkAvailable
      // so we don't need to set _userWantsOffline here
    } catch (error) {
      debugPrint('Connectivity probe failed: $error');
      _networkAvailable = false;
    }

    _connectivitySubscription =
        _connectivityService.onStatusChange.listen(_handleConnectivityStatusChange);
    _connectivityMonitorInitialized = true;
  }

  /// Pending "network is back" handling (see [_handleConnectivityStatusChange]).
  Timer? _reconnectDebounce;
  static const Duration _reconnectDebounceDelay = Duration(seconds: 2);

  /// When the last full refresh after a reconnect ran.
  DateTime? _lastReconnectRefresh;
  static const Duration _reconnectRefreshMinInterval = Duration(seconds: 30);

  void _handleConnectivityStatusChange(bool isOnline) {
    // OS connectivity is authoritative once it reports a change; the
    // bootstrap-triggered reachability probe is no longer needed.
    _stopReachabilityProbe();

    // When network is lost, isOfflineMode getter automatically returns true
    // We don't change _userWantsOffline - that's the user's explicit choice
    if (!isOnline) {
      _reconnectDebounce?.cancel();
      _reconnectDebounce = null;
      if (!_networkAvailable) return;
      _networkAvailable = false;
      debugPrint('📴 Network lost - app is now effectively offline');
      _publishOfflineState();
      _activateSubmarineFeatures();
      notifyListeners();
      return;
    }

    // Going online: wait until the connection has been up for a moment. A
    // flapping connection (Wi-Fi handoff, CarPlay dead zones) would
    // otherwise restart every service and reload the whole library on each
    // flip. Going offline above stays immediate.
    if (_networkAvailable) return;
    _reconnectDebounce?.cancel();
    _reconnectDebounce = Timer(_reconnectDebounceDelay, () {
      _reconnectDebounce = null;
      _handleNetworkRestored();
    });
  }

  void _handleNetworkRestored() {
    if (_networkAvailable) return;
    _networkAvailable = true;
    debugPrint('📶 Network restored');

    // Restore services only if the user doesn't want offline.
    if (!_userWantsOffline) {
      debugPrint('📶 User is online — restoring network services');
      // Before publishing, so the restarted timers use the normal
      // intervals. Stays engaged while iOS Low Power Mode is on.
      _maybeDeactivateSubmarineFeatures();
      _publishOfflineState();
      // Refresh data in background - don't await, don't block UI
      unawaited(_refreshAfterReconnect());
    } else {
      debugPrint('📴 User prefers offline — keeping services silenced');
    }
    notifyListeners();
  }

  Future<void> _refreshAfterReconnect() async {
    // Small delay to let connection stabilize
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if still online before refreshing
    if (!_networkAvailable) return;

    // A connection that dropped and came back within moments doesn't need
    // the whole library reloaded again.
    final last = _lastReconnectRefresh;
    final now = DateTime.now();
    if (last != null && now.difference(last) < _reconnectRefreshMinInterval) {
      unawaited(_syncPendingPlaylistActions());
      return;
    }
    _lastReconnectRefresh = now;

    try {
      await refreshLibraries();
      debugPrint('✅ Background refresh after reconnect complete');
      // Note: We don't auto-change _userWantsOffline here
      // If user explicitly chose offline mode, they stay offline until they toggle it
      // If they were offline due to no network, isOfflineMode getter now returns false
      notifyListeners();
      // Analytics are synced by _restoreOnlineNetworkPolicy, which always
      // runs before this; a second concurrent sync would send plays twice.
    } catch (error) {
      debugPrint('⚠️ Refresh after reconnect failed: $error');
    }
    // Playlist edits / favorites made while offline (single-flight, so the
    // bootstrap sync started by the online policy doesn't run them twice).
    unawaited(_syncPendingPlaylistActions());
  }

  /// Start periodic analytics sync timer (10 min normal, 30 min in submarine mode)
  /// This ensures local plays are regularly pushed to server
  void _startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    final interval = _submarineModeEnabled
        ? const Duration(minutes: 30)
        : const Duration(minutes: 10);
    _periodicSyncTimer = Timer.periodic(interval, (_) {
      if (_session != null && _networkAvailable && !_isDemoMode && !_userWantsOffline) {
        debugPrint('📊 Periodic sync triggered (every ${_submarineModeEnabled ? 30 : 10} min)');
        unawaited(_syncAnalyticsToServer());
      }
    });
    debugPrint('📊 Started periodic analytics sync timer (${interval.inMinutes} min interval)');
  }

  /// Stop the periodic sync timer
  void _stopPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    debugPrint('📊 Stopped periodic analytics sync timer');
  }

  Future<void>? _analyticsSyncInFlight;

  /// Sync local listening analytics to the Jellyfin server
  /// This pushes unsynced plays that were recorded offline.
  ///
  /// Single-flight: overlapping triggers (reconnect, periodic timer, startup)
  /// share one run. Two concurrent runs would both send the plays the first
  /// one hasn't marked as synced yet, and Jellyfin counts every mark.
  Future<void> _syncAnalyticsToServer() {
    final running = _analyticsSyncInFlight;
    if (running != null) return running;
    late final Future<void> run;
    run = _runAnalyticsSync().whenComplete(() {
      if (identical(_analyticsSyncInFlight, run)) _analyticsSyncInFlight = null;
    });
    _analyticsSyncInFlight = run;
    return run;
  }

  Future<void> _runAnalyticsSync() async {
    final session = _session;
    final client = _jellyfinService.jellyfinClient;

    if (session == null || client == null || _isDemoMode) {
      return;
    }

    try {
      final analyticsService = ListeningAnalyticsService();
      if (!analyticsService.isInitialized) {
        await analyticsService.initialize();
      }

      final unsyncedCount = analyticsService.unsyncedCount;
      if (unsyncedCount == 0) {
        debugPrint('📊 Analytics: No unsynced plays to push');
        return;
      }

      debugPrint('📊 Analytics: Syncing $unsyncedCount plays to server...');

      final result = await analyticsService.syncToServer(
        client: client,
        credentials: session.credentials,
      );

      if (result.success) {
        debugPrint('📊 Analytics: Sync complete - ${result.syncedCount} plays synced');
      } else {
        debugPrint('⚠️ Analytics sync failed: ${result.error ?? result.errors?.join(', ')}');
      }
    } catch (e) {
      debugPrint('⚠️ Analytics sync error: $e');
    }
  }

  /// Apply the preferences that gate network traffic (the user's offline
  /// choice, remote control) before the session is restored, so work that
  /// starts on the session change (LibraryDataProvider's loads) already
  /// honours them. main calls this before SessionProvider.initialize().
  void primeStoredPreferences(PlaybackState? state) {
    if (state == null) return;
    _userWantsOffline = state.isOfflineMode;
    _remoteControlEnabled = state.remoteControlEnabled;
  }

  /// Also before SessionProvider.initialize() (main): whether the device
  /// has a network at all, so LibraryDataProvider's first loads read the
  /// cache instead of trying the network, and the saved library sort, so
  /// they load in that order. Never throws.
  Future<void> prepareSessionRestore() async {
    try {
      _networkAvailable = await _connectivityService.hasNetworkConnection();
    } catch (error) {
      debugPrint('Connectivity probe failed: $error');
    }
    await _restoreLibrarySort();
  }

  static const _librarySortBox = 'nautune_library_sort';

  Future<void> _restoreLibrarySort() async {
    try {
      final box = await _openBox(_librarySortBox);
      final options = SortOption.values.asNameMap();
      final orders = SortOrder.values.asNameMap();
      _albumSortBy = options[box.get('albumSortBy')] ?? _albumSortBy;
      _albumSortOrder = orders[box.get('albumSortOrder')] ?? _albumSortOrder;
      _artistSortBy = options[box.get('artistSortBy')] ?? _artistSortBy;
      _artistSortOrder = orders[box.get('artistSortOrder')] ?? _artistSortOrder;
      _libraryDataProvider?.seedSortState(
        albumSortBy: _albumSortBy,
        albumSortOrder: _albumSortOrder,
        artistSortBy: _artistSortBy,
        artistSortOrder: _artistSortOrder,
      );
    } catch (error) {
      debugPrint('Failed to restore the library sort: $error');
    }
  }

  Future<void> _saveLibrarySort() async {
    try {
      final box = await _openBox(_librarySortBox);
      await box.putAll({
        'albumSortBy': _albumSortBy.name,
        'albumSortOrder': _albumSortOrder.name,
        'artistSortBy': _artistSortBy.name,
        'artistSortOrder': _artistSortOrder.name,
      });
    } catch (error) {
      debugPrint('Failed to save the library sort: $error');
    }
  }

  /// A small Hive box of app preferences (opened once, then reused).
  static Future<Box<dynamic>> _openBox(String name) async {
    await ensureHiveInitialized();
    return Hive.isBoxOpen(name)
        ? Hive.box<dynamic>(name)
        : Hive.openBox<dynamic>(name);
  }

  /// Restores the persisted preferences and session. Pass
  /// [storedPlaybackState] when the caller already loaded it (main does).
  ///
  /// Always ends with [isInitialized] true, even when a step fails, so the
  /// app can't hang on the startup spinner.
  Future<void> initialize({PlaybackState? storedPlaybackState}) async {
    final initStopwatch = Stopwatch()..start();
    debugPrint('NautuneAppState initialization started');
    try {
      await _initialize(storedPlaybackState);
    } catch (error, stackTrace) {
      _lastError = error;
      debugPrint('NautuneAppState initialization failed: $error');
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'app_state',
        context: ErrorDescription('initializing Nautune'),
      ));
    } finally {
      _initialized = true;
      _syncStatusProvider?.setOffline(isOfflineMode);
      notifyListeners();
      // Pick up a session that arrived or changed while initializing (e.g.
      // the keychain unlocked); a no-op when it's the one restored above.
      _onSessionChanged();
      unawaited(_refreshPendingActionsCount());
      debugPrint('NautuneAppState init took: ${initStopwatch.elapsedMilliseconds}ms');
    }
  }

  Future<void> _initialize(PlaybackState? preloadedPlaybackState) async {
    // Parallelize core connectivity and power monitoring
    await Future.wait([
      _ensureConnectivityMonitoring(),
      PowerModeService.instance.initialize(),
      AppIconService()
          .initialize()
          .then((_) => AppIconService().syncIOSIcon())
          .catchError((Object e) => debugPrint('App icon init failed: $e')),
    ]);

    PlaybackState? storedPlaybackState = preloadedPlaybackState;
    if (storedPlaybackState == null) {
      try {
        storedPlaybackState = await _playbackStateStore.load();
      } catch (error) {
        debugPrint('Failed to load playback state: $error');
      }
    }
    // SessionProvider (initialized before this runs) already read the
    // keychain and restored the JellyfinService; reuse its session instead
    // of reading and restoring a second copy. A session that becomes
    // readable later (locked keychain) arrives through _onSessionChanged.
    final sessionProvider = _sessionProvider;
    final storedSession = sessionProvider != null
        ? sessionProvider.session
        : await _loadStoredSessionSafely();

    // Network type for auto quality / Wi-Fi-only caching. Needed even on a
    // first launch (no stored state), which used to leave it unset.
    _audioPlayerService.setConnectivityService(_connectivityService);
    _downloadService.setConnectivityService(_connectivityService);

    if (storedPlaybackState != null) {
      _showVolumeBar = storedPlaybackState.showVolumeBar;
      _crossfadeEnabled = storedPlaybackState.crossfadeEnabled;
      _crossfadeDurationSeconds = storedPlaybackState.crossfadeDurationSeconds;
      _infiniteRadioEnabled = storedPlaybackState.infiniteRadioEnabled;
      _cacheTtlMinutes = storedPlaybackState.cacheTtlMinutes;
      _restoredLibraryTabIndex = storedPlaybackState.libraryTabIndex;
      _navTabOrder = List<int>.from(storedPlaybackState.navTabOrder);
      _gaplessPlaybackEnabled = storedPlaybackState.gaplessPlaybackEnabled;
      _streamingQuality = storedPlaybackState.streamingQuality;
      _visualizerEnabledByUser = storedPlaybackState.visualizerEnabled;
      _preCacheTrackCount = storedPlaybackState.preCacheTrackCount;
      _visualizerType = storedPlaybackState.visualizerType;
      _visualizerPosition = storedPlaybackState.visualizerPosition;
      _nowPlayingLayout = storedPlaybackState.nowPlayingLayout;
      _submarineModeEnabled = storedPlaybackState.submarineModeEnabled ||
          storedPlaybackState.isOfflineMode;
      _restoreLegacyBatterySaverSnapshot(storedPlaybackState);
      _libraryScrollOffsets =
          Map<String, double>.from(storedPlaybackState.scrollOffsets);

      // Apply playback preferences BEFORE restoring the session: the restore
      // prepares the source for the restored track, which must already see
      // the streaming quality, connectivity (network type for auto quality,
      // Wi-Fi-only caching) and battery-saver settings.
      _audioPlayerService.setCrossfadeDuration(_crossfadeDurationSeconds);
      _audioPlayerService.setInfiniteRadioEnabled(_infiniteRadioEnabled);
      _audioPlayerService.setStreamingQuality(_streamingQuality);
      _audioPlayerService.setTranscodeCodec(storedPlaybackState.transcodeCodec);
      _audioPlayerService.setSmartShuffleEnabled(storedPlaybackState.smartShuffleEnabled);
      _remoteControlEnabled = storedPlaybackState.remoteControlEnabled;
      unawaited(_audioPlayerService.setPlaybackSpeed(storedPlaybackState.playbackSpeed));
      unawaited(_audioPlayerService.setReplayGain(
        mode: storedPlaybackState.replayGainMode,
        preampDb: storedPlaybackState.replayGainPreampDb,
      ));
      _audioPlayerService.setWifiOnlyCaching(storedPlaybackState.wifiOnlyCaching);
      _jellyfinService.setCacheTtl(Duration(minutes: _cacheTtlMinutes));

      // Crossfade, gapless and pre-caching: the preferences, or the battery
      // saver's overrides when it was active at the last run.
      _audioPlayerService.setCrossfadeEnabled(
          _crossfadeEnabled && !_submarineModeEnabled);
      _audioPlayerService.setGaplessPlaybackEnabled(
          _gaplessPlaybackEnabled && !_submarineModeEnabled);
      _audioPlayerService.setPreCacheTrackCount(
          _submarineModeEnabled ? 0 : _preCacheTrackCount);
      if (_submarineModeEnabled) {
        _audioPlayerService.setBatterySaverMode(true);
        _audioPlayerService.reportingService?.setProgressInterval(
          const Duration(seconds: 60),
        );
      }

      _initPowerModeListener();

      _downloadService.loadSettings(
        maxConcurrentDownloads: storedPlaybackState.maxConcurrentDownloads,
        wifiOnlyDownloads: storedPlaybackState.wifiOnlyDownloads,
        storageLimitMB: storedPlaybackState.storageLimitMB,
        autoCleanupEnabled: storedPlaybackState.autoCleanupEnabled,
        autoCleanupDays: storedPlaybackState.autoCleanupDays,
      );

      _userWantsOffline = storedPlaybackState.isOfflineMode;
      if (!_remoteControlEnabled) _stopRemoteControl();

      // The battery saver was active at the last run (offline or Low Power
      // Mode) but neither applies any more: lift it now, before the queue
      // is restored, so the preferences apply again.
      _maybeDeactivateSubmarineFeatures();

      if (_userWantsOffline) {
        _audioPlayerService.reportingService?.setEnabled(false);
        _audioPlayerService.setImagePrewarmEnabled(false);
      }
      // Before the queue is restored: offline, the restored track must not
      // be prepared as a stream.
      _audioPlayerService.setOfflineMode(isOfflineMode);

      // Restore the saved queue/track (paused). Doesn't wait on the network:
      // the source is prepared in the background. A failure here must not
      // stop the session from being restored.
      try {
        await _audioPlayerService.hydrateFromPersistence(storedPlaybackState);
      } catch (error) {
        debugPrint('Failed to restore the saved queue: $error');
      }
    } else {
      _initPowerModeListener();
    }

    if (storedSession != null) {
      try {
        if (storedSession.isDemo) {
          if (_demoModeProvider != null) {
            await _demoModeProvider.startDemoMode();
          } else {
            final data = await rootBundle.load('assets/demo/demo_offline_track.mp3');
            await _setupDemoMode(DemoContent(), data.buffer.asUint8List());
          }
          return; // initialize() marks the state initialized
        }

        // Same object as SessionProvider's, so _onSessionChanged sees no
        // change and doesn't restart everything.
        _session = storedSession;
        if (sessionProvider == null) {
          // SessionProvider restores the JellyfinService itself; restoring
          // again would drop its caches and in-flight request sharing.
          _jellyfinService.restoreSession(storedSession);
        }
        _audioPlayerService.setJellyfinService(_jellyfinService);
        // setJellyfinService starts a new image prewarmer (enabled).
        _audioPlayerService.setImagePrewarmEnabled(!isOfflineMode);
        _downloadService.onSessionChanged();

        _installReportingService(storedSession);
        unawaited(_reconcileScrobblerLinks(storedSession));

        // Load cached snapshot and start sync in parallel
        final snapshot = await _bootstrapService.loadCachedSnapshot(
          session: storedSession,
        );
        await _applyBootstrapSnapshot(snapshot);

        if (!_userWantsOffline) {
          _startPeriodicSyncTimer();
        }

        _startSessionNetworkWork(storedSession);
        if (isOfflineMode && _libraryDataProvider?.libraries == null) {
          unawaited(_loadLibraries()); // downloads-based fallback
        }
        // Home sections the app owns (recently played, discover, ...);
        // offline, also the downloads-based collections.
        if (storedSession.selectedLibraryId != null || isOfflineMode) {
          unawaited(_loadLibraryDependentContent(forceRefresh: true));
        }
      } catch (error, stackTrace) {
        _lastError = error;
        debugPrint('Session restoration failed: $error');
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'app_state',
            context: ErrorDescription('restoring Nautune session'),
          ),
        );
      }
    }
  }

  /// Network work for a session that was just restored or signed in.
  /// Online: the bootstrap sync (which also replays offline playlist edits
  /// and detects an expired token) and the analytics sync. Offline: the
  /// offline policy, the battery saver and, unless the user chose offline,
  /// a probe that brings the app back online as soon as the server answers.
  void _startSessionNetworkWork(JellyfinSession session) {
    if (!isOfflineMode) {
      _startBootstrapSync(session);
      unawaited(_syncAnalyticsToServer());
      _publishOfflineState(); // records "online" (policy already live)
    } else {
      _publishOfflineState();
      _activateSubmarineFeatures();
      if (!_userWantsOffline) {
        // No network transport right now: keep checking the server so
        // the app comes back online as soon as it answers.
        _startReachabilityProbe();
      }
    }
  }

  /// Builds before 2026-09 wrote the battery saver's overrides (crossfade,
  /// gapless, pre-cache and visualizer off) into the preference fields and
  /// kept the user's values in `batterySaverSnapshot`. Take the preferences
  /// from such a snapshot, and persist them where they belong.
  void _restoreLegacyBatterySaverSnapshot(PlaybackState stored) {
    final snapshot = stored.batterySaverSnapshot;
    if (snapshot == null || snapshot.isEmpty) return;
    _visualizerEnabledByUser =
        snapshot['visualizerEnabledByUser'] as bool? ?? _visualizerEnabledByUser;
    _crossfadeEnabled = snapshot['crossfadeEnabled'] as bool? ?? _crossfadeEnabled;
    _gaplessPlaybackEnabled =
        snapshot['gaplessPlaybackEnabled'] as bool? ?? _gaplessPlaybackEnabled;
    _preCacheTrackCount =
        (snapshot['preCacheTrackCount'] as num?)?.toInt() ?? _preCacheTrackCount;
    unawaited(_playbackStateStore.saveUiState(
      visualizerEnabled: _visualizerEnabledByUser,
      crossfadeEnabled: _crossfadeEnabled,
      gaplessPlaybackEnabled: _gaplessPlaybackEnabled,
      preCacheTrackCount: _preCacheTrackCount,
      batterySaverSnapshot: <String, dynamic>{}, // empty map = cleared
    ));
  }

  /// Loads the persisted session. When the keychain is locked (cold start
  /// from CarPlay before unlock) this returns null WITHOUT treating it as a
  /// logout; SessionProvider retries and _onSessionChanged picks the session
  /// up once it becomes readable.
  Future<JellyfinSession?> _loadStoredSessionSafely() async {
    try {
      return await _sessionStore.load();
    } on SessionStorageUnavailableException catch (error) {
      debugPrint('Session storage unavailable at startup; waiting for SessionProvider retry: $error');
      return null;
    }
  }

  void _startBootstrapSync(
    JellyfinSession session, {
    String? libraryIdOverride,
  }) {
    _bootstrapService.scheduleSync(
      session: session,
      libraryIdOverride: libraryIdOverride,
      onLibraries: (data) => unawaited(_handleLibrariesBootstrapUpdate(data)),
      onPlaylists: _handlePlaylistsBootstrapUpdate,
      onAlbums: _handleAlbumsBootstrapUpdate,
      onArtists: _handleArtistsBootstrapUpdate,
      onRecent: _handleRecentBootstrapUpdate,
      onRecentlyAdded: _handleRecentlyAddedBootstrapUpdate,
      onNetworkReachable: _handleNetworkRecovered,
      onNetworkLost: _handleNetworkDrop,
      onUnauthorized: _handleBootstrapUnauthorized,
      // LibraryDataProvider loads (and caches) the collections itself; the
      // bootstrap then only fetches the libraries, to detect network loss
      // and an expired session. Its other results went to legacy fields the
      // provider-backed getters never read.
      librariesOnly: _libraryDataProvider != null,
    );
    unawaited(_syncPendingPlaylistActions());
  }

  Future<void> _applyBootstrapSnapshot(BootstrapSnapshot snapshot) async {
    final provider = _libraryDataProvider;
    if (provider != null) {
      // Only fill what the provider doesn't have yet: its own loads started
      // on the session change and may already have fresher data, which a
      // cached snapshot must not overwrite. (The provider validates the
      // selected library against the fresh list itself.)
      provider.applySnapshot(BootstrapSnapshot(
        libraries: provider.libraries == null ? snapshot.libraries : null,
        playlists: provider.playlists == null ? snapshot.playlists : null,
        albums: provider.albums == null ? snapshot.albums : null,
        artists: provider.artists == null ? snapshot.artists : null,
        recentTracks:
            provider.recentTracks == null ? snapshot.recentTracks : null,
        recentlyAddedAlbums: provider.recentlyAddedAlbums == null
            ? snapshot.recentlyAddedAlbums
            : null,
      ));
      return;
    }
    
    final hasSession = _session != null;
    final selectedLibraryId = _session?.selectedLibraryId;

    if (snapshot.libraries != null) {
      _libraries = snapshot.libraries;
      _librariesError = null;
      _isLoadingLibraries = false;
      await _ensureSelectedLibraryStillValid();
    } else if (hasSession) {
      _isLoadingLibraries = true;
    }

    if (snapshot.playlists != null) {
      _playlists = snapshot.playlists;
      _playlistsError = null;
      _isLoadingPlaylists = false;
    } else if (hasSession) {
      _isLoadingPlaylists = true;
    }

    if (snapshot.albums != null) {
      _albums = snapshot.albums;
      _albumsError = null;
      _isLoadingAlbums = false;
    } else if (selectedLibraryId != null) {
      _isLoadingAlbums = true;
    }

    if (snapshot.artists != null) {
      _artists = snapshot.artists;
      _artistsError = null;
      _isLoadingArtists = false;
    } else if (selectedLibraryId != null) {
      _isLoadingArtists = true;
    }

    if (snapshot.recentTracks != null) {
      _recentTracks = snapshot.recentTracks;
      _recentError = null;
      _isLoadingRecent = false;
    } else if (selectedLibraryId != null) {
      _isLoadingRecent = true;
    }

    if (snapshot.recentlyAddedAlbums != null) {
      _recentlyAddedAlbums = snapshot.recentlyAddedAlbums;
      _recentlyAddedError = null;
      _isLoadingRecentlyAdded = false;
    } else if (selectedLibraryId != null) {
      _isLoadingRecentlyAdded = true;
    }

    notifyListeners();
  }

  Future<void> _handleLibrariesBootstrapUpdate(
    List<JellyfinLibrary> data,
  ) async {
    _libraries = data;
    _librariesError = null;
    _isLoadingLibraries = false;
    await _ensureSelectedLibraryStillValid();
    notifyListeners();
  }

  void _handlePlaylistsBootstrapUpdate(List<JellyfinPlaylist> data) {
    _playlists = data;
    _playlistsError = null;
    _isLoadingPlaylists = false;
    unawaited(_playlistStore.save(data));
    notifyListeners();
  }

  void _handleAlbumsBootstrapUpdate(List<JellyfinAlbum> data) {
    _albums = data;
    _albumsError = null;
    _isLoadingAlbums = false;
    _hasMoreAlbums = data.length == _albumsPageSize;
    notifyListeners();
  }

  void _handleArtistsBootstrapUpdate(List<JellyfinArtist> data) {
    _artists = data;
    _artistsError = null;
    _isLoadingArtists = false;
    _hasMoreArtists = data.length == _artistsPageSize;
    notifyListeners();
  }

  void _handleRecentBootstrapUpdate(List<JellyfinTrack> data) {
    _recentTracks = data;
    _recentError = null;
    _isLoadingRecent = false;
    notifyListeners();
  }

  void _handleRecentlyAddedBootstrapUpdate(List<JellyfinAlbum> data) {
    _recentlyAddedAlbums = data;
    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = false;
    notifyListeners();
  }

  /// The server answered again (bootstrap request or reachability probe).
  /// Called on every successful bootstrap fetch, so only the offline →
  /// online transition does anything.
  void _handleNetworkRecovered() {
    _stopReachabilityProbe();
    if (!_networkAvailable) {
      _networkAvailable = true;
      // Re-enable reporting (flushing queued reports), analytics, image
      // prewarm, playback streaming; kick queued downloads. The bootstrap
      // isn't restarted: this is called from a running bootstrap sync, and
      // the probe path refreshes via _refreshAfterReconnect.
      // The battery saver engaged for the outage is lifted too (unless the
      // user chose offline or Low Power Mode is on).
      _maybeDeactivateSubmarineFeatures();
      _publishOfflineState(restartBootstrap: false);
      if (!_userWantsOffline) {
        unawaited(_syncPendingPlaylistActions());
      }
      notifyListeners();
    }
  }

  /// Start the periodic reachability probe (idempotent).
  void _startReachabilityProbe() {
    if (_reachabilityTimer != null) return;
    debugPrint('📡 Starting server reachability probe (every ${_reachabilityProbeInterval.inSeconds}s)');
    _reachabilityTimer = Timer.periodic(
      _reachabilityProbeInterval,
      (_) => unawaited(_probeServerReachability()),
    );
  }

  void _stopReachabilityProbe() {
    _reachabilityTimer?.cancel();
    _reachabilityTimer = null;
  }

  Future<void> _probeServerReachability() async {
    if (_reachabilityProbeInFlight) return;
    final session = _session;
    if (session == null || session.isDemo) {
      _stopReachabilityProbe();
      return;
    }
    if (_networkAvailable) {
      _stopReachabilityProbe();
      return;
    }
    if (_userWantsOffline) return; // Don't generate traffic in user-offline mode
    _reachabilityProbeInFlight = true;
    try {
      final reachable = await _jellyfinService.isServerReachable();
      // Session may have changed (logout) while probing.
      if (!reachable || !identical(_session, session) || _reachabilityTimer == null) {
        return;
      }
      debugPrint('📶 Server reachable again — restoring online state');
      _handleNetworkRecovered();
      unawaited(_refreshAfterReconnect());
    } catch (e) {
      debugPrint('Reachability probe failed: $e');
    } finally {
      _reachabilityProbeInFlight = false;
    }
  }

  void _handleNetworkDrop(Object error) {
    // Bootstrap only reports genuine network failures here (see
    // BootstrapService.isNetworkFailure); probe until the server answers.
    _startReachabilityProbe();
    if (_networkAvailable) {
      _networkAvailable = false;
      // Note: isOfflineMode getter automatically returns true when !_networkAvailable
      debugPrint('Network lost while syncing: $error');
      // Play downloads only, queue reports, stop background traffic.
      _publishOfflineState();

      // Reset all loading flags to prevent stuck states (especially in CarPlay)
      _isLoadingLibraries = false;
      _isLoadingAlbums = false;
      _isLoadingArtists = false;
      _isLoadingPlaylists = false;
      _isLoadingFavorites = false;
      _isLoadingRecent = false;
      _isLoadingRecentlyAdded = false;
      _isLoadingRecentlyPlayed = false;

      notifyListeners();
    }
  }

  void _handleBootstrapUnauthorized() {
    if (_handlingUnauthorizedSession || _session == null) {
      return;
    }
    _handlingUnauthorizedSession = true;
    debugPrint('Bootstrap detected unauthorized session; forcing logout');
    _lastError = JellyfinAuthException('Session expired. Please log in again.');
    notifyListeners();
    unawaited(_logoutAfterUnauthorized());
  }

  Future<void> _logoutAfterUnauthorized() async {
    try {
      await logout();
    } finally {
      _handlingUnauthorizedSession = false;
    }
  }

  Future<void> logout() async {
    final cacheKey = _sessionCacheKey;
    final oldSession = _session;

    // 1. Stop playback while the old token is still valid (so the stop is
    //    reported) and clear the persisted queue snapshot — every track in it
    //    carries the previous user's server URL + access token.
    try {
      await _audioPlayerService.stop();
    } catch (error) {
      debugPrint('Logout: failed to stop playback: $error');
    }
    // A saved queue still waiting to be restored must not be restored
    // under the next account.
    _audioPlayerService.clearPendingRestore();
    try {
      await _playbackStateStore.clearPlaybackData();
    } catch (error) {
      debugPrint('Logout: failed to clear saved playback state: $error');
    }

    // Give playlist edits / favorites queued while offline one last chance
    // to reach this account; whatever is left is dropped below so it can't
    // be replayed into the next account.
    if (!isOfflineMode && !isDemoMode && _session != null) {
      try {
        await _syncPendingPlaylistActions(refreshAfter: false)
            .timeout(const Duration(seconds: 5));
      } catch (error) {
        debugPrint('Logout: pending playlist sync did not finish: $error');
      }
    }
    // A run still in flight stops by itself once the session is cleared
    // below; forget it so the next account's sync starts a fresh run.
    _playlistSyncInFlight = null;

    // 2. Silence all background work tied to the old account.
    _retireReportingService();
    _stopRemoteControl();
    _remoteControl = null;
    _stopReachabilityProbe();
    _stopPeriodicSyncTimer();
    _bootstrapService.cancelSync();
    _jellyfinService.clearSession();
    // Park in-flight downloads as queued. After clearSession, so they wait
    // for the next session instead of restarting with the old token.
    _downloadService.pauseActiveForSessionChange();
    // Revoke the token on the server (best effort). The delay lets the
    // final Stopped report above go out with the token first.
    if (oldSession != null && !oldSession.isDemo) {
      unawaited(_jellyfinService.revokeSessionToken(
        oldSession,
        delay: const Duration(seconds: 5),
      ));
    }

    // 3. Per-account data, cleared while the library is still showing: the
    //    login screen appears only once this is done, so a quick sign-in
    //    (or restarting demo) can't be undone by the rest of this logout.
    //    Each step on its own, so one failure can't skip the others.
    if (oldSession != null) {
      // Remember which account the scrobbler links belong to.
      await _reconcileScrobblerLinks(oldSession);
    }
    if (cacheKey != null) {
      try {
        await _cacheService.clearForSession(cacheKey);
      } catch (error) {
        debugPrint('Logout: failed to clear cached library data: $error');
      }
    }
    try {
      await _sessionStore.clear();
    } catch (error) {
      debugPrint('Logout: failed to clear stored session: $error');
    }

    // Per-account data kept in global boxes: queued offline edits, the
    // offline playlist list and playlist membership. Left in place, the
    // next account would replay the edits and show these playlists.
    try {
      await _syncQueue.clear();
      await _playlistStore.clear();
      await PlaylistMembershipStore.instance.clear();
    } catch (error) {
      debugPrint('Logout: failed to clear per-account playlist data: $error');
    }
    try {
      await ProfileStatsCache.clear();
    } catch (error) {
      debugPrint('Logout: failed to clear profile stats cache: $error');
    }
    try {
      await _clearSearchHistory();
    } catch (error) {
      debugPrint('Logout: failed to clear search history: $error');
    }

    // A bootstrap-detected network drop belongs to the old session; re-derive
    // network state from OS connectivity so the next login isn't stuck
    // offline (applied below, once the old session is gone).
    bool? networkAvailable;
    try {
      networkAvailable = await _connectivityService.hasNetworkConnection();
    } catch (_) {
      // Keep the current value.
    }

    try {
      await _teardownDemoMode();
    } catch (error) {
      debugPrint('Logout: failed to stop demo mode: $error');
    }

    // 4. Clear the SessionProvider BEFORE nulling our own session, so
    //    _onSessionChanged sees the transition (old → null) and runs its
    //    cleanup, and the UI shows the login screen.
    if (_sessionProvider != null) {
      try {
        await _sessionProvider.logout();
      } catch (error) {
        debugPrint('SessionProvider.logout failed: $error');
      }
    }

    // 5. Local cleanup (idempotent with _onSessionChanged's cleanup, and
    //    needed when there is no SessionProvider). Synchronous: nothing
    //    the user does on the login screen can run in between.
    _session = null;
    _stopPeriodicSyncTimer();
    _clearLibraryCaches();
    _clearHomeShelves();
    _isLoadingLibraries = false;
    _isLoadingRecentlyAdded = false;
    _syncStatusProvider?.reset();
    ListeningAnalyticsService().setCurrentAccount();
    if (networkAvailable != null) _networkAvailable = networkAvailable;
    // "Go offline" was this account's choice. Kept, the next sign-in (which
    // needs the network anyway) would land offline on an empty cache.
    if (_userWantsOffline) {
      _userWantsOffline = false;
      unawaited(_playbackStateStore.saveUiState(isOfflineMode: false));
    }
    _maybeDeactivateSubmarineFeatures();
    _publishOfflineState();
    notifyListeners();
  }

  /// Recent searches live in one global box; they belong to the account
  /// that searched.
  static Future<void> _clearSearchHistory() async {
    final box = await _openBox('nautune_search_history');
    await box.clear();
  }

  /// Which Jellyfin account ("server|user") connected Last.fm and
  /// ListenBrainz. Those links are device-wide; kept blindly, another
  /// account signing in here would scrobble into them.
  static const _scrobblerLinksBox = 'nautune_scrobbler_links';

  /// Records the owner of a connected scrobbler (the first account seen
  /// with it), and disconnects a scrobbler that another account connected.
  /// Called on sign-in / restore and on logout. Best effort.
  Future<void> _reconcileScrobblerLinks(JellyfinSession session) async {
    if (session.isDemo) return;
    final account = _accountKey(session);
    try {
      final box = await _openBox(_scrobblerLinksBox);

      Future<void> reconcile(
        String key, {
        required bool connected,
        required Future<void> Function() disconnect,
      }) async {
        final owner = box.get(key) as String?;
        switch (decideScrobblerLink(
          connected: connected,
          owner: owner,
          account: account,
        )) {
          case ScrobblerLinkAction.keep:
            break;
          case ScrobblerLinkAction.adopt:
            await box.put(key, account);
          case ScrobblerLinkAction.forget:
            await box.delete(key);
          case ScrobblerLinkAction.disconnect:
            debugPrint('Disconnecting $key: it was connected by another account');
            await disconnect();
            await box.delete(key);
        }
      }

      final lastFm = LastFmService.instance;
      await lastFm.initialize();
      await reconcile(
        'lastfm',
        connected: lastFm.isConfigured,
        disconnect: lastFm.disconnect,
      );
      final listenBrainz = ListenBrainzService();
      await listenBrainz.initialize();
      await reconcile(
        'listenbrainz',
        connected: listenBrainz.isConfigured,
        disconnect: listenBrainz.disconnect,
      );
    } catch (error) {
      debugPrint('Scrobbler account check failed: $error');
    }
  }

  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  /// Reload the libraries and everything shown for the selected library
  /// (pull-to-refresh, retry, back online).
  Future<void> refreshLibraries() async {
    final provider = _libraryDataProvider;
    if (provider != null) {
      // Demo collections are local; nothing to fetch.
      if (_demoModeProvider?.isDemoMode ?? false) return;
      await provider.loadLibraries();
      // Libraries alone left albums, playlists, favorites, ... (and their
      // errors from an offline start) stale after reconnecting.
      if (_sessionProvider?.session?.selectedLibraryId != null) {
        await Future.wait([
          provider.loadAllLibraryData(forceRefresh: true),
          _loadLibraryDependentContent(forceRefresh: true),
        ]);
      }
      return;
    }
    await _loadLibraries();
    await _loadLibraryDependentContent(forceRefresh: true);
  }

  // Playlist Management
  Future<JellyfinPlaylist> createPlaylist({
    required String name,
    List<String>? itemIds,
  }) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        return _demoModeProvider.createPlaylist(name: name, itemIds: itemIds);
      }
      _demoPlaylistCounter++;
      final playlistId = 'demo-playlist-$_demoPlaylistCounter';
      final tracks = List<String>.from(itemIds ?? const <String>[]);
      final playlist = JellyfinPlaylist(
        id: playlistId,
        name: name,
        trackCount: tracks.length,
      );
      _demoPlaylistTrackMap[playlistId] = tracks;
      _replaceDemoPlaylist(playlist);
      notifyListeners();
      return playlist;
    }

    if (isOfflineMode) {
      await _queueAction(PendingPlaylistAction(
        type: 'create',
        payload: {
          'name': name,
          'itemIds': itemIds ?? [],
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Playlist creation queued for sync');
    }
    
    final playlist = await _jellyfinService.createPlaylist(
      name: name,
      itemIds: itemIds,
    );
    await refreshPlaylists();
    return playlist;
  }

  Future<void> updatePlaylist({
    required String playlistId,
    required String newName,
  }) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        _demoModeProvider.updatePlaylist(playlistId: playlistId, newName: newName);
        return;
      }
      final existing = _findPlaylist(playlistId);
      if (existing != null) {
        _replaceDemoPlaylist(JellyfinPlaylist(
          id: existing.id,
          name: newName,
          trackCount: existing.trackCount,
        ));
        notifyListeners();
      }
      return;
    }

    if (isOfflineMode) {
      await _queueAction(PendingPlaylistAction(
        type: 'update',
        payload: {
          'playlistId': playlistId,
          'newName': newName,
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Playlist update queued for sync');
    }
    
    await _jellyfinService.updatePlaylist(
      playlistId: playlistId,
      newName: newName,
    );
    await refreshPlaylists();
  }

  Future<void> deletePlaylist(String playlistId) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        _demoModeProvider.deletePlaylist(playlistId);
        return;
      }
      _demoPlaylistTrackMap.remove(playlistId);
      _removeDemoPlaylist(playlistId);
      notifyListeners();
      return;
    }

    if (isOfflineMode) {
      await _queueAction(PendingPlaylistAction(
        type: 'delete',
        payload: {
          'playlistId': playlistId,
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Playlist deletion queued for sync');
    }
    
    await _jellyfinService.deletePlaylist(playlistId);
    unawaited(PlaylistMembershipStore.instance.remove(playlistId));
    await refreshPlaylists();
  }

  Future<void> addToPlaylist({
    required String playlistId,
    required List<String> itemIds,
  }) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        _demoModeProvider.addToPlaylist(playlistId: playlistId, itemIds: itemIds);
        return;
      }
      final existing = _demoPlaylistTrackMap[playlistId] ?? <String>[];
      final updated = List<String>.from(existing)..addAll(itemIds);
      _demoPlaylistTrackMap[playlistId] = updated;
      final playlist = _findPlaylist(playlistId);
      if (playlist != null) {
        _replaceDemoPlaylist(JellyfinPlaylist(
          id: playlist.id,
          name: playlist.name,
          trackCount: updated.length,
        ));
      }
      notifyListeners();
      return;
    }

    if (isOfflineMode) {
      await _queueAction(PendingPlaylistAction(
        type: 'add',
        payload: {
          'playlistId': playlistId,
          'itemIds': itemIds,
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Adding to playlist queued for sync');
    }
    
    await _jellyfinService.addItemsToPlaylist(
      playlistId: playlistId,
      itemIds: itemIds,
    );
    await refreshPlaylists();
  }

  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        return _demoModeProvider.getPlaylistTracks(playlistId);
      }
      final ids = _demoPlaylistTrackMap[playlistId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    // When offline, playlists are not fully supported yet
    // Return empty list instead of making network request
    if (isOfflineMode) {
      return await repository.getPlaylistTracks(playlistId);
    }
    final tracks = await _jellyfinService.getPlaylistItems(playlistId);
    // Remember the order/membership so the offline library can show this
    // playlist's downloaded tracks (however they were downloaded).
    unawaited(PlaylistMembershipStore.instance
        .save(playlistId, [for (final t in tracks) t.id]));
    return tracks;
  }

  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        return _demoModeProvider.getAlbumTracks(albumId);
      }
      final ids = _demoAlbumTrackMap[albumId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    // When offline, use downloaded tracks from the download service
    if (isOfflineMode) {
      return await repository.getAlbumTracks(albumId);
    }
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        _demoModeProvider.markFavorite(itemId, shouldBeFavorite);
        return;
      }
      final existing = _demoTracks[itemId];
      if (existing != null) {
        _demoTracks[itemId] = existing.copyWith(isFavorite: shouldBeFavorite);
        if (shouldBeFavorite) {
          _demoFavoriteTrackIds.add(itemId);
        } else {
          _demoFavoriteTrackIds.remove(itemId);
        }
        _favoriteTracks =
            _demoTracksFromIds(_demoFavoriteTrackIds.toList());
        notifyListeners();
      }
      return;
    }

    if (isOfflineMode) {
      await _queueAction(PendingPlaylistAction(
        type: 'favorite',
        payload: {
          'itemId': itemId,
          'shouldBeFavorite': shouldBeFavorite,
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Favorite action queued for sync');
    }
    
    await _jellyfinService.markFavorite(itemId, shouldBeFavorite);
  }

  Future<void> _loadLibraries() async {
    _librariesError = null;
    _isLoadingLibraries = true;
    notifyListeners();

    if (_isDemoMode) {
      final library = _demoContent?.library;
      _libraries = library != null ? [library] : <JellyfinLibrary>[];
      _isLoadingLibraries = false;
      notifyListeners();
      return;
    }

    if (isOfflineMode) {
      // In offline mode, keep existing library data from cache;
      // fall back to offline repository if empty
      if (_libraries == null || _libraries!.isEmpty) {
        _libraries = await repository.getLibraries();
      }
      _librariesError = null;
      _isLoadingLibraries = false;
      notifyListeners();
      return;
    }

    try {
      final results = await _jellyfinService.loadLibraries();
      final audioLibraries =
          results.where((lib) => lib.isAudioLibrary).toList();
      _libraries = audioLibraries;

      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveLibraries(cacheKey, audioLibraries);
      }
      await _ensureSelectedLibraryStillValid();
    } catch (error) {
      _librariesError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readLibraries(cacheKey);
        if (cached != null && cached.isNotEmpty) {
          _libraries = cached;
        } else {
          _libraries = null;
        }
      } else {
        _libraries = null;
      }
    } finally {
      _isLoadingLibraries = false;
      notifyListeners();
    }
  }

  Future<void> _ensureSelectedLibraryStillValid() async {
    final libs = _libraries;
    final session = _session;
    if (libs == null || session == null) {
      return;
    }
    final currentId = session.selectedLibraryId;
    if (currentId == null) {
      return;
    }
    final stillExists = libs.any((lib) => lib.id == currentId);
    if (!stillExists) {
      final updated = session.copyWith(
        selectedLibraryId: null,
        selectedLibraryName: null,
      );
      _session = updated;
      await _sessionStore.save(updated);
      _albums = null;
      _artists = null;
      _recentTracks = null;
      _recentlyAddedAlbums = null;
    }
  }

  Future<void> selectLibrary(JellyfinLibrary library) async {
    debugPrint('Select library called: ${library.name} (${library.id})');
    if (_sessionProvider == null) {
      // Fallback for when SessionProvider is not available (shouldn't happen in new setup)
      final session = _session;
      if (session == null) {
        return;
      }
      final updated = session.copyWith(
        selectedLibraryId: library.id,
        selectedLibraryName: library.name,
      );
      _session = updated;
      if (!_isDemoMode) {
        await _sessionStore.save(updated);
      }
      final snapshot = await _bootstrapService.loadCachedSnapshot(
        session: updated,
        libraryIdOverride: library.id,
      );
      await _applyBootstrapSnapshot(snapshot);
      _startBootstrapSync(updated, libraryIdOverride: library.id);
      unawaited(_loadFavorites(forceRefresh: true));
      unawaited(_loadGenres(library.id, forceRefresh: true));
    } else {
      // Delegate to SessionProvider for state management
      debugPrint('Calling sessionProvider.updateSelectedLibrary');
      await _sessionProvider.updateSelectedLibrary(
        libraryId: library.id,
        libraryName: library.name,
      );
      debugPrint('Session provider update complete');
      // _onSessionChanged will handle the rest
    }
  }

  Future<void> refreshAlbums() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadAlbums(forceRefresh: true);
      return;
    }
    await _loadAlbumsForSelectedLibrary(forceRefresh: true);
  }

  Future<void> refreshArtists() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadArtists(forceRefresh: true);
      return;
    }
    final libraryId = _session?.selectedLibraryId;
    if (libraryId != null) {
      await _loadArtistsForLibrary(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshLibraryData() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadAllLibraryData(forceRefresh: true);
      return;
    }
    final libraryId = _session?.selectedLibraryId;
    if (libraryId != null) {
      await _loadLibraryDependentContent(forceRefresh: true);
    }
  }

  Future<void> refreshPlaylists() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadPlaylists(forceRefresh: true);
      return;
    }
    await _loadPlaylistsForSelectedLibrary(forceRefresh: true);
  }

  Future<void> refreshRecentTracks() async {
    await _loadRecentForSelectedLibrary(forceRefresh: true);
  }

  Future<void> _loadLibraryDependentContent({bool forceRefresh = false}) async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null) {
      _albums = null;
      _albumsError = null;
      _isLoadingAlbums = false;
      _playlists = null;
      _playlistsError = null;
      _isLoadingPlaylists = false;
      _recentTracks = null;
      _recentError = null;
      _isLoadingRecent = false;
      _genres = null;
      _genresError = null;
      _isLoadingGenres = false;
      notifyListeners();
      return;
    }

    if (_isDemoMode) {
      _applyDemoCollections();
      _isLoadingAlbums = false;
      _isLoadingArtists = false;
      _isLoadingPlaylists = false;
      _isLoadingRecent = false;
      _isLoadingFavorites = false;
      _isLoadingGenres = false;
      _isLoadingRecentlyPlayed = false;
      _isLoadingMostPlayedTracks = false;
      _isLoadingMostPlayedAlbums = false;
      _isLoadingLongestTracks = false;
      notifyListeners();
      return;
    }

    // Online, LibraryDataProvider (when wired) loads the library collections
    // itself (albums, artists, playlists, recent, recently added, favorites,
    // genres) and the getters prefer its lists, so loading them here too
    // only duplicated every request. Offline, these legacy loaders still
    // provide the downloads-based fallback through OfflineRepository.
    final providerOwnsCollections =
        _libraryDataProvider != null && !isOfflineMode;

    // Load all data in parallel with individual timeouts
    // eagerError: false ensures one slow/failed request doesn't cancel others
    await Future.wait([
      if (!providerOwnsCollections) ...[
        _loadAlbumsForLibrary(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Albums load timed out')),
        _loadArtistsForLibrary(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Artists load timed out')),
        _loadPlaylistsForLibrary(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Playlists load timed out')),
        _loadRecentForLibrary(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Recent load timed out')),
        _loadRecentlyAddedForLibrary(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ RecentlyAdded load timed out')),
        _loadGenres(libraryId, forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Genres load timed out')),
      ],
      // Skip the legacy favorites load when LibraryDataProvider is wired —
      // it loads favorites itself via loadAllLibraryData on session change,
      // and the favoriteTracks getter prefers the provider's list.
      if (_libraryDataProvider == null)
        _loadFavorites(forceRefresh: forceRefresh)
            .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Favorites load timed out')),
      // Home sections only the app state owns.
      // Recommendations are seeded from the recently played list, so they
      // wait for this library's list (not the previous one).
      _loadRecentlyPlayed(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ RecentlyPlayed load timed out'))
          .then((_) => _loadRecommendations(libraryId, forceRefresh: forceRefresh)
              .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Recommendations load timed out'))),
      _loadDiscoverTracks(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Discover load timed out')),
      _loadOnThisDayTracks(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ OnThisDay load timed out')),
    ], eagerError: false);
  }

  Future<void> _loadAlbumsForSelectedLibrary({bool forceRefresh = false}) async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null) {
      _albums = null;
      _albumsError = null;
      _isLoadingAlbums = false;
      notifyListeners();
      return;
    }
    await _loadAlbumsForLibrary(libraryId, forceRefresh: forceRefresh);
  }

  Future<void> _loadArtistsForSelectedLibrary({bool forceRefresh = false}) async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null) {
      _artists = null;
      _artistsError = null;
      _isLoadingArtists = false;
      notifyListeners();
      return;
    }
    await _loadArtistsForLibrary(libraryId, forceRefresh: forceRefresh);
  }

  Future<void> _loadPlaylistsForSelectedLibrary(
      {bool forceRefresh = false}) async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null) {
      _playlists = null;
      _playlistsError = null;
      _isLoadingPlaylists = false;
      notifyListeners();
      return;
    }
    await _loadPlaylistsForLibrary(libraryId, forceRefresh: forceRefresh);
  }

  Future<void> _loadRecentForSelectedLibrary({bool forceRefresh = false}) async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null) {
      _recentTracks = null;
      _recentError = null;
      _isLoadingRecent = false;
      notifyListeners();
      return;
    }
    await _loadRecentForLibrary(libraryId, forceRefresh: forceRefresh);
  }

  Future<void> _loadAlbumsForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _albumsError = null;
    _isLoadingAlbums = true;
    _albumsPage = 0;
    _albumsLoadId++;
    _hasMoreAlbums = true;
    notifyListeners();

    if (_isDemoMode) {
      _albums = _demoContent?.albums ?? const <JellyfinAlbum>[];
      _hasMoreAlbums = false;
      _isLoadingAlbums = false;
      notifyListeners();
      return;
    }

    try {
      // Use repository for offline UI parity
      final albums = await repository.getAlbums(
        libraryId: libraryId,
        startIndex: 0,
        limit: _albumsPageSize,
        sortBy: _albumSortBy,
        sortOrder: _albumSortOrder,
      );
      _albums = albums;
      _hasMoreAlbums = albums.length == _albumsPageSize;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveAlbums(
          cacheKey,
          libraryId: libraryId,
          data: albums,
        );
      }
    } catch (error) {
      _albumsError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached =
            await _cacheService.readAlbums(cacheKey, libraryId: libraryId);
        if (cached != null && cached.isNotEmpty) {
          _albums = cached;
        } else {
          _albums = null;
        }
      } else {
        _albums = null;
      }
    } finally {
      _isLoadingAlbums = false;
      notifyListeners();
    }
  }

  /// Load every remaining album (before an A-Z jump past the loaded pages).
  Future<void> loadAllAlbums() async {
    await _libraryDataProvider?.loadAllAlbums();
  }

  /// Load every remaining artist (before an A-Z jump past the loaded pages).
  Future<void> loadAllArtists() async {
    await _libraryDataProvider?.loadAllArtists();
  }

  Future<void> loadMoreAlbums() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadMoreAlbums();
      return;
    }
    if (_isDemoMode) {
      return;
    }
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null || 
        _isLoadingMoreAlbums || 
        _isLoadingAlbums || 
        !_hasMoreAlbums ||
        _albums == null) {
      return;
    }

    _isLoadingMoreAlbums = true;
    final loadId = _albumsLoadId;
    notifyListeners();

    try {
      _albumsPage++;
      final newAlbums = await repository.getAlbums(
        libraryId: libraryId,
        startIndex: _albumsPage * _albumsPageSize,
        limit: _albumsPageSize,
        sortBy: _albumSortBy,
        sortOrder: _albumSortOrder,
      );

      // Discard results if sort/load changed while awaiting
      if (_albumsLoadId != loadId) return;

      if (newAlbums.isEmpty || newAlbums.length < _albumsPageSize) {
        _hasMoreAlbums = false;
      }

      _albums = [..._albums!, ...newAlbums];
    } catch (error) {
      debugPrint('Error loading more albums: $error');
      _albumsPage--; // Revert page on error
    } finally {
      _isLoadingMoreAlbums = false;
      notifyListeners();
    }
  }

  Future<void> _loadArtistsForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _artistsError = null;
    _isLoadingArtists = true;
    _artistsPage = 0;
    _hasMoreArtists = true;
    notifyListeners();

    if (_isDemoMode) {
      _artists = _demoContent?.artists ?? const <JellyfinArtist>[];
      _hasMoreArtists = false;
      _isLoadingArtists = false;
      notifyListeners();
      return;
    }

    try {
      // Use repository for offline UI parity
      final artists = await repository.getArtists(
        libraryId: libraryId,
        startIndex: 0,
        limit: _artistsPageSize,
        sortBy: _artistSortBy,
        sortOrder: _artistSortOrder,
      );
      _artists = artists;
      _hasMoreArtists = artists.length == _artistsPageSize;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveArtists(
          cacheKey,
          libraryId: libraryId,
          data: artists,
        );
      }
    } catch (error) {
      _artistsError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached =
            await _cacheService.readArtists(cacheKey, libraryId: libraryId);
        if (cached != null && cached.isNotEmpty) {
          _artists = cached;
        } else {
          _artists = null;
        }
      } else {
        _artists = null;
      }
    } finally {
      _isLoadingArtists = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreArtists() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadMoreArtists();
      return;
    }
    if (_isDemoMode) {
      return;
    }
    final libraryId = _session?.selectedLibraryId;
    if (libraryId == null || 
        _isLoadingMoreArtists || 
        _isLoadingArtists || 
        !_hasMoreArtists ||
        _artists == null) {
      return;
    }

    _isLoadingMoreArtists = true;
    notifyListeners();

    try {
      _artistsPage++;
      final newArtists = await repository.getArtists(
        libraryId: libraryId,
        startIndex: _artistsPage * _artistsPageSize,
        limit: _artistsPageSize,
        sortBy: _artistSortBy,
        sortOrder: _artistSortOrder,
      );
      
      if (newArtists.isEmpty || newArtists.length < _artistsPageSize) {
        _hasMoreArtists = false;
      }
      
      _artists = [..._artists!, ...newArtists];
    } catch (error) {
      debugPrint('Error loading more artists: $error');
      _artistsPage--; // Revert page on error
    } finally {
      _isLoadingMoreArtists = false;
      notifyListeners();
    }
  }

  Future<void> _loadPlaylistsForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _playlistsError = null;
    _isLoadingPlaylists = true;
    notifyListeners();

    if (_isDemoMode) {
      _playlists ??=
          List<JellyfinPlaylist>.from(_demoContent?.playlists ?? const []);
      _isLoadingPlaylists = false;
      notifyListeners();
      return;
    }

    try {
      // Load ALL playlists via repository
      _playlists = await repository.getPlaylists();
      
      if (_playlists != null) {
        await _playlistStore.save(_playlists!);
        final cacheKey = _sessionCacheKey;
        if (cacheKey != null) {
          await _cacheService.savePlaylists(cacheKey, _playlists!);
        }
      }
    } catch (error) {
      _playlistsError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readPlaylists(cacheKey);
        if (cached != null && cached.isNotEmpty) {
          _playlists = cached;
        } else {
          _playlists = await _playlistStore.load();
        }
      } else {
        _playlists = await _playlistStore.load();
      }
    } finally {
      _isLoadingPlaylists = false;
      notifyListeners();
    }
  }

  /// Demo "recent" tracks: DemoModeProvider's when it runs the demo, else
  /// the legacy demo state's.
  List<JellyfinTrack> _demoRecentTracks() {
    final provider = _demoModeProvider;
    if (provider != null && provider.isDemoMode) return provider.recentTracks;
    return _demoTracksFromIds(_demoRecentTrackIds);
  }

  List<JellyfinAlbum> _demoAlbumList() {
    final provider = _demoModeProvider;
    if (provider != null && provider.isDemoMode) return provider.albums;
    return _demoContent?.albums ?? const <JellyfinAlbum>[];
  }

  // The loaders below (legacy collections used offline or without
  // LibraryDataProvider, and the home shelves the app state owns) capture
  // [_shelvesGeneration]: a result that arrives after the account or
  // library changed is dropped, and only the current load clears its
  // loading flag. Offline they make no network requests.

  Future<void> _loadRecentForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    final gen = _shelvesGeneration;
    _recentError = null;
    _isLoadingRecent = true;
    notifyListeners();

    if (_isDemoMode) {
      _recentTracks = _demoRecentTracks();
      _isLoadingRecent = false;
      notifyListeners();
      return;
    }

    final cacheKey = _sessionCacheKey;
    Future<List<JellyfinTrack>?> readCached() async {
      if (cacheKey == null) return null;
      final cached =
          await _cacheService.readRecentTracks(cacheKey, libraryId: libraryId);
      return (cached == null || cached.isEmpty) ? null : cached;
    }

    try {
      if (isOfflineMode) {
        final cached = await readCached();
        if (gen != _shelvesGeneration) return;
        if (cached != null) _recentTracks = cached;
        return;
      }
      final tracks = await _jellyfinService.loadRecentTracks(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      if (gen != _shelvesGeneration) return;
      _recentTracks = tracks;
      if (cacheKey != null) {
        await _cacheService.saveRecentTracks(
          cacheKey,
          libraryId: libraryId,
          data: tracks,
        );
      }
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _recentError = error;
      final cached = await readCached();
      if (gen != _shelvesGeneration) return;
      _recentTracks = cached;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingRecent = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadRecentlyAddedForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    final gen = _shelvesGeneration;
    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = true;
    notifyListeners();

    if (_isDemoMode) {
      _recentlyAddedAlbums = _demoAlbumList();
      _isLoadingRecentlyAdded = false;
      notifyListeners();
      return;
    }

    final cacheKey = _sessionCacheKey;
    Future<List<JellyfinAlbum>?> readCached() async {
      if (cacheKey == null) return null;
      final cached = await _cacheService.readRecentlyAddedAlbums(
        cacheKey,
        libraryId: libraryId,
      );
      return (cached == null || cached.isEmpty) ? null : cached;
    }

    try {
      if (isOfflineMode) {
        final cached = await readCached();
        if (gen != _shelvesGeneration) return;
        if (cached != null) _recentlyAddedAlbums = cached;
        return;
      }
      final albums = await _jellyfinService.loadRecentlyAddedAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _recentlyAddedAlbums = albums;
      if (cacheKey != null) {
        await _cacheService.saveRecentlyAddedAlbums(
          cacheKey,
          libraryId: libraryId,
          data: albums,
        );
      }
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _recentlyAddedError = error;
      final cached = await readCached();
      if (gen != _shelvesGeneration) return;
      _recentlyAddedAlbums = cached;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingRecentlyAdded = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshRecent() async {
    // Demo collections are local; nothing to refresh.
    if (isDemoMode) return;
    final provider = _libData;
    if (provider != null) {
      await provider.loadRecentTracks(forceRefresh: true);
      return;
    }
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecentForLibrary(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshRecentlyAdded() async {
    // Demo collections are local; nothing to refresh.
    if (isDemoMode) return;
    // The recentlyAddedAlbums getter reads the provider when it's wired, so
    // refresh that list (the legacy one would never show).
    final provider = _libData;
    if (provider != null) {
      await provider.loadRecentlyAddedAlbums(forceRefresh: true);
      return;
    }
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecentlyAddedForLibrary(libraryId, forceRefresh: true);
    }
  }

  Future<void> _loadFavorites({bool forceRefresh = false}) async {
    _favoritesError = null;
    _isLoadingFavorites = true;
    notifyListeners();

    if (_isDemoMode) {
      _favoriteTracks = _demoTracksFromIds(
        _demoFavoriteTrackIds.toList(),
      );
      _isLoadingFavorites = false;
      notifyListeners();
      return;
    }

    if (isOfflineMode) {
      try {
        _favoriteTracks = await repository.getFavoriteTracks();
      } catch (error) {
        _favoritesError = error;
        _favoriteTracks = null;
      } finally {
        _isLoadingFavorites = false;
        notifyListeners();
      }
      return;
    }

    try {
      _favoriteTracks = await _jellyfinService.getFavoriteTracks();

      // Merge durations from downloaded tracks (fixes duration accuracy)
      if (_favoriteTracks != null) {
        _favoriteTracks = _favoriteTracks!.map((track) {
          final downloadedTrack = _downloadService.trackFor(track.id);
          if (downloadedTrack != null && downloadedTrack.duration != null) {
            // Use downloaded track's accurate duration
            return track.copyWith(runTimeTicks: downloadedTrack.runTimeTicks);
          }
          return track;
        }).toList();
      }
    } catch (error) {
      _favoritesError = error;
      _favoriteTracks = null;
    } finally {
      _isLoadingFavorites = false;
      notifyListeners();
    }
  }

  Future<void> refreshFavorites() async {
    if (_libraryDataProvider != null) {
      await _libraryDataProvider.loadFavorites(forceRefresh: true);
      return;
    }
    await _loadFavorites(forceRefresh: true);
  }

  Future<void> refreshGenres() async {
    // Demo collections are local; nothing to refresh.
    if (isDemoMode) return;
    // The genres getter reads the provider when it's wired (not in demo
    // mode), so refresh that list, as refreshAlbums/refreshArtists do.
    final provider = _libData;
    if (provider != null) {
      await provider.loadGenres(forceRefresh: true);
      return;
    }
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadGenres(libraryId, forceRefresh: true);
    }
  }

  Future<void> _loadGenres(String libraryId, {bool forceRefresh = false}) async {
    _genresError = null;
    _isLoadingGenres = true;
    notifyListeners();

    if (_isDemoMode) {
      _genres = _demoModeProvider?.genres ??
          _demoContent?.genres ??
          const <JellyfinGenre>[];
      _isLoadingGenres = false;
      notifyListeners();
      return;
    }

    try {
      _genres = await repository.getGenres(libraryId: libraryId);
    } catch (error) {
      _genresError = error;
      _genres = null;
    } finally {
      _isLoadingGenres = false;
      notifyListeners();
    }
  }

  Future<void> _loadRecentlyPlayed(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _recentlyPlayedTracks = _demoRecentTracks().take(10).toList();
      _isLoadingRecentlyPlayed = false;
      notifyListeners();
      return;
    }

    final gen = _shelvesGeneration;
    _isLoadingRecentlyPlayed = true;
    notifyListeners();
    try {
      // The repository serves downloads offline.
      final tracks = await repository.getRecentlyPlayedTracks(
        libraryId: libraryId,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _recentlyPlayedTracks = tracks;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _recentlyPlayedTracks = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingRecentlyPlayed = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadMostPlayedTracks(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _mostPlayedTracks = _demoRecentTracks().take(10).toList();
      _isLoadingMostPlayedTracks = false;
      notifyListeners();
      return;
    }
    if (isOfflineMode) return; // Server data: keep what's shown.

    final gen = _shelvesGeneration;
    _isLoadingMostPlayedTracks = true;
    notifyListeners();
    try {
      final tracks = await _jellyfinService.getMostPlayedTracks(
        libraryId: libraryId,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _mostPlayedTracks = tracks;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _mostPlayedTracks = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingMostPlayedTracks = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadMostPlayedAlbums(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _mostPlayedAlbums = _demoAlbumList().take(10).toList();
      _isLoadingMostPlayedAlbums = false;
      notifyListeners();
      return;
    }
    if (isOfflineMode) return; // Server data: keep what's shown.

    final gen = _shelvesGeneration;
    _isLoadingMostPlayedAlbums = true;
    notifyListeners();
    try {
      final albums = await _jellyfinService.getMostPlayedAlbums(
        libraryId: libraryId,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _mostPlayedAlbums = albums;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _mostPlayedAlbums = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingMostPlayedAlbums = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadLongestTracks(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _longestTracks = _demoRecentTracks().take(10).toList();
      _isLoadingLongestTracks = false;
      notifyListeners();
      return;
    }
    if (isOfflineMode) return; // Server data: keep what's shown.

    final gen = _shelvesGeneration;
    _isLoadingLongestTracks = true;
    notifyListeners();
    try {
      final tracks = await _jellyfinService.getLongestRuntimeTracks(
        libraryId: libraryId,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _longestTracks = tracks;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      _longestTracks = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingLongestTracks = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshRecentlyPlayed() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecentlyPlayed(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshMostPlayedTracks() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadMostPlayedTracks(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshMostPlayedAlbums() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadMostPlayedAlbums(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshLongestTracks() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadLongestTracks(libraryId, forceRefresh: true);
    }
  }

  Future<void> _loadDiscoverTracks(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      // In demo mode, shuffle some tracks as "discover"
      _discoverTracks = _demoRecentTracks().reversed.take(10).toList();
      _isLoadingDiscover = false;
      notifyListeners();
      return;
    }
    if (isOfflineMode) return; // Server data: keep what's shown.

    final gen = _shelvesGeneration;
    _isLoadingDiscover = true;
    notifyListeners();
    try {
      // Get tracks with less than 3 plays (rarely played = discover)
      final tracks = await _jellyfinService.getLeastPlayedTracks(
        libraryId: libraryId,
        maxPlayCount: 3,
        limit: 20,
      );
      if (gen != _shelvesGeneration) return;
      _discoverTracks = tracks;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      debugPrint('Failed to load discover tracks: $error');
      _discoverTracks = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingDiscover = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadOnThisDayTracks(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _onThisDayTracks = _demoRecentTracks().take(5).toList();
      _isLoadingOnThisDay = false;
      notifyListeners();
      return;
    }

    final gen = _shelvesGeneration;
    _isLoadingOnThisDay = true;
    notifyListeners();
    try {
      // Get tracks from local analytics that were played on this day in previous years
      final analyticsService = ListeningAnalyticsService();
      final onThisDayEvents = analyticsService.getOnThisDayEvents();

      if (onThisDayEvents.isEmpty) {
        _onThisDayTracks = [];
      } else {
        // Get unique track IDs from the events
        final trackIds = onThisDayEvents.map((e) => e.trackId).toSet().take(20).toList();

        // Offline, only the downloaded ones (no server request). Online,
        // batch fetch all tracks at once for better performance.
        final tracks = isOfflineMode
            ? trackIds
                .map(_downloadService.trackFor)
                .whereType<JellyfinTrack>()
                .toList()
            : await _jellyfinService.loadTracksByIds(trackIds);
        if (gen != _shelvesGeneration) return;
        _onThisDayTracks = tracks;
      }
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      debugPrint('Failed to load on this day tracks: $error');
      _onThisDayTracks = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingOnThisDay = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshDiscover() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadDiscoverTracks(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshOnThisDay() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadOnThisDayTracks(libraryId, forceRefresh: true);
    }
  }

  Future<void> _loadRecommendations(String libraryId, {bool forceRefresh = false}) async {
    if (_isDemoMode) {
      _recommendationTracks = _demoRecentTracks().take(10).toList();
      _recommendationSeedTrackName = 'Demo Track';
      _isLoadingRecommendations = false;
      notifyListeners();
      return;
    }
    if (isOfflineMode) return; // Server data: keep what's shown.

    final gen = _shelvesGeneration;
    _isLoadingRecommendations = true;
    notifyListeners();
    try {
      // Get a seed track from recently played or most played
      JellyfinTrack? seedTrack;

      // Try recently played first
      if (_recentlyPlayedTracks != null && _recentlyPlayedTracks!.isNotEmpty) {
        seedTrack = _recentlyPlayedTracks!.first;
      } else if (recentTracks?.isNotEmpty ?? false) {
        seedTrack = recentTracks!.first;
      }

      if (seedTrack == null) {
        // No seed track available, try to get most played
        final mostPlayed = await _jellyfinService.getMostPlayedTracks(
          libraryId: libraryId,
          limit: 1,
        );
        if (gen != _shelvesGeneration) return;
        if (mostPlayed.isNotEmpty) {
          seedTrack = mostPlayed.first;
        }
      }

      if (seedTrack == null) {
        _recommendationTracks = [];
        _recommendationSeedTrackName = null;
        return;
      }

      // Get instant mix based on the seed track
      final recommendations = await _jellyfinService.getInstantMix(
        itemId: seedTrack.id,
        limit: 30,
      );
      if (gen != _shelvesGeneration) return;

      // Filter out the seed track itself
      _recommendationTracks = recommendations.where((t) => t.id != seedTrack!.id).take(20).toList();
      _recommendationSeedTrackName = seedTrack.name;
    } catch (error) {
      if (gen != _shelvesGeneration) return;
      debugPrint('Failed to load recommendations: $error');
      _recommendationTracks = null;
      _recommendationSeedTrackName = null;
    } finally {
      if (gen == _shelvesGeneration) {
        _isLoadingRecommendations = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshRecommendations() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecommendations(libraryId, forceRefresh: true);
    }
  }

  void clearLibrarySelection() {
    final previous = _session;
    _session = previous?.copyWith(selectedLibraryId: null, selectedLibraryName: null);
    _albums = null;
    _playlists = null;
    _recentTracks = null;
    _favoriteTracks = null;
    _recentlyPlayedTracks = null;
    _mostPlayedTracks = null;
    _mostPlayedAlbums = null;
    _longestTracks = null;
    _discoverTracks = null;
    _onThisDayTracks = null;
    _recommendationTracks = null;
    _recommendationSeedTrackName = null;
    notifyListeners();
    if (previous == null) return;

    final sessionProvider = _sessionProvider;
    if (sessionProvider != null) {
      // Through SessionProvider, so it, LibraryDataProvider and the stored
      // session agree (and a demo session isn't persisted).
      unawaited(sessionProvider.clearSelectedLibrary().catchError((Object e) {
        debugPrint('Failed to save the cleared library selection: $e');
      }));
    } else if (!previous.isDemo) {
      unawaited(_sessionStore.save(_session!).catchError((Object e) {
        debugPrint('Failed to save the cleared library selection: $e');
      }));
    }
  }

  void toggleOfflineMode() {
    _userWantsOffline = !_userWantsOffline;
    debugPrint('🔄 Toggled offline mode: $_userWantsOffline (Demo mode: $isDemoMode)');

    // Persist the user's offline preference
    unawaited(_playbackStateStore.saveUiState(isOfflineMode: _userWantsOffline));

    if (_userWantsOffline) {
      _activateSubmarineFeatures();
    } else {
      // Stays engaged while there's no network or Low Power Mode is on.
      _maybeDeactivateSubmarineFeatures();
    }
    // Applies the offline policy, or restores the online one (only when the
    // network is actually available).
    _publishOfflineState();

    notifyListeners();

    // In demo mode, offline toggle just switches between demo content and offline library view
    // No need to refresh or sync anything
    if (isDemoMode) {
      debugPrint('📱 Demo mode active - offline toggle is UI-only');
      return;
    }

    // If switching to online mode and we have a session and network, try to refresh data
    if (!_userWantsOffline && _session != null && _networkAvailable) {
      debugPrint('📶 Switching to online mode - refreshing libraries');
      refreshLibraries().then((_) {
        _syncPendingPlaylistActions();
      }).catchError((error) {
        debugPrint('Failed to refresh libraries when going online: $error');
        // Revert to offline if refresh fails
        _userWantsOffline = true;
        unawaited(_playbackStateStore.saveUiState(isOfflineMode: true));
        _publishOfflineState();
        _activateSubmarineFeatures();
        notifyListeners();
      });
    }
  }

  // Effective offline state last fanned out by [_publishOfflineState]
  // (null until the first call).
  bool? _publishedOffline;

  /// The single place that pushes the effective offline state
  /// ([isOfflineMode]: the user's toggle OR no network) to the services.
  /// Call after every change to [_userWantsOffline] / [_networkAvailable];
  /// idempotent.
  ///
  /// - Playback, every time: offline it plays only downloaded/cached tracks
  ///   and skips the rest instead of trying to stream.
  /// - On a change to offline: [_applyOfflineNetworkPolicy] (reports are
  ///   queued, analytics sync / image prewarm / bootstrap stopped).
  /// - On a change back to online: [_restoreOnlineNetworkPolicy] (flushes
  ///   queued reports, restarts syncs; [restartBootstrap] false when called
  ///   from inside a bootstrap sync) and retries queued downloads now
  ///   instead of after their backoff. The first call only records the
  ///   state: startup sets its own policy.
  void _publishOfflineState({bool restartBootstrap = true}) {
    final offline = isOfflineMode;
    _audioPlayerService.setOfflineMode(offline);
    _syncStatusProvider?.setOffline(offline);
    final previous = _publishedOffline;
    if (previous == offline) return;
    _publishedOffline = offline;
    if (offline) {
      _applyOfflineNetworkPolicy();
    } else if (previous != null) {
      _restoreOnlineNetworkPolicy(restartBootstrap: restartBootstrap);
      _downloadService.onSessionChanged();
    }
  }

  /// Shut down all background network activity for offline mode.
  void _applyOfflineNetworkPolicy() {
    debugPrint('📴 Applying offline network policy — silencing all background services');

    // Cancel periodic analytics sync
    _stopPeriodicSyncTimer();

    // Pause playback reporting
    _audioPlayerService.reportingService?.setEnabled(false);

    // Stop listening for remote commands
    _stopRemoteControl();

    // Disable image prewarming
    _audioPlayerService.setImagePrewarmEnabled(false);

    // Cancel bootstrap sync
    _bootstrapService.cancelSync();

    // Hold downloads (transfers, artwork, lyrics) until back online
    _downloadService.setSuspended(true);
  }

  /// Restore all background network activity when coming back online.
  void _restoreOnlineNetworkPolicy({bool restartBootstrap = true}) {
    debugPrint('📶 Restoring online network policy — re-enabling background services');

    // Resume downloads held by the offline policy
    _downloadService.setSuspended(false);

    final session = _session;
    if (session == null || _isDemoMode) return;

    // Restart periodic analytics sync + flush queued analytics
    _startPeriodicSyncTimer();
    unawaited(_syncAnalyticsToServer());

    // Send scrobbles queued while offline
    unawaited(ListenBrainzService().retryPendingScrobbles());
    unawaited(LastFmService.instance.flush());

    // Re-enable playback reporting + flush queued reports
    final reportingService = _audioPlayerService.reportingService;
    if (reportingService != null) {
      reportingService.setEnabled(true);
      unawaited(reportingService.flushPendingReports());
    }

    // Re-enable image prewarming
    _audioPlayerService.setImagePrewarmEnabled(true);

    // Accept remote commands again
    _startRemoteControl(session);

    // Resume bootstrap sync (also syncs pending playlist actions)
    if (restartBootstrap) _startBootstrapSync(session);
  }

  Future<void>? _playlistSyncInFlight;

  /// Queue a playlist edit / favorite made while offline.
  Future<void> _queueAction(PendingPlaylistAction action) async {
    await _syncQueue.add(action);
    unawaited(_refreshPendingActionsCount());
  }

  /// Publish the number of queued offline edits to the sync indicator.
  Future<void> _refreshPendingActionsCount() async {
    final status = _syncStatusProvider;
    if (status == null) return;
    try {
      status.setPendingActionsCount((await _syncQueue.load()).length);
    } catch (e) {
      debugPrint('Failed to read the pending playlist queue: $e');
    }
  }

  /// Replay playlist edits / favorites queued while offline. Runs whenever
  /// the app is (back) online — startup, reconnect, "Go online" — and is
  /// single-flight: overlapping triggers share one run, so no action is sent
  /// twice. [refreshAfter] reloads the playlists once done (only honoured
  /// when this call starts the run).
  Future<void> _syncPendingPlaylistActions({bool refreshAfter = true}) {
    final running = _playlistSyncInFlight;
    if (running != null) return running;
    late final Future<void> run;
    run = _runPendingPlaylistSync(refreshAfter: refreshAfter)
        .catchError((Object e) {
      debugPrint('❌ Pending playlist sync failed: $e');
    }).whenComplete(() {
      if (identical(_playlistSyncInFlight, run)) _playlistSyncInFlight = null;
    });
    _playlistSyncInFlight = run;
    return run;
  }

  /// HTTP status of a failed Jellyfin request, when the error carries one.
  static int? _requestStatus(Object error) {
    if (error is! JellyfinRequestException) return null;
    final match = RegExp(r'status (\d{3})').firstMatch(error.message);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Whether a failed request may still have been applied by the server:
  /// it timed out or broke after being sent, or the server answered 5xx.
  static bool _mayHaveBeenApplied(Object error) {
    if (error is ServerSlowException) return true;
    if (error is RobustHttpException) {
      final cause = error.lastError;
      return cause != null &&
          !RobustHttpClient.isConnectionEstablishmentFailure(cause);
    }
    final status = _requestStatus(error);
    return status != null && status >= 500;
  }

  Future<void> _runPendingPlaylistSync({bool refreshAfter = true}) async {
    if (isOfflineMode || isDemoMode || _session == null) return;
    // Every action is sent with this session; if the account changes
    // (logout / another login) the run stops, so one account's edits can
    // never reach another.
    final startSession = _jellyfinService.session;
    if (startSession == null) return;
    bool sessionChanged() => !identical(_jellyfinService.session, startSession);

    final pending = await _syncQueue.load();
    if (pending.isEmpty || sessionChanged()) return;

    debugPrint('Syncing ${pending.length} pending playlist actions...');
    _syncStatusProvider?.startSync('Syncing offline changes');
    String? failure;
    var aborted = false;

    // In order, stopping at the first transient failure: later actions may
    // depend on earlier ones (rename after create, favorite toggles), so
    // running them out of order could leave the wrong final state.
    for (final action in pending) {
      if (sessionChanged()) {
        aborted = true;
        break;
      }
      // `add` progress: ids of the action the server has accepted so far.
      int? addSent;
      try {
        switch (action.type) {
          case 'create':
            final name = action.payload['name'] as String;
            final itemIds = (action.payload['itemIds'] as List?)?.cast<String>();
            // An earlier attempt may have created it on the server even
            // though the response never arrived; don't create a duplicate.
            if (action.maybeApplied &&
                await _retriedCreateAlreadyApplied(action, name)) {
              break;
            }
            if (sessionChanged()) {
              aborted = true;
              break;
            }
            await _jellyfinService.createPlaylist(name: name, itemIds: itemIds);
            break;
          case 'update':
            final playlistId = action.payload['playlistId'] as String;
            final newName = action.payload['newName'] as String;
            await _jellyfinService.updatePlaylist(
              playlistId: playlistId,
              newName: newName,
            );
            break;
          case 'delete':
            final playlistId = action.payload['playlistId'] as String;
            await _jellyfinService.deletePlaylist(playlistId);
            break;
          case 'add':
            // Resume after the chunks an earlier attempt got accepted, and
            // skip the chunk that was in flight if the server applied it:
            // re-adding would duplicate songs in the playlist.
            final playlistId = action.payload['playlistId'] as String;
            final total = (action.payload['itemIds'] as List).length;
            var remaining = remainingAddIds(action.payload);
            if (action.maybeApplied && remaining.isNotEmpty) {
              var inPlaylist = const <String>{};
              try {
                inPlaylist = {
                  for (final t
                      in await _jellyfinService.getPlaylistItems(playlistId))
                    t.id,
                };
              } catch (_) {}
              final applied = appliedLeadingChunk(
                maybeApplied: true,
                remaining: remaining,
                playlistItemIds: inPlaylist,
              );
              remaining = remaining.sublist(applied);
            }
            final base = total - remaining.length;
            addSent = base;
            if (sessionChanged()) {
              aborted = true;
              break;
            }
            await _jellyfinService.addItemsToPlaylist(
              playlistId: playlistId,
              itemIds: remaining,
              onChunkSent: (sent) => addSent = base + sent,
            );
            break;
          case 'favorite':
            final itemId = action.payload['itemId'] as String;
            final shouldBeFavorite = action.payload['shouldBeFavorite'] as bool;
            await _jellyfinService.markFavorite(itemId, shouldBeFavorite);
            break;
        }
        if (aborted) break;
        await _syncQueue.remove(action);
        debugPrint('✅ Synced ${action.type} action');
      } catch (error) {
        if (sessionChanged()) {
          // Failed because the account changed mid-request: not the
          // action's fault, and it no longer belongs to this session.
          aborted = true;
          break;
        }
        final decision = decidePendingActionFailure(
          attempts: action.attempts,
          queuedAt: action.timestamp,
          now: DateTime.now(),
          httpStatus: _requestStatus(error),
          // A malformed stored payload (bad cast) can never succeed.
          invalidPayload: error is TypeError,
        );
        if (decision.drop) {
          debugPrint('❌ Dropping ${action.type} action after '
              '${decision.attempts} attempt(s): $error');
          await _syncQueue.remove(action);
          continue;
        }
        debugPrint('❌ Failed to sync ${action.type} action: $error');
        final sent = addSent;
        await _syncQueue.update(action.copyWith(
          attempts: decision.attempts,
          // For `add` it concerns only the chunk that was in flight now
          // (earlier chunks are recorded in the payload).
          maybeApplied: sent != null
              ? _mayHaveBeenApplied(error)
              : action.maybeApplied || _mayHaveBeenApplied(error),
          payload: sent != null
              ? {...action.payload, kAddActionSentCountKey: sent}
              : null,
        ));
        failure = error.toString();
        break; // keep the order; retry from here next time
      }
    }

    if (aborted) {
      debugPrint('Pending playlist sync stopped: the session changed');
      return;
    }

    await _refreshPendingActionsCount();
    if (failure != null) {
      _syncStatusProvider?.failSync(failure);
    } else {
      _syncStatusProvider?.completeSync();
    }

    // Refresh playlists after sync
    if (refreshAfter) await refreshPlaylists();
  }

  /// See [retriedCreateAlreadyApplied]. When the server's playlists can't
  /// be read, assumes not applied (a duplicate beats a lost playlist).
  Future<bool> _retriedCreateAlreadyApplied(
    PendingPlaylistAction action,
    String name,
  ) async {
    try {
      final playlists = await _jellyfinService.loadPlaylists(forceRefresh: true);
      return retriedCreateAlreadyApplied(
        maybeApplied: action.maybeApplied,
        name: name,
        queuedAt: action.timestamp,
        serverPlaylists: [
          for (final p in playlists) (name: p.name, created: p.dateCreated),
        ],
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnect() async {
    await logout();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _powerModeSub?.cancel();
    _periodicSyncTimer?.cancel();
    _reconnectDebounce?.cancel();
    _stopReachabilityProbe();
    _demoModeProvider?.removeListener(_onDemoModeChanged);
    _sessionProvider?.removeListener(_onSessionChanged);
    _libraryDataProvider?.removeListener(notifyListeners);
    _carPlayService?.dispose();
    _audioPlayerService.dispose();
    super.dispose();
  }

  AudioPlayerService get audioService => _audioPlayerService;

  String buildImageUrl({required String itemId, String? tag, int maxWidth = 400}) {
    return _jellyfinService.buildImageUrl(
      itemId: itemId,
      tag: tag,
      maxWidth: maxWidth,
    );
  }
}