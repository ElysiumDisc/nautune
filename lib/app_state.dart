import 'package:flutter/material.dart';

import 'jellyfin/jellyfin_album.dart';
import 'jellyfin/jellyfin_library.dart';
import 'jellyfin/jellyfin_playlist.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'jellyfin/jellyfin_track.dart';

class NautuneAppState extends ChangeNotifier {
  NautuneAppState({
    required JellyfinService jellyfinService,
    required JellyfinSessionStore sessionStore,
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore;

  final JellyfinService _jellyfinService;
  final JellyfinSessionStore _sessionStore;

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
  bool _isLoadingPlaylists = false;
  Object? _playlistsError;
  List<JellyfinPlaylist>? _playlists;
  bool _isLoadingRecent = false;
  Object? _recentError;
  List<JellyfinTrack>? _recentTracks;

  bool get isInitialized => _initialized;
  bool get isAuthenticating => _isAuthenticating;
  JellyfinSession? get session => _session;
  Object? get lastError => _lastError;
  bool get isLoadingLibraries => _isLoadingLibraries;
  Object? get librariesError => _librariesError;
  List<JellyfinLibrary>? get libraries => _libraries;
  bool get isLoadingAlbums => _isLoadingAlbums;
  Object? get albumsError => _albumsError;
  List<JellyfinAlbum>? get albums => _albums;
  bool get isLoadingPlaylists => _isLoadingPlaylists;
  Object? get playlistsError => _playlistsError;
  List<JellyfinPlaylist>? get playlists => _playlists;
  bool get isLoadingRecent => _isLoadingRecent;
  Object? get recentError => _recentError;
  List<JellyfinTrack>? get recentTracks => _recentTracks;
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

  Future<void> initialize() async {
    final storedSession = await _sessionStore.load();
    if (storedSession != null) {
      _session = storedSession;
      _jellyfinService.restoreSession(storedSession);
      await _loadLibraries();
      await _loadLibraryDependentContent();
    }
    _initialized = true;
    notifyListeners();
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
      notifyListeners();
      return;
    }

    await Future.wait([
      _loadAlbumsForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadPlaylistsForLibrary(libraryId, forceRefresh: forceRefresh),
      _loadRecentForLibrary(libraryId, forceRefresh: forceRefresh),
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
}
