import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'demo/demo_content.dart';
import 'jellyfin/jellyfin_album.dart';
import 'jellyfin/jellyfin_artist.dart';
import 'jellyfin/jellyfin_genre.dart';
import 'jellyfin/jellyfin_library.dart';
import 'jellyfin/jellyfin_credentials.dart';
import 'jellyfin/jellyfin_playlist.dart';
import 'jellyfin/jellyfin_playlist_store.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'jellyfin/jellyfin_track.dart';
import 'services/audio_player_service.dart';
import 'services/carplay_service.dart';
import 'services/download_service.dart';
import 'services/playback_reporting_service.dart';
import 'services/playback_state_store.dart';
import 'services/playlist_sync_queue.dart';

class NautuneAppState extends ChangeNotifier {
  NautuneAppState({
    required JellyfinService jellyfinService,
    required JellyfinSessionStore sessionStore,
    required PlaybackStateStore playbackStateStore,
    JellyfinPlaylistStore? playlistStore,
    PlaylistSyncQueue? syncQueue,
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore,
        _playbackStateStore = playbackStateStore,
        _playlistStore = playlistStore ?? JellyfinPlaylistStore(),
        _syncQueue = syncQueue ?? PlaylistSyncQueue() {
    _audioPlayerService = AudioPlayerService();
    _downloadService = DownloadService(jellyfinService: jellyfinService);
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
  }

  final JellyfinService _jellyfinService;
  final JellyfinSessionStore _sessionStore;
  final PlaybackStateStore _playbackStateStore;
  final JellyfinPlaylistStore _playlistStore;
  final PlaylistSyncQueue _syncQueue;
  late final AudioPlayerService _audioPlayerService;
  late final DownloadService _downloadService;
  CarPlayService? _carPlayService;
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
  bool _isLoadingFavorites = false;
  Object? _favoritesError;
  List<JellyfinTrack>? _favoriteTracks;
  bool _isLoadingGenres = false;
  Object? _genresError;
  List<JellyfinGenre>? _genres;
  bool _isOfflineMode = false;  // Toggle between online and offline library
  bool _networkAvailable = true;  // Track network connectivity

  bool get isInitialized => _initialized;
  bool get networkAvailable => _networkAvailable;
  bool get isDemoMode => _isDemoMode;
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

  JellyfinService get jellyfinService => _jellyfinService;
  AudioPlayerService get audioPlayerService => _audioPlayerService;
  DownloadService get downloadService => _downloadService;
  List<JellyfinAlbum> get demoAlbums =>
      _demoContent?.albums ?? const <JellyfinAlbum>[];
  List<JellyfinArtist> get demoArtists =>
      _demoContent?.artists ?? const <JellyfinArtist>[];

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

  String _buildStreamUrl(String trackId) {
    final session = _session;
    if (session == null) {
      throw StateError('Session not initialized');
    }
    return '${session.serverUrl}/Audio/$trackId/stream?'
        'api_key=${session.credentials.accessToken}&'
        'audioCodec=aac';
  }

  Future<void> initialize() async {
    debugPrint('Nautune initialization started');
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
          final data =
              await rootBundle.load('assets/demo/demo_offline_track.mp3');
          await _setupDemoMode(DemoContent(), data.buffer.asUint8List());
          _initialized = true;
          notifyListeners();
          return;
        }
        _session = storedSession;
        _jellyfinService.restoreSession(storedSession);
        _audioPlayerService.setJellyfinService(_jellyfinService);
        
        // Initialize playback reporting for restored session
        final reportingService = PlaybackReportingService(
          serverUrl: storedSession.serverUrl,
          accessToken: storedSession.credentials.accessToken,
        );
        _audioPlayerService.setReportingService(reportingService);
        
        // Attempt to load libraries from server
        // If network is unavailable, gracefully fall back to offline mode
        try {
          // Add timeout to prevent infinite spinning on airplane mode
          await _loadLibraries().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Server unreachable');
            },
          );
          await _loadLibraryDependentContent().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Server unreachable');
            },
          );
          _networkAvailable = true;
          // Sync any pending playlist actions
          unawaited(_syncPendingPlaylistActions());
        } catch (error) {
          debugPrint('Network unavailable during initialization, entering offline mode: $error');
          _networkAvailable = false;
          _isOfflineMode = true;
          // Don't clear session - keep it for when network returns
          // Load cached playlists for offline use
          final cachedPlaylists = await _playlistStore.load();
          if (cachedPlaylists != null) {
            _playlists = cachedPlaylists;
          }
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
      
      // Initialize CarPlay after the first frame so plugin setup cannot block UI
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

  Future<void> startDemoExperience() async {
    _lastError = null;
    _isAuthenticating = true;
    notifyListeners();

    try {
      await _teardownDemoMode();
      final data = await rootBundle.load('assets/demo/demo_offline_track.mp3');
      final content = DemoContent();
      await _setupDemoMode(content, data.buffer.asUint8List());
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _lastError = null;
    _isAuthenticating = true;
    notifyListeners();

    try {
      await _teardownDemoMode();
      final session = await _jellyfinService.connect(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      _session = session;
      _audioPlayerService.setJellyfinService(_jellyfinService);
      await _sessionStore.save(session);
      
      // Initialize playback reporting
      final reportingService = PlaybackReportingService(
        serverUrl: session.serverUrl,
        accessToken: session.credentials.accessToken,
      );
      _audioPlayerService.setReportingService(reportingService);
      
      await _loadLibraries();
      await _loadLibraryDependentContent(forceRefresh: true);
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
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
    _favoriteTracks = null;
    _favoritesError = null;
    _isLoadingFavorites = false;
    await _sessionStore.clear();
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
      final ids = _demoPlaylistTrackMap[playlistId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    return await _jellyfinService.getPlaylistItems(playlistId);
  }

  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    if (_isDemoMode) {
      final ids = _demoAlbumTrackMap[albumId] ?? const <String>[];
      return _demoTracksFromIds(ids);
    }
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    if (_isDemoMode) {
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

      final session = _session;
      if (session != null) {
        final currentId = session.selectedLibraryId;
        final stillExists = currentId != null &&
            audioLibraries.any((lib) => lib.id == currentId);
        if (!stillExists && currentId != null) {
          final updated = session.copyWith(
            selectedLibraryId: null,
            selectedLibraryName: null,
          );
          _session = updated;
          await _sessionStore.save(updated);
          _albums = null;
          _playlists = null;
          _recentTracks = null;
        }
      }
    } catch (error) {
      _librariesError = error;
      _libraries = null;
    } finally {
      _isLoadingLibraries = false;
      notifyListeners();
    }
  }

  Future<void> selectLibrary(JellyfinLibrary library) async {
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
    await _loadLibraryDependentContent(forceRefresh: true);
    notifyListeners();
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
    } catch (error) {
      _albumsError = error;
      _albums = null;
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
    } catch (error) {
      _artistsError = error;
      _artists = null;
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
    } catch (error) {
      _playlistsError = error;
      final cached = await _playlistStore.load();
      _playlists = cached;
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
    } catch (error) {
      _recentError = error;
      _recentTracks = null;
    } finally {
      _isLoadingRecent = false;
      notifyListeners();
    }
  }

  Future<void> refreshRecent() async {
    final libraryId = selectedLibraryId;
    if (libraryId != null) {
      await _loadRecentForLibrary(libraryId, forceRefresh: true);
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

  AudioPlayerService get audioService => _audioPlayerService;

  String buildImageUrl({required String itemId, String? tag, int maxWidth = 400}) {
    return _jellyfinService.buildImageUrl(
      itemId: itemId,
      tag: tag,
      maxWidth: maxWidth,
    );
  }
}
