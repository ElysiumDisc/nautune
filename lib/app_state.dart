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
import 'services/carplay_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/local_cache_service.dart';
import 'services/playback_reporting_service.dart';
import 'services/playback_state_store.dart';
import 'services/playlist_sync_queue.dart';

// Import SessionProvider - this is new
import 'providers/session_provider.dart';

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
    // CarPlay service is only available on iOS; defer creation until Flutter boots
    if (Platform.isIOS) {
      scheduleMicrotask(() {
        try {
          _carPlayService = CarPlayService(appState: this);
        } catch (error) {
          debugPrint('CarPlay service construction failed: $error');
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
  StreamSubscription<bool>? _connectivitySubscription;
  bool _connectivityMonitorInitialized = false;
  Map<String, double> _libraryScrollOffsets = {};
  int _restoredLibraryTabIndex = 0;
  bool _showVolumeBar = true;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
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
  bool _isAuthenticating = false;
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
  bool _isOfflineMode = false;  // Toggle between online and offline library
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

    final newSession = _sessionProvider!.session;
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
              selectedLibraryId: provider.library!.id,
              selectedLibraryName: provider.library!.name,
              isDemo: true,
            );

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

          notifyListeners();
          return;
        }
      }

      // Normal (non-demo) session handling
      if (_session != null && !(_session?.isDemo ?? false)) {
        // Ensure AudioPlayerService has the correct JellyfinService instance
        _audioPlayerService.setJellyfinService(_jellyfinService);

        // Initialize playback reporting if not already done
        final reportingService = PlaybackReportingService(
          serverUrl: _session!.serverUrl,
          accessToken: _session!.credentials.accessToken,
        );
        _audioPlayerService.setReportingService(reportingService);

        _loadLibraries();
        if (_session!.selectedLibraryId != null) {
          _loadLibraryDependentContent(forceRefresh: true);
        }
      } else if (_session == null) {
        // Session cleared
        _clearLibraryCaches();
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
  bool get isOfflineMode => _isOfflineMode;
  bool get showVolumeBar => _showVolumeBar;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeDurationSeconds => _crossfadeDurationSeconds;
  int get initialLibraryTabIndex => _restoredLibraryTabIndex;
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
  List<JellyfinAlbum> get demoAlbums =>
      _demoContent?.albums ?? const <JellyfinAlbum>[];
  List<JellyfinArtist> get demoArtists =>
      _demoContent?.artists ?? const <JellyfinArtist>[];
  List<JellyfinTrack> get demoTracks {
    if (_demoModeProvider != null) {
      return _demoModeProvider!.allTracks;
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
      await _demoModeProvider!.stopDemoMode();
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
    _isOfflineMode = false;

    _session = JellyfinSession(
      serverUrl: 'demo://nautune',
      username: 'tester',
      credentials: const JellyfinCredentials(
        accessToken: 'demo-token',
        userId: 'demo-user',
      ),
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

  void updateLibraryTabIndex(int index) {
    if (_restoredLibraryTabIndex == index) return;
    _restoredLibraryTabIndex = index;
    unawaited(_playbackStateStore.saveUiState(libraryTabIndex: index));
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
      if (!isOnline && !_isOfflineMode && !_isDemoMode) {
        _isOfflineMode = true;
      }
    } catch (error) {
      debugPrint('Connectivity probe failed: $error');
      _networkAvailable = false;
      if (!_isOfflineMode && !_isDemoMode) {
        _isOfflineMode = true;
      }
    }

    _connectivitySubscription =
        _connectivityService.onStatusChange.listen(_handleConnectivityStatusChange);
    _connectivityMonitorInitialized = true;
  }

  void _handleConnectivityStatusChange(bool isOnline) {
    final wasOnline = _networkAvailable;
    _networkAvailable = isOnline;
    if (!isOnline && !_isOfflineMode && !_isDemoMode) {
      _isOfflineMode = true;
    }
    if (wasOnline != isOnline) {
      notifyListeners();
    }

    if (isOnline && !wasOnline) {
      final session = _session;
      if (session != null && !_isDemoMode) {
        _startBootstrapSync(session);
        unawaited(() async {
          try {
            await refreshLibraries();
          } catch (error) {
            debugPrint('Refresh after reconnect failed: $error');
          }
        }());
      }
    }
  }

  Future<void> initialize() async {
    debugPrint('Nautune initialization started');
    await _ensureConnectivityMonitoring();
    final storedPlaybackState = await _playbackStateStore.load();
    if (storedPlaybackState != null) {
      _showVolumeBar = storedPlaybackState.showVolumeBar;
      _crossfadeEnabled = storedPlaybackState.crossfadeEnabled;
      _crossfadeDurationSeconds = storedPlaybackState.crossfadeDurationSeconds;
      _restoredLibraryTabIndex = storedPlaybackState.libraryTabIndex;
      _libraryScrollOffsets =
          Map<String, double>.from(storedPlaybackState.scrollOffsets);
      await _audioPlayerService.hydrateFromPersistence(storedPlaybackState);
      _audioPlayerService.setCrossfadeEnabled(_crossfadeEnabled);
      _audioPlayerService.setCrossfadeDuration(_crossfadeDurationSeconds);
    }

    try {
      final storedSession = await _sessionStore.load();
      if (storedSession != null) {
        if (storedSession.isDemo) {
          if (_demoModeProvider != null) {
            await _demoModeProvider!.startDemoMode();
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
        if (_networkAvailable) {
          _startBootstrapSync(storedSession);
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
      debugPrint('Nautune initialization finished (session restored: ${_session != null}, offline: $_isOfflineMode)');
      
      if (Platform.isIOS) {
        scheduleMicrotask(() async {
          try {
            await _carPlayService?.initialize();
          } catch (error) {
            debugPrint('CarPlay initialization skipped: $error');
          }
        });
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
      if (!_isOfflineMode && (_libraries == null || _libraries!.isEmpty)) {
        _isOfflineMode = true;
      }
      debugPrint('Network lost while syncing: $error');
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
        await _sessionProvider!.logout();
      } catch (error) {
        debugPrint('SessionProvider.logout failed: $error');
      }
    }
    await _teardownDemoMode();
    notifyListeners();
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
        return _demoModeProvider!.createPlaylist(name: name, itemIds: itemIds);
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

    if (!_networkAvailable || _isOfflineMode) {
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
        _demoModeProvider!.updatePlaylist(playlistId: playlistId, newName: newName);
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

    if (!_networkAvailable || _isOfflineMode) {
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
        _demoModeProvider!.deletePlaylist(playlistId);
        return;
      }
      _demoPlaylistTrackMap.remove(playlistId);
      _removeDemoPlaylist(playlistId);
      notifyListeners();
      return;
    }

    if (!_networkAvailable || _isOfflineMode) {
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
        _demoModeProvider!.addToPlaylist(playlistId: playlistId, itemIds: itemIds);
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

    if (!_networkAvailable || _isOfflineMode) {
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
        return _demoModeProvider!.getPlaylistTracks(playlistId);
      }
      final ids = _demoPlaylistTrackMap[playlistId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    return await _jellyfinService.getPlaylistItems(playlistId);
  }

  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        return _demoModeProvider!.getAlbumTracks(albumId);
      }
      final ids = _demoAlbumTrackMap[albumId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    if (_isDemoMode) {
      if (_demoModeProvider != null) {
        _demoModeProvider!.markFavorite(itemId, shouldBeFavorite);
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

    if (!_networkAvailable || _isOfflineMode) {
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
      await _sessionProvider!.updateSelectedLibrary(
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
      notifyListeners();
      return;
    }

    await Future.wait([
      _loadAlbumsForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadArtistsForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadPlaylistsForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadRecentForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadRecentlyAddedForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadFavorites(forceRefresh: forceRefresh),
      _loadGenres(libraryId, forceRefresh: forceRefresh),
    ]);
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
      final albums = await _jellyfinService.loadAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        startIndex: 0,
        limit: _albumsPageSize,
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
      final newAlbums = await _jellyfinService.loadAlbums(
        libraryId: libraryId,
        startIndex: _albumsPage * _albumsPageSize,
        limit: _albumsPageSize,
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
      final artists = await _jellyfinService.loadArtists(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        startIndex: 0,
        limit: _artistsPageSize,
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
      final newArtists = await _jellyfinService.loadArtists(
        libraryId: libraryId,
        startIndex: _artistsPage * _artistsPageSize,
        limit: _artistsPageSize,
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

  void clearLibrarySelection() {
    _session = _session?.copyWith(selectedLibraryId: null, selectedLibraryName: null);
    _albums = null;
    _playlists = null;
    _recentTracks = null;
    _favoriteTracks = null;
    notifyListeners();
    if (_session != null) {
      _sessionStore.save(_session!);
    }
  }

  void toggleOfflineMode() {
    _isOfflineMode = !_isOfflineMode;
    notifyListeners();
    
    // If switching to online mode and we have a session, try to refresh data
    if (!_isOfflineMode && _session != null && _networkAvailable) {
      refreshLibraries().catchError((error) {
        debugPrint('Failed to refresh libraries when going online: $error');
        _isOfflineMode = true;
        _networkAvailable = false;
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