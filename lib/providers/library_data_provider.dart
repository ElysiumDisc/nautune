import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_playlist_store.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/local_cache_service.dart';
import 'session_provider.dart';

/// Manages all library data (albums, artists, playlists, tracks, genres).
///
/// Responsibilities:
/// - Fetch library data from Jellyfin
/// - Cache data locally via LocalCacheService
/// - Manage loading states and errors
/// - Handle pagination for large datasets
/// - Coordinate with SessionProvider for auth context
///
/// This provider depends on SessionProvider to know which user/library is active.
/// It does NOT handle:
/// - Authentication (SessionProvider's job)
/// - UI state (UIStateProvider's job)
/// - Demo mode (DemoModeProvider's job)
class LibraryDataProvider extends ChangeNotifier {
  LibraryDataProvider({
    required SessionProvider sessionProvider,
    required JellyfinService jellyfinService,
    required LocalCacheService cacheService,
    JellyfinPlaylistStore? playlistStore,
  })  : _sessionProvider = sessionProvider,
        _jellyfinService = jellyfinService,
        _cacheService = cacheService,
        _playlistStore = playlistStore ?? JellyfinPlaylistStore();

  final SessionProvider _sessionProvider;
  final JellyfinService _jellyfinService;
  final LocalCacheService _cacheService;
  final JellyfinPlaylistStore _playlistStore;

  // Libraries
  bool _isLoadingLibraries = false;
  Object? _librariesError;
  List<JellyfinLibrary>? _libraries;

  // Albums (with pagination)
  bool _isLoadingAlbums = false;
  Object? _albumsError;
  List<JellyfinAlbum>? _albums;
  bool _isLoadingMoreAlbums = false;
  bool _hasMoreAlbums = true;
  int _albumsPage = 0;
  static const int _albumsPageSize = 50;

  // Artists (with pagination)
  bool _isLoadingArtists = false;
  Object? _artistsError;
  List<JellyfinArtist>? _artists;
  bool _isLoadingMoreArtists = false;
  bool _hasMoreArtists = true;
  int _artistsPage = 0;
  static const int _artistsPageSize = 50;

  // Playlists
  bool _isLoadingPlaylists = false;
  Object? _playlistsError;
  List<JellyfinPlaylist>? _playlists;

  // Recent Tracks
  bool _isLoadingRecent = false;
  Object? _recentError;
  List<JellyfinTrack>? _recentTracks;

  // Recently Added Albums
  bool _isLoadingRecentlyAdded = false;
  Object? _recentlyAddedError;
  List<JellyfinAlbum>? _recentlyAddedAlbums;

  // Favorites
  bool _isLoadingFavorites = false;
  Object? _favoritesError;
  List<JellyfinTrack>? _favoriteTracks;

  // Genres
  bool _isLoadingGenres = false;
  Object? _genresError;
  List<JellyfinGenre>? _genres;

  // Getters - Libraries
  bool get isLoadingLibraries => _isLoadingLibraries;
  Object? get librariesError => _librariesError;
  List<JellyfinLibrary>? get libraries => _libraries;

  JellyfinLibrary? get selectedLibrary {
    final libs = _libraries;
    final id = _sessionProvider.session?.selectedLibraryId;
    if (libs == null || id == null) return null;
    try {
      return libs.firstWhere((lib) => lib.id == id);
    } catch (_) {
      return null;
    }
  }

  // Getters - Albums
  bool get isLoadingAlbums => _isLoadingAlbums;
  Object? get albumsError => _albumsError;
  List<JellyfinAlbum>? get albums => _albums;
  bool get isLoadingMoreAlbums => _isLoadingMoreAlbums;
  bool get hasMoreAlbums => _hasMoreAlbums;

  // Getters - Artists
  bool get isLoadingArtists => _isLoadingArtists;
  Object? get artistsError => _artistsError;
  List<JellyfinArtist>? get artists => _artists;
  bool get isLoadingMoreArtists => _isLoadingMoreArtists;
  bool get hasMoreArtists => _hasMoreArtists;

