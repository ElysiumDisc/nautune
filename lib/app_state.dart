import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

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
import 'providers/demo_mode_provider.dart';
import 'services/audio_player_service.dart';
import 'services/bootstrap_service.dart';
import 'services/listening_analytics_service.dart';
import 'services/carplay_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/local_cache_service.dart';
import 'services/playback_reporting_service.dart';
import 'services/playback_state_store.dart';
import 'services/playlist_sync_queue.dart';
import 'services/app_icon_service.dart';
import 'services/power_mode_service.dart';
import 'services/remote_control_service.dart';
import 'services/tray_service.dart';

// Import SessionProvider - this is new
import 'providers/session_provider.dart';

// Import repository layer for offline UI parity
import 'repositories/music_repository.dart';
import 'repositories/repository_factory.dart';

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
    SessionProvider? sessionProvider, // New parameter for SessionProvider
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore,
        _playbackStateStore = playbackStateStore,
        _cacheService = cacheService,
        _bootstrapService = bootstrapService,
        _connectivityService = connectivityService,
        _playlistStore = playlistStore ?? JellyfinPlaylistStore(),
        _syncQueue = syncQueue ?? PlaylistSyncQueue(),
        _demoModeProvider = demoModeProvider,
        _sessionProvider = sessionProvider, // Initialize the new field
        _downloadService = downloadService {
    _audioPlayerService = AudioPlayerService();
    // Link download service to audio player for offline playback
    _audioPlayerService.setDownloadService(_downloadService);
    _audioPlayerService.setJellyfinService(_jellyfinService);
    _audioPlayerService.setLocalCacheService(_cacheService);
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

    // System tray service for desktop platforms
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      scheduleMicrotask(() async {
        try {
          _trayService = TrayService(audioService: _audioPlayerService);
          await _trayService?.initialize();
          // Listen to track changes to update tray (store subscriptions for cleanup)
          _trayTrackSubscription = _audioPlayerService.currentTrackStream.listen((track) {
            _trayService?.updateCurrentTrack(track);
          });
          _trayPlayingSubscription = _audioPlayerService.playingStream.listen((isPlaying) {
            _trayService?.updatePlayingState(isPlaying);
          });
          debugPrint('✅ System tray service initialized');
        } catch (error) {
          debugPrint('System tray service initialization failed: $error');
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
  final SessionProvider? _sessionProvider; // New field for SessionProvider
  late final AudioPlayerService _audioPlayerService;
  late final DownloadService _downloadService;
  CarPlayService? _carPlayService;
  TrayService? _trayService;
  RemoteControlService? _remoteControlService;
  StreamSubscription<bool>? _connectivitySubscription;
  StreamSubscription<JellyfinTrack?>? _trayTrackSubscription;
  StreamSubscription<bool>? _trayPlayingSubscription;
  Timer? _periodicSyncTimer; // Syncs analytics every 10 minutes
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
  bool _visualizerEnabled = true; // Bioluminescent visualizer toggle
  bool _visualizerEnabledByUser = true; // User's explicit preference (for Low Power Mode restore)
  bool _visualizerSuppressedByLowPower = false; // Temporarily disabled by iOS Low Power Mode
  VisualizerType _visualizerType = VisualizerType.bioluminescent; // Current visualizer style
  VisualizerPosition _visualizerPosition = VisualizerPosition.controlsBar; // Where visualizer is displayed
  NowPlayingLayout _nowPlayingLayout = NowPlayingLayout.classic; // Now Playing screen layout
  StreamSubscription? _powerModeSub;
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
  final bool _isAuthenticating = false;
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
          final reportingService = PlaybackReportingService(
            serverUrl: _session!.serverUrl,
            accessToken: _session!.credentials.accessToken,
          );
          _audioPlayerService.setReportingService(reportingService);
        }
        _albums = provider.albums;
        _artists = provider.artists;
        _genres = provider.genres;
        _playlists = provider.playlists;
        _recentTracks = provider.recentTracks;
        _favoriteTracks = provider.favoriteTracks;
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
    debugPrint('[NautuneAppState] _onSessionChanged called. Provider session: ${newSession?.selectedLibraryId}');

    if (_session != newSession) {
      debugPrint('[NautuneAppState] Updating local session. New Lib ID: ${newSession?.selectedLibraryId}');
      _session = newSession;
      notifyListeners();

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
            final session = _session!;
            final reportingService = PlaybackReportingService(
              serverUrl: session.serverUrl,
              accessToken: session.credentials.accessToken,
            );
            _audioPlayerService.setReportingService(reportingService);
          }

          _albums = provider.albums;
          _artists = provider.artists;
          _genres = provider.genres;
          _playlists = provider.playlists;
          _recentTracks = provider.recentTracks;
          _favoriteTracks = provider.favoriteTracks;

          notifyListeners();
          return;
        }
      }

      // Normal (non-demo) session handling
      if (_session != null && !(_session?.isDemo ?? false)) {
        final session = _session!;
        // Ensure AudioPlayerService has the correct JellyfinService instance
        _audioPlayerService.setJellyfinService(_jellyfinService);

        // Initialize playback reporting if not already done
        final reportingService = PlaybackReportingService(
          serverUrl: session.serverUrl,
          accessToken: session.credentials.accessToken,
        );
        _audioPlayerService.setReportingService(reportingService);

        // Start periodic analytics sync for the new session
        _startPeriodicSyncTimer();

        // Start remote control WebSocket for Helm Mode
        _startRemoteControl(session);

        _loadLibraries();
        if (session.selectedLibraryId != null) {
          _loadLibraryDependentContent(forceRefresh: true);
        }
      } else if (_session == null) {
        // Session cleared - stop periodic sync
        _stopPeriodicSyncTimer();
        _clearLibraryCaches();
        // Disconnect remote control
        _remoteControlService?.dispose();
        _remoteControlService = null;
      }
    }
  }

  // --- End of _onSessionChanged ---

  bool get isAuthenticating => _isAuthenticating;
  JellyfinSession? get session => _session;
  Object? get lastError => _lastError;
  bool get isLoadingLibraries => _isLoadingLibraries;
  Object? get librariesError => _librariesError;
  List<JellyfinLibrary>? get libraries => _libraries;
  bool get isLoadingAlbums => _isLoadingAlbums;
  Object? get albumsError => _albumsError;
  List<JellyfinAlbum>? get albums => _albums;
  bool get isLoadingMoreAlbums => _isLoadingMoreAlbums;
  bool get hasMoreAlbums => _hasMoreAlbums;
  bool get isLoadingArtists => _isLoadingArtists;
  Object? get artistsError => _artistsError;
  List<JellyfinArtist>? get artists => _artists;
  bool get isLoadingMoreArtists => _isLoadingMoreArtists;
  bool get hasMoreArtists => _hasMoreArtists;
  bool get isLoadingPlaylists => _isLoadingPlaylists;
  Object? get playlistsError => _playlistsError;
  List<JellyfinPlaylist>? get playlists => _playlists;
  bool get isLoadingRecent => _isLoadingRecent;
  Object? get recentError => _recentError;
  List<JellyfinTrack>? get recentTracks => _recentTracks;
  bool get isLoadingRecentlyAdded => _isLoadingRecentlyAdded;
  Object? get recentlyAddedError => _recentlyAddedError;
  List<JellyfinAlbum>? get recentlyAddedAlbums => _recentlyAddedAlbums;
  bool get isLoadingFavorites => _isLoadingFavorites;
  Object? get favoritesError => _favoritesError;
  List<JellyfinTrack>? get favoriteTracks => _favoriteTracks;
  bool get isLoadingGenres => _isLoadingGenres;
  Object? get genresError => _genresError;
  List<JellyfinGenre>? get genres => _genres;
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
  /// Offline mode is active if user explicitly chose it OR network is unavailable
  bool get isOfflineMode => _userWantsOffline || !_networkAvailable;

  /// Whether user explicitly wants offline mode (persisted setting)
  bool get userWantsOffline => _userWantsOffline;

  /// Get the appropriate repository based on offline mode.
  /// Returns OfflineRepository when offline, OnlineRepository when online.
  MusicRepository get repository => RepositoryFactory.create(
        isOfflineMode: _userWantsOffline,
        jellyfinService: _jellyfinService,
        downloadService: _downloadService,
      );

  bool get showVolumeBar => _showVolumeBar;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeDurationSeconds => _crossfadeDurationSeconds;
  bool get infiniteRadioEnabled => _infiniteRadioEnabled;
  bool get gaplessPlaybackEnabled => _gaplessPlaybackEnabled;
  int get cacheTtlMinutes => _cacheTtlMinutes;
  StreamingQuality get streamingQuality => _streamingQuality;
  bool get visualizerEnabled => _visualizerEnabled;
  VisualizerType get visualizerType => _visualizerType;
  VisualizerPosition get visualizerPosition => _visualizerPosition;
  NowPlayingLayout get nowPlayingLayout => _nowPlayingLayout;
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
    final libs = _libraries;
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
  TrayService? get trayService => _trayService;
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
    _audioPlayerService.setCrossfadeEnabled(enabled);
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
    _audioPlayerService.setGaplessPlaybackEnabled(enabled);
    unawaited(_playbackStateStore.saveUiState(
      gaplessPlaybackEnabled: enabled,
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
    // Track user's explicit preference for Low Power Mode restore
    _visualizerEnabledByUser = enabled;

    // Only update actual state if not in Low Power Mode
    if (!PowerModeService.instance.isLowPowerMode) {
      if (_visualizerEnabled == enabled) return;
      _visualizerEnabled = enabled;
      notifyListeners();
    }

    unawaited(_playbackStateStore.saveUiState(
      visualizerEnabled: enabled,
    ));
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
    _audioPlayerService.setPreCacheTrackCount(count);
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

  /// Initialize Low Power Mode listener (iOS only)
  void _initPowerModeListener() {
    // Check INITIAL state - if already in low power mode, disable visualizer
    if (PowerModeService.instance.isLowPowerMode && _visualizerEnabled) {
      _visualizerSuppressedByLowPower = true;
      _visualizerEnabled = false;
      notifyListeners();
      debugPrint('🔋 Visualizer disabled (Low Power Mode - initial state)');
    }

    // Listen for CHANGES
    _powerModeSub = PowerModeService.instance.lowPowerModeStream.listen((isLowPower) {
      if (isLowPower) {
        // Entering Low Power Mode - save current state and disable visualizer
        if (_visualizerEnabled) {
          _visualizerSuppressedByLowPower = true;
          _visualizerEnabled = false;
          notifyListeners();
          debugPrint('🔋 Visualizer disabled (Low Power Mode)');
        }
      } else {
        // Exiting Low Power Mode - restore if it was suppressed and user had it ON
        if (_visualizerSuppressedByLowPower && _visualizerEnabledByUser) {
          _visualizerEnabled = true;
          _visualizerSuppressedByLowPower = false;
          notifyListeners();
          debugPrint('🔋 Visualizer restored (Low Power Mode off)');
        } else {
          _visualizerSuppressedByLowPower = false;
        }
      }
    });
  }

  /// Set album sort options and reload
  Future<void> setAlbumSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_albumSortBy == sortBy && _albumSortOrder == sortOrder) return;
    _albumSortBy = sortBy;
    _albumSortOrder = sortOrder;
    await _loadAlbumsForSelectedLibrary(forceRefresh: true);
  }

  /// Set artist sort options and reload
  Future<void> setArtistSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_artistSortBy == sortBy && _artistSortOrder == sortOrder) return;
    _artistSortBy = sortBy;
    _artistSortOrder = sortOrder;
    await _loadArtistsForSelectedLibrary(forceRefresh: true);
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

  void _handleConnectivityStatusChange(bool isOnline) {
    final wasOnline = _networkAvailable;
    _networkAvailable = isOnline;

    // When network is lost, isOfflineMode getter automatically returns true
    // We don't change _userWantsOffline - that's the user's explicit choice
    if (!isOnline && wasOnline) {
      debugPrint('📴 Network lost - app is now effectively offline');
      notifyListeners();
      return;
    }
    
    // Going online - apply immediately but don't auto-switch offline mode
    // Let the user manually switch back or let bootstrap sync handle it
    if (isOnline && !wasOnline) {
      debugPrint('📶 Network restored - starting background sync');
      notifyListeners();
      
      final session = _session;
      if (session != null && !_isDemoMode) {
        // Start background sync without forcing offline mode change
        _startBootstrapSync(session);
        // Refresh data in background - don't await, don't block UI
        unawaited(_refreshAfterReconnect());
      }
    } else if (wasOnline != isOnline) {
      notifyListeners();
    }
  }
  
  Future<void> _refreshAfterReconnect() async {
    // Small delay to let connection stabilize
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if still online before refreshing
    if (!_networkAvailable) return;

    try {
      await refreshLibraries();
      debugPrint('✅ Background refresh after reconnect complete');
      // Note: We don't auto-change _userWantsOffline here
      // If user explicitly chose offline mode, they stay offline until they toggle it
      // If they were offline due to no network, isOfflineMode getter now returns false
      notifyListeners();

      // Sync analytics in background (don't await - fire and forget)
      unawaited(_syncAnalyticsToServer());
    } catch (error) {
      debugPrint('⚠️ Refresh after reconnect failed: $error');
    }
  }

  /// Start periodic analytics sync timer (every 10 minutes)
  /// This ensures local plays are regularly pushed to server
  void _startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (_session != null && _networkAvailable && !_isDemoMode) {
        debugPrint('📊 Periodic sync triggered (every 10 min)');
        unawaited(_syncAnalyticsToServer());
      }
    });
    debugPrint('📊 Started periodic analytics sync timer (10 min interval)');
  }

  /// Stop the periodic sync timer
  void _stopPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
    debugPrint('📊 Stopped periodic analytics sync timer');
  }

  /// Sync local listening analytics to the Jellyfin server
  /// This pushes unsynced plays that were recorded offline
  Future<void> _syncAnalyticsToServer() async {
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

  Future<void> initialize() async {
    debugPrint('Nautune initialization started');
    await _ensureConnectivityMonitoring();

    // Initialize iOS Low Power Mode detection (listener attached after state restoration below)
    await PowerModeService.instance.initialize();

    // Initialize app icon service (for alternate icon support)
    await AppIconService().initialize();
    // Sync iOS icon to match stored preference
    await AppIconService().syncIOSIcon();
    // Update tray icon to match saved preference (tray may have initialized with default)
    _trayService?.updateTrayIcon();

    final storedPlaybackState = await _playbackStateStore.load();
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
      _visualizerEnabled = storedPlaybackState.visualizerEnabled;
      _visualizerEnabledByUser = storedPlaybackState.visualizerEnabled;
      _visualizerType = storedPlaybackState.visualizerType;
      _visualizerPosition = storedPlaybackState.visualizerPosition;
      _nowPlayingLayout = storedPlaybackState.nowPlayingLayout;
      _libraryScrollOffsets =
          Map<String, double>.from(storedPlaybackState.scrollOffsets);
      await _audioPlayerService.hydrateFromPersistence(storedPlaybackState);
      _audioPlayerService.setCrossfadeEnabled(_crossfadeEnabled);
      _audioPlayerService.setCrossfadeDuration(_crossfadeDurationSeconds);
      _audioPlayerService.setInfiniteRadioEnabled(_infiniteRadioEnabled);
      _audioPlayerService.setGaplessPlaybackEnabled(_gaplessPlaybackEnabled);
      _audioPlayerService.setStreamingQuality(_streamingQuality);
      _audioPlayerService.setPreCacheTrackCount(storedPlaybackState.preCacheTrackCount);
      _audioPlayerService.setWifiOnlyCaching(storedPlaybackState.wifiOnlyCaching);
      _audioPlayerService.setConnectivityService(_connectivityService);
      _jellyfinService.setCacheTtl(Duration(minutes: _cacheTtlMinutes));

      // Initialize Low Power Mode listener AFTER visualizer state is restored
      // (so the initial check has the correct _visualizerEnabled value)
      _initPowerModeListener();
      
      // Restore download settings
      _downloadService.loadSettings(
        maxConcurrentDownloads: storedPlaybackState.maxConcurrentDownloads,
        wifiOnlyDownloads: storedPlaybackState.wifiOnlyDownloads,
        storageLimitMB: storedPlaybackState.storageLimitMB,
        autoCleanupEnabled: storedPlaybackState.autoCleanupEnabled,
        autoCleanupDays: storedPlaybackState.autoCleanupDays,
      );

      // Restore offline mode preference
      _userWantsOffline = storedPlaybackState.isOfflineMode;
    } else {
      // No stored state - still need power mode listener for new installs
      _initPowerModeListener();
    }

    try {
      final storedSession = await _sessionStore.load();
      if (storedSession != null) {
        if (storedSession.isDemo) {
          if (_demoModeProvider != null) {
            await _demoModeProvider.startDemoMode();
          } else {
            // Fallback for legacy demo
            final data = await rootBundle.load('assets/demo/demo_offline_track.mp3');
            await _setupDemoMode(DemoContent(), data.buffer.asUint8List());
          }
          _initialized = true;
          notifyListeners();
          return;
        }

        _session = storedSession;
        _jellyfinService.restoreSession(storedSession);
        _audioPlayerService.setJellyfinService(_jellyfinService);

        final reportingService = PlaybackReportingService(
          serverUrl: storedSession.serverUrl,
          accessToken: storedSession.credentials.accessToken,
        );
        _audioPlayerService.setReportingService(reportingService);

        final snapshot = await _bootstrapService.loadCachedSnapshot(
          session: storedSession,
        );
        await _applyBootstrapSnapshot(snapshot);
        // Start periodic analytics sync timer (runs every 10 min)
        _startPeriodicSyncTimer();

        if (_networkAvailable) {
          _startBootstrapSync(storedSession);
          // Sync analytics in background on startup
          unawaited(_syncAnalyticsToServer());
          // Start remote control WebSocket for Helm Mode
          _startRemoteControl(storedSession);
        } else {
          debugPrint('Skipping bootstrap sync: offline at startup');
        }
      }
    } catch (error, stackTrace) {
      _lastError = error;
      debugPrint('Nautune initialization failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'app_state',
          context: ErrorDescription('restoring Nautune session'),
        ),
      );
    } finally {
      _initialized = true;
      notifyListeners();
      debugPrint('Nautune initialization finished (session restored: ${_session != null}, offline: $_userWantsOffline)');
      
      // CarPlay is now initialized early in constructor, no need to init here
      // Just refresh content if connected
      if (Platform.isIOS && _carPlayService != null) {
        debugPrint('🚗 CarPlay: Refreshing content after app init');
      }
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
    );
    unawaited(_syncPendingPlaylistActions());
  }

  Future<void> _applyBootstrapSnapshot(BootstrapSnapshot snapshot) async {
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

  void _handleNetworkRecovered() {
    if (!_networkAvailable) {
      _networkAvailable = true;
      notifyListeners();
    }
  }

  void _handleNetworkDrop(Object error) {
    if (_networkAvailable) {
      _networkAvailable = false;
      // Note: isOfflineMode getter automatically returns true when !_networkAvailable
      debugPrint('Network lost while syncing: $error');

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
    _jellyfinService.clearSession();
    _session = null;
    _libraries = null;
    _librariesError = null;
    _isLoadingLibraries = false;
    _albums = null;
    _albumsError = null;
    _isLoadingAlbums = false;
    _playlists = null;
    _playlistsError = null;
    _isLoadingPlaylists = false;
    _recentTracks = null;
    _recentError = null;
    _isLoadingRecent = false;
    _recentlyAddedAlbums = null;
    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = false;
    _favoriteTracks = null;
    _favoritesError = null;
    _isLoadingFavorites = false;
    if (cacheKey != null) {
      await _cacheService.clearForSession(cacheKey);
    }
    await _sessionStore.clear();
    // Also clear the SessionProvider so UI reacts and shows the login screen
    if (_sessionProvider != null) {
      try {
        await _sessionProvider.logout();
      } catch (error) {
        debugPrint('SessionProvider.logout failed: $error');
      }
    }
    // Disconnect remote control WebSocket
    _remoteControlService?.dispose();
    _remoteControlService = null;

    await _teardownDemoMode();
    notifyListeners();
  }

  /// Start the persistent WebSocket for receiving remote control commands
  /// (Helm Mode). Only connects for real, non-demo, online sessions.
  void _startRemoteControl(JellyfinSession session) {
    if (session.isDemo) return;

    final client = _jellyfinService.jellyfinClient;
    if (client == null) return;

    _remoteControlService?.dispose();
    _remoteControlService = RemoteControlService(
      client: client,
      credentials: session.credentials,
      deviceId: session.deviceId,
      jellyfinService: _jellyfinService,
      audioPlayerService: _audioPlayerService,
    );
    _remoteControlService!.connect();
  }

  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  Future<void> refreshLibraries() async {
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
      await _syncQueue.add(PendingPlaylistAction(
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
      await _syncQueue.add(PendingPlaylistAction(
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
      await _syncQueue.add(PendingPlaylistAction(
        type: 'delete',
        payload: {
          'playlistId': playlistId,
        },
        timestamp: DateTime.now(),
      ));
      throw Exception('Offline: Playlist deletion queued for sync');
    }
    
    await _jellyfinService.deletePlaylist(playlistId);
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
      await _syncQueue.add(PendingPlaylistAction(
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
    return await _jellyfinService.getPlaylistItems(playlistId);
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
      await _syncQueue.add(PendingPlaylistAction(
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
    await _loadAlbumsForSelectedLibrary(forceRefresh: true);
  }

  Future<void> refreshArtists() async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId != null) {
      await _loadArtistsForLibrary(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshLibraryData() async {
    final libraryId = _session?.selectedLibraryId;
    if (libraryId != null) {
      await _loadLibraryDependentContent(forceRefresh: true);
    }
  }

  Future<void> refreshPlaylists() async {
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

    // Load all data in parallel with individual timeouts
    // eagerError: false ensures one slow/failed request doesn't cancel others
    await Future.wait([
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
      _loadFavorites(forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Favorites load timed out')),
      _loadGenres(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Genres load timed out')),
      _loadRecentlyPlayed(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ RecentlyPlayed load timed out')),
      _loadDiscoverTracks(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Discover load timed out')),
      _loadOnThisDayTracks(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ OnThisDay load timed out')),
      _loadRecommendations(libraryId, forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 30), onTimeout: () => debugPrint('⚠️ Recommendations load timed out')),
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

  Future<void> loadMoreAlbums() async {
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
      // Load ALL playlists (playlists are global, not library-specific)
      _playlists = await _jellyfinService.loadPlaylists(
        libraryId: null,
        forceRefresh: forceRefresh,
      );
      await _playlistStore.save(_playlists!);
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.savePlaylists(cacheKey, _playlists!);
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

  Future<void> _loadRecentForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _recentError = null;
    _isLoadingRecent = true;
    notifyListeners();

    if (_isDemoMode) {
      _recentTracks = _demoTracksFromIds(_demoRecentTrackIds);
      _isLoadingRecent = false;
      notifyListeners();
      return;
    }

    try {
      _recentTracks = await _jellyfinService.loadRecentTracks(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final tracks = _recentTracks ?? const <JellyfinTrack>[];
        await _cacheService.saveRecentTracks(
          cacheKey,
          libraryId: libraryId,
          data: tracks,
        );
      }
    } catch (error) {
      _recentError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached =
            await _cacheService.readRecentTracks(cacheKey, libraryId: libraryId);
        if (cached != null && cached.isNotEmpty) {
          _recentTracks = cached;
        } else {
          _recentTracks = null;
        }
      } else {
        _recentTracks = null;
      }
    } finally {
      _isLoadingRecent = false;
      notifyListeners();
    }
  }

  Future<void> _loadRecentlyAddedForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = true;
    notifyListeners();

    if (_isDemoMode) {
      _recentlyAddedAlbums = _demoContent?.albums ?? const <JellyfinAlbum>[];
      _isLoadingRecentlyAdded = false;
      notifyListeners();
      return;
    }

    try {
      final albums = await _jellyfinService.loadRecentlyAddedAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        limit: 20,
      );
      _recentlyAddedAlbums = albums;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveRecentlyAddedAlbums(
          cacheKey,
          libraryId: libraryId,
          data: albums,
        );
      }
    } catch (error) {
      _recentlyAddedError = error;
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readRecentlyAddedAlbums(
          cacheKey,
          libraryId: libraryId,
        );
        if (cached != null && cached.isNotEmpty) {
          _recentlyAddedAlbums = cached;
        } else {
          _recentlyAddedAlbums = null;
        }
      } else {
        _recentlyAddedAlbums = null;
      }
    } finally {
      _isLoadingRecentlyAdded = false;
      notifyListeners();
    }
  }

  Future<void> refreshRecent() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecentForLibrary(libraryId, forceRefresh: true);
    }
  }

  Future<void> refreshRecentlyAdded() async {
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
    await _loadFavorites(forceRefresh: true);
  }

  Future<void> refreshGenres() async {
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
      _genres = _demoContent?.genres ?? const <JellyfinGenre>[];
      _isLoadingGenres = false;
      notifyListeners();
      return;
    }

    try {
      _genres = await _jellyfinService.loadGenres(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      _genresError = error;
      _genres = null;
    } finally {
      _isLoadingGenres = false;
      notifyListeners();
    }
  }

  Future<void> _loadRecentlyPlayed(String libraryId, {bool forceRefresh = false}) async {
    _isLoadingRecentlyPlayed = true;
    notifyListeners();

    if (_isDemoMode) {
      _recentlyPlayedTracks = _demoTracksFromIds(_demoRecentTrackIds.take(10).toList());
      _isLoadingRecentlyPlayed = false;
      notifyListeners();
      return;
    }

    try {
      _recentlyPlayedTracks = await _jellyfinService.getRecentlyPlayedTracks(
        libraryId: libraryId,
        limit: 20,
      );
    } catch (error) {
      _recentlyPlayedTracks = null;
    } finally {
      _isLoadingRecentlyPlayed = false;
      notifyListeners();
    }
  }

  Future<void> _loadMostPlayedTracks(String libraryId, {bool forceRefresh = false}) async {
    _isLoadingMostPlayedTracks = true;
    notifyListeners();

    if (_isDemoMode) {
      _mostPlayedTracks = _demoTracksFromIds(_demoRecentTrackIds.take(10).toList());
      _isLoadingMostPlayedTracks = false;
      notifyListeners();
      return;
    }

    try {
      _mostPlayedTracks = await _jellyfinService.getMostPlayedTracks(
        libraryId: libraryId,
        limit: 20,
      );
    } catch (error) {
      _mostPlayedTracks = null;
    } finally {
      _isLoadingMostPlayedTracks = false;
      notifyListeners();
    }
  }

  Future<void> _loadMostPlayedAlbums(String libraryId, {bool forceRefresh = false}) async {
    _isLoadingMostPlayedAlbums = true;
    notifyListeners();

    if (_isDemoMode) {
      final demoAlbums = _demoContent?.albums ?? [];
      _mostPlayedAlbums = demoAlbums.take(10).toList();
      _isLoadingMostPlayedAlbums = false;
      notifyListeners();
      return;
    }

    try {
      _mostPlayedAlbums = await _jellyfinService.getMostPlayedAlbums(
        libraryId: libraryId,
        limit: 20,
      );
    } catch (error) {
      _mostPlayedAlbums = null;
    } finally {
      _isLoadingMostPlayedAlbums = false;
      notifyListeners();
    }
  }

  Future<void> _loadLongestTracks(String libraryId, {bool forceRefresh = false}) async {
    _isLoadingLongestTracks = true;
    notifyListeners();

    if (_isDemoMode) {
      _longestTracks = _demoTracksFromIds(_demoRecentTrackIds.take(10).toList());
      _isLoadingLongestTracks = false;
      notifyListeners();
      return;
    }

    try {
      _longestTracks = await _jellyfinService.getLongestRuntimeTracks(
        libraryId: libraryId,
        limit: 20,
      );
    } catch (error) {
      _longestTracks = null;
    } finally {
      _isLoadingLongestTracks = false;
      notifyListeners();
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
    _isLoadingDiscover = true;
    notifyListeners();

    if (_isDemoMode) {
      // In demo mode, shuffle some tracks as "discover"
      _discoverTracks = _demoTracksFromIds(_demoRecentTrackIds.reversed.take(10).toList());
      _isLoadingDiscover = false;
      notifyListeners();
      return;
    }

    try {
      // Get tracks with less than 3 plays (rarely played = discover)
      _discoverTracks = await _jellyfinService.getLeastPlayedTracks(
        libraryId: libraryId,
        maxPlayCount: 3,
        limit: 20,
      );
    } catch (error) {
      debugPrint('Failed to load discover tracks: $error');
      _discoverTracks = null;
    } finally {
      _isLoadingDiscover = false;
      notifyListeners();
    }
  }

  Future<void> _loadOnThisDayTracks(String libraryId, {bool forceRefresh = false}) async {
    _isLoadingOnThisDay = true;
    notifyListeners();

    if (_isDemoMode) {
      _onThisDayTracks = _demoTracksFromIds(_demoRecentTrackIds.take(5).toList());
      _isLoadingOnThisDay = false;
      notifyListeners();
      return;
    }

    try {
      // Get tracks from local analytics that were played on this day in previous years
      final analyticsService = ListeningAnalyticsService();
      final onThisDayEvents = analyticsService.getOnThisDayEvents();

      if (onThisDayEvents.isEmpty) {
        _onThisDayTracks = [];
      } else {
        // Get unique track IDs from the events
        final trackIds = onThisDayEvents.map((e) => e.trackId).toSet().take(20).toList();

        // Batch fetch all tracks at once for better performance
        final tracks = await _jellyfinService.loadTracksByIds(trackIds);
        _onThisDayTracks = tracks;
      }
    } catch (error) {
      debugPrint('Failed to load on this day tracks: $error');
      _onThisDayTracks = null;
    } finally {
      _isLoadingOnThisDay = false;
      notifyListeners();
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
    _isLoadingRecommendations = true;
    notifyListeners();

    if (_isDemoMode) {
      _recommendationTracks = _demoTracksFromIds(_demoRecentTrackIds.take(10).toList());
      _recommendationSeedTrackName = 'Demo Track';
      _isLoadingRecommendations = false;
      notifyListeners();
      return;
    }

    try {
      // Get a seed track from recently played or most played
      JellyfinTrack? seedTrack;

      // Try recently played first
      if (_recentlyPlayedTracks != null && _recentlyPlayedTracks!.isNotEmpty) {
        seedTrack = _recentlyPlayedTracks!.first;
      } else if (_recentTracks != null && _recentTracks!.isNotEmpty) {
        seedTrack = _recentTracks!.first;
      }

      if (seedTrack == null) {
        // No seed track available, try to get most played
        final mostPlayed = await _jellyfinService.getMostPlayedTracks(
          libraryId: libraryId,
          limit: 1,
        );
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

      // Filter out the seed track itself
      _recommendationTracks = recommendations.where((t) => t.id != seedTrack!.id).take(20).toList();
      _recommendationSeedTrackName = seedTrack.name;
    } catch (error) {
      debugPrint('Failed to load recommendations: $error');
      _recommendationTracks = null;
      _recommendationSeedTrackName = null;
    } finally {
      _isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  Future<void> refreshRecommendations() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecommendations(libraryId, forceRefresh: true);
    }
  }

  void clearLibrarySelection() {
    _session = _session?.copyWith(selectedLibraryId: null, selectedLibraryName: null);
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
    if (_session != null) {
      _sessionStore.save(_session!);
    }
  }

  void toggleOfflineMode() {
    _userWantsOffline = !_userWantsOffline;
    debugPrint('🔄 Toggled offline mode: $_userWantsOffline (Demo mode: $isDemoMode)');

    // Persist the user's offline preference
    unawaited(_playbackStateStore.saveUiState(isOfflineMode: _userWantsOffline));

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
      refreshLibraries().catchError((error) {
        debugPrint('Failed to refresh libraries when going online: $error');
        // Revert to offline if refresh fails
        _userWantsOffline = true;
        unawaited(_playbackStateStore.saveUiState(isOfflineMode: true));
        notifyListeners();
      });

      // Sync pending playlist actions
      _syncPendingPlaylistActions();
    }
  }

  Future<void> _syncPendingPlaylistActions() async {
    final pending = await _syncQueue.load();
    if (pending.isEmpty) return;

    debugPrint('Syncing ${pending.length} pending playlist actions...');
    
    for (final action in pending) {
      try {
        switch (action.type) {
          case 'create':
            final name = action.payload['name'] as String;
            final itemIds = (action.payload['itemIds'] as List?)?.cast<String>();
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
            final playlistId = action.payload['playlistId'] as String;
            final itemIds = (action.payload['itemIds'] as List).cast<String>();
            await _jellyfinService.addItemsToPlaylist(
              playlistId: playlistId,
              itemIds: itemIds,
            );
            break;
          case 'favorite':
            final itemId = action.payload['itemId'] as String;
            final shouldBeFavorite = action.payload['shouldBeFavorite'] as bool;
            await _jellyfinService.markFavorite(itemId, shouldBeFavorite);
            break;
        }
        await _syncQueue.remove(action);
        debugPrint('✅ Synced ${action.type} action');
      } catch (error) {
        debugPrint('❌ Failed to sync ${action.type} action: $error');
        // Keep the action for next sync attempt
      }
    }
    
    // Refresh playlists after sync
    await refreshPlaylists();
  }

  Future<void> disconnect() async {
    await logout();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _trayTrackSubscription?.cancel();
    _trayPlayingSubscription?.cancel();
    _powerModeSub?.cancel();
    _periodicSyncTimer?.cancel();
    _demoModeProvider?.removeListener(_onDemoModeChanged);
    _sessionProvider?.removeListener(_onSessionChanged);
    _carPlayService?.dispose();
    _remoteControlService?.dispose();
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