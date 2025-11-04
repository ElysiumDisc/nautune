import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'jellyfin/jellyfin_album.dart';
import 'jellyfin/jellyfin_artist.dart';
import 'jellyfin/jellyfin_genre.dart';
import 'jellyfin/jellyfin_library.dart';
import 'jellyfin/jellyfin_playlist.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'jellyfin/jellyfin_track.dart';
import 'services/audio_player_service.dart';
import 'services/carplay_service.dart';
import 'services/download_service.dart';
import 'services/playback_reporting_service.dart';
import 'services/playback_state_store.dart';

class NautuneAppState extends ChangeNotifier {
  NautuneAppState({
    required JellyfinService jellyfinService,
    required JellyfinSessionStore sessionStore,
    required PlaybackStateStore playbackStateStore,
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore,
        _playbackStateStore = playbackStateStore {
    _audioPlayerService = AudioPlayerService();
    _downloadService = DownloadService(jellyfinService: jellyfinService);
    // Link download service to audio player for offline playback
    _audioPlayerService.setDownloadService(_downloadService);
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
  late final AudioPlayerService _audioPlayerService;
  late final DownloadService _downloadService;
  CarPlayService? _carPlayService;

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
  bool _isLoadingArtists = false;
  Object? _artistsError;
  List<JellyfinArtist>? _artists;
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
  bool get isAuthenticating => _isAuthenticating;
  JellyfinSession? get session => _session;
  Object? get lastError => _lastError;
  bool get isLoadingLibraries => _isLoadingLibraries;
  Object? get librariesError => _librariesError;
  List<JellyfinLibrary>? get libraries => _libraries;
  bool get isLoadingAlbums => _isLoadingAlbums;
  Object? get albumsError => _albumsError;
  List<JellyfinAlbum>? get albums => _albums;
  bool get isLoadingArtists => _isLoadingArtists;
  Object? get artistsError => _artistsError;
  List<JellyfinArtist>? get artists => _artists;
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
    try {
      final storedSession = await _sessionStore.load();
      if (storedSession != null) {
        _session = storedSession;
        _jellyfinService.restoreSession(storedSession);
        
        // Initialize playback reporting for restored session
        final reportingService = PlaybackReportingService(
          serverUrl: storedSession.serverUrl,
          accessToken: storedSession.credentials.accessToken,
        );
        _audioPlayerService.setReportingService(reportingService);
        
        // Attempt to load libraries from server
        // If network is unavailable, gracefully fall back to offline mode
        try {
          await _loadLibraries();
          await _loadLibraryDependentContent();
          _networkAvailable = true;
        } catch (error) {
          debugPrint('Network unavailable during initialization, entering offline mode: $error');
          _networkAvailable = false;
          _isOfflineMode = true;
          // Don't clear session - keep it for when network returns
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

  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _lastError = null;
    _isAuthenticating = true;
    notifyListeners();

    try {
      final session = await _jellyfinService.connect(
        serverUrl: serverUrl,
        username: username,
        password: password,
      );
      _session = session;
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
    await _jellyfinService.updatePlaylist(
      playlistId: playlistId,
      newName: newName,
    );
    await refreshPlaylists();
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _jellyfinService.deletePlaylist(playlistId);
    await refreshPlaylists();
  }

  Future<void> addToPlaylist({
    required String playlistId,
    required List<String> itemIds,
  }) async {
    await _jellyfinService.addItemsToPlaylist(
      playlistId: playlistId,
      itemIds: itemIds,
    );
  }

  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId) async {
    return await _jellyfinService.getPlaylistItems(playlistId);
  }

  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  Future<void> _loadLibraries() async {
    _librariesError = null;
    _isLoadingLibraries = true;
    notifyListeners();

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
    await _sessionStore.save(updated);
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
    notifyListeners();

    try {
      _albums = await _jellyfinService.loadAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      _albumsError = error;
      _albums = null;
    } finally {
      _isLoadingAlbums = false;
      notifyListeners();
    }
  }

  Future<void> _loadArtistsForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _artistsError = null;
    _isLoadingArtists = true;
    notifyListeners();

    try {
      _artists = await _jellyfinService.loadArtists(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      _artistsError = error;
      _artists = null;
    } finally {
      _isLoadingArtists = false;
      notifyListeners();
    }
  }

  Future<void> _loadPlaylistsForLibrary(String libraryId,
      {bool forceRefresh = false}) async {
    _playlistsError = null;
    _isLoadingPlaylists = true;
    notifyListeners();

    try {
      _playlists = await _jellyfinService.loadPlaylists(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
    } catch (error) {
      _playlistsError = error;
      _playlists = null;
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
    }
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