  // Getters - Playlists
  bool get isLoadingPlaylists => _isLoadingPlaylists;
  Object? get playlistsError => _playlistsError;
  List<JellyfinPlaylist>? get playlists => _playlists;

  // Getters - Recent
  bool get isLoadingRecent => _isLoadingRecent;
  Object? get recentError => _recentError;
  List<JellyfinTrack>? get recentTracks => _recentTracks;

  // Getters - Recently Added
  bool get isLoadingRecentlyAdded => _isLoadingRecentlyAdded;
  Object? get recentlyAddedError => _recentlyAddedError;
  List<JellyfinAlbum>? get recentlyAddedAlbums => _recentlyAddedAlbums;

  // Getters - Favorites
  bool get isLoadingFavorites => _isLoadingFavorites;
  Object? get favoritesError => _favoritesError;
  List<JellyfinTrack>? get favoriteTracks => _favoriteTracks;

  // Getters - Genres
  bool get isLoadingGenres => _isLoadingGenres;
  Object? get genresError => _genresError;
  List<JellyfinGenre>? get genres => _genres;

  String? get _sessionCacheKey {
    final session = _sessionProvider.session;
    if (session == null) return null;
    return _cacheService.cacheKeyForSession(session);
  }

  /// Clear all library data (called on logout or library change).
  void clearAllData() {
    _libraries = null;
    _albums = null;
    _artists = null;
    _playlists = null;
    _recentTracks = null;
    _recentlyAddedAlbums = null;
    _favoriteTracks = null;
    _genres = null;

    _librariesError = null;
    _albumsError = null;
    _artistsError = null;
    _playlistsError = null;
    _recentError = null;
    _recentlyAddedError = null;
    _favoritesError = null;
    _genresError = null;

    _isLoadingLibraries = false;
    _isLoadingAlbums = false;
    _isLoadingArtists = false;
    _isLoadingPlaylists = false;
    _isLoadingRecent = false;
    _isLoadingRecentlyAdded = false;
    _isLoadingFavorites = false;
    _isLoadingGenres = false;

    _hasMoreAlbums = true;
    _hasMoreArtists = true;
    _albumsPage = 0;
    _artistsPage = 0;

    notifyListeners();
  }

  /// Load libraries from Jellyfin.
  Future<void> loadLibraries() async {
    _librariesError = null;
    _isLoadingLibraries = true;
    notifyListeners();

    try {
      final results = await _jellyfinService.loadLibraries();
      final audioLibraries = results.where((lib) => lib.isAudioLibrary).toList();
      _libraries = audioLibraries;

      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveLibraries(cacheKey, audioLibraries);
      }

      await _ensureSelectedLibraryStillValid();
    } catch (error) {
      debugPrint('LibraryDataProvider: Failed to load libraries: $error');
      _librariesError = error;

      // Try loading from cache
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readLibraries(cacheKey);
        if (cached != null && cached.isNotEmpty) {
          _libraries = cached;
        }
      }
    } finally {
      _isLoadingLibraries = false;
      notifyListeners();
    }
  }

  /// Ensure the selected library still exists.
  /// If not, clear the selection.
  Future<void> _ensureSelectedLibraryStillValid() async {
    final libs = _libraries;
    final session = _sessionProvider.session;
    if (libs == null || session == null) return;

    final currentId = session.selectedLibraryId;
    if (currentId == null) return;

    final stillExists = libs.any((lib) => lib.id == currentId);
    if (!stillExists) {
      await _sessionProvider.clearSelectedLibrary();
      // Clear library-dependent data
      _albums = null;
      _artists = null;
      _recentTracks = null;
      _recentlyAddedAlbums = null;
      notifyListeners();
    }
  }

  /// Load albums for the currently selected library.
  Future<void> loadAlbums({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _albums = null;
      _albumsError = null;
      _isLoadingAlbums = false;
      notifyListeners();
      return;
    }

    _albumsError = null;
    _isLoadingAlbums = true;
    _albumsPage = 0;
    _hasMoreAlbums = true;
    notifyListeners();

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
      debugPrint('LibraryDataProvider: Failed to load albums: $error');
      _albumsError = error;

      // Try loading from cache
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readAlbums(cacheKey, libraryId: libraryId);
        if (cached != null && cached.isNotEmpty) {
          _albums = cached;
        }
      }
    } finally {
      _isLoadingAlbums = false;
      notifyListeners();
    }
  }

  /// Load more albums (pagination).
  Future<void> loadMoreAlbums() async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
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
      debugPrint('LibraryDataProvider: Error loading more albums: $error');
      _albumsPage--; // Revert page on error
    } finally {
      _isLoadingMoreAlbums = false;
      notifyListeners();
    }
  }

  /// Load artists for the currently selected library.
  Future<void> loadArtists({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _artists = null;
      _artistsError = null;
      _isLoadingArtists = false;
      notifyListeners();
      return;
    }

    _artistsError = null;
    _isLoadingArtists = true;
    _artistsPage = 0;
    _hasMoreArtists = true;
    notifyListeners();

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
      debugPrint('LibraryDataProvider: Failed to load artists: $error');
      _artistsError = error;

      // Try loading from cache
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readArtists(cacheKey, libraryId: libraryId);
        if (cached != null && cached.isNotEmpty) {
          _artists = cached;
        }
      }
    } finally {
      _isLoadingArtists = false;
      notifyListeners();
    }
  }

  /// Load more artists (pagination).
  Future<void> loadMoreArtists() async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
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
      debugPrint('LibraryDataProvider: Error loading more artists: $error');
      _artistsPage--; // Revert page on error
    } finally {
      _isLoadingMoreArtists = false;
      notifyListeners();
    }
  }

  /// Load playlists (global, not library-specific).
  Future<void> loadPlaylists({bool forceRefresh = false}) async {
    _playlistsError = null;
    _isLoadingPlaylists = true;
    notifyListeners();

    try {
      final playlists = await _jellyfinService.loadPlaylists(
        libraryId: null,
        forceRefresh: forceRefresh,
      );
      _playlists = playlists;
      await _playlistStore.save(playlists);

      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.savePlaylists(cacheKey, playlists);
      }
    } catch (error) {
      debugPrint('LibraryDataProvider: Failed to load playlists: $error');
      _playlistsError = error;

      // Try loading from cache
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

  /// Load recent tracks for the currently selected library.
  Future<void> loadRecentTracks({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _recentTracks = null;
      _recentError = null;
      _isLoadingRecent = false;
      notifyListeners();
      return;
    }

    _recentError = null;
    _isLoadingRecent = true;
    notifyListeners();

    try {
      final tracks = await _jellyfinService.loadRecentTracks(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      _recentTracks = tracks;

      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        await _cacheService.saveRecentTracks(
          cacheKey,
          libraryId: libraryId,
          data: tracks,
        );
      }
    } catch (error) {
      debugPrint('LibraryDataProvider: Failed to load recent tracks: $error');
      _recentError = error;

      // Try loading from cache
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readRecentTracks(
          cacheKey,
          libraryId: libraryId,
        );
        if (cached != null && cached.isNotEmpty) {
          _recentTracks = cached;
        }
      }
    } finally {
      _isLoadingRecent = false;
      notifyListeners();
    }
  }

  /// Load recently added albums for the currently selected library.
  Future<void> loadRecentlyAddedAlbums({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _recentlyAddedAlbums = null;
      _recentlyAddedError = null;
      _isLoadingRecentlyAdded = false;
      notifyListeners();
      return;
    }

    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = true;
    notifyListeners();

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
      debugPrint('LibraryDataProvider: Failed to load recently added: $error');
      _recentlyAddedError = error;

      // Try loading from cache
      final cacheKey = _sessionCacheKey;
      if (cacheKey != null) {
        final cached = await _cacheService.readRecentlyAddedAlbums(
          cacheKey,
          libraryId: libraryId,
        );
        if (cached != null && cached.isNotEmpty) {
          _recentlyAddedAlbums = cached;
        }
      }
    } finally {
      _isLoadingRecentlyAdded = false;
      notifyListeners();
    }
  }

  /// Load favorite tracks.
  Future<void> loadFavorites({bool forceRefresh = false}) async {
    _favoritesError = null;
    _isLoadingFavorites = true;
    notifyListeners();

    try {
      final tracks = await _jellyfinService.getFavoriteTracks();
      _favoriteTracks = tracks;
    } catch (error) {
      debugPrint('LibraryDataProvider: Failed to load favorites: $error');
      _favoritesError = error;
      _favoriteTracks = null;
    } finally {
      _isLoadingFavorites = false;
      notifyListeners();
    }
  }

  /// Load genres for the currently selected library.
  Future<void> loadGenres({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _genres = null;
      _genresError = null;
      _isLoadingGenres = false;
      notifyListeners();
      return;
    }

    _genresError = null;
    _isLoadingGenres = true;
    notifyListeners();

    try {
      final genres = await _jellyfinService.loadGenres(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      _genres = genres;
    } catch (error) {
      debugPrint('LibraryDataProvider: Failed to load genres: $error');
      _genresError = error;
      _genres = null;
    } finally {
      _isLoadingGenres = false;
      notifyListeners();
    }
  }

  /// Load all library-dependent content at once.
  Future<void> loadAllLibraryContent({bool forceRefresh = false}) async {
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      clearAllData();
      return;
    }

    await Future.wait([
      loadAlbums(forceRefresh: forceRefresh),
      loadArtists(forceRefresh: forceRefresh),
      loadPlaylists(forceRefresh: forceRefresh),
      loadRecentTracks(forceRefresh: forceRefresh),
      loadRecentlyAddedAlbums(forceRefresh: forceRefresh),
      loadFavorites(forceRefresh: forceRefresh),
      loadGenres(forceRefresh: forceRefresh),
    ]);
  }

  /// Get tracks for a specific album.
  Future<List<JellyfinTrack>> getAlbumTracks(String albumId) async {
    return await _jellyfinService.getAlbumTracks(albumId);
  }

  /// Get tracks for a specific playlist.
  Future<List<JellyfinTrack>> getPlaylistTracks(String playlistId) async {
    return await _jellyfinService.getPlaylistItems(playlistId);
  }

  // Playlist Management

  /// Create a new playlist.
  Future<JellyfinPlaylist> createPlaylist({
    required String name,
    List<String>? itemIds,
  }) async {
    final playlist = await _jellyfinService.createPlaylist(
      name: name,
      itemIds: itemIds,
    );
    await loadPlaylists(forceRefresh: true);
    return playlist;
  }

  /// Update a playlist's name.
  Future<void> updatePlaylist({
    required String playlistId,
    required String newName,
  }) async {
    await _jellyfinService.updatePlaylist(
      playlistId: playlistId,
      newName: newName,
    );
    await loadPlaylists(forceRefresh: true);
  }

  /// Delete a playlist.
  Future<void> deletePlaylist(String playlistId) async {
    await _jellyfinService.deletePlaylist(playlistId);
    await loadPlaylists(forceRefresh: true);
  }

  /// Add tracks to a playlist.
  Future<void> addToPlaylist({
    required String playlistId,
    required List<String> itemIds,
  }) async {
    await _jellyfinService.addItemsToPlaylist(
      playlistId: playlistId,
      itemIds: itemIds,
    );
    await loadPlaylists(forceRefresh: true);
  }

  /// Mark a track as favorite/unfavorite.
  Future<void> markFavorite(String itemId, bool shouldBeFavorite) async {
    await _jellyfinService.markFavorite(itemId, shouldBeFavorite);
    // Optionally refresh favorites list
    await loadFavorites(forceRefresh: true);
  }
}
