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
import '../repositories/music_repository.dart';
import '../services/local_cache_service.dart';
import '../services/bootstrap_service.dart';
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
/// - Demo mode (DemoModeProvider's job): in demo mode it holds no data, so
///   NautuneAppState's demo collections show through.
///
/// Every load captures the session generation (bumped whenever the session
/// or the selected library changes) and drops its result if the generation
/// moved while it was waiting, so one account's or library's data never
/// lands in another's state or cache. While [offlineCheck] reports offline,
/// loads read the local cache instead of the network.
///
/// Errors are only exposed when there is nothing to show: a failed refresh
/// that still has earlier or cached data keeps that data and no error.
class LibraryDataProvider extends ChangeNotifier {
  LibraryDataProvider({
    required SessionProvider sessionProvider,
    required JellyfinService jellyfinService,
    required LocalCacheService cacheService,
    JellyfinPlaylistStore? playlistStore,
    bool Function()? isOffline,
  })  : _sessionProvider = sessionProvider,
        _jellyfinService = jellyfinService,
        _cacheService = cacheService,
        _playlistStore = playlistStore ?? JellyfinPlaylistStore(),
        _isOffline = isOffline ?? _alwaysOnline {
    _sessionProvider.addListener(_onSessionChanged);
  }

  final SessionProvider _sessionProvider;
  final JellyfinService _jellyfinService;
  final LocalCacheService _cacheService;
  final JellyfinPlaylistStore _playlistStore;

  bool Function() _isOffline;
  static bool _alwaysOnline() => false;

  /// Replaces the offline check (for owners created after this provider,
  /// e.g. `provider.offlineCheck = () => appState.isOfflineMode`).
  set offlineCheck(bool Function() check) => _isOffline = check;

  bool get _offline => _isOffline();
  bool get _isDemo => _sessionProvider.isDemoMode;

  String? _lastSessionId;
  String? _lastLibraryId;
  String? _lastAccountKey;

  /// Bumped on every session / library change; loads started under an older
  /// generation discard their results.
  int _generation = 0;

  void _onSessionChanged() {
    final session = _sessionProvider.session;
    final sessionId = session?.credentials.accessToken; // Using token as session ID
    final libraryId = session?.selectedLibraryId;
    final sessionChanged = sessionId != _lastSessionId;
    final libraryChanged = libraryId != _lastLibraryId;
    if (!sessionChanged && !libraryChanged) return;

    _lastSessionId = sessionId;
    _lastLibraryId = libraryId;
    _generation++;
    // Loads of the old generation will never clear their flags.
    _resetLoadingFlags();

    if (session == null || session.isDemo) {
      // Logged out, or demo mode: NautuneAppState serves the demo library.
      _lastAccountKey = null;
      clearAllData();
      return;
    }

    if (sessionChanged) {
      // Another account (not just a refreshed token): its data must not
      // show, or be cached, under this one. The first session of the run
      // keeps whatever the bootstrap snapshot already applied.
      final accountKey = _cacheService.cacheKeyForSession(session);
      if (_lastAccountKey != null && _lastAccountKey != accountKey) {
        _clearLibraryData();
        _libraries = null;
        _playlists = null;
        _favoriteTracks = null;
        _librariesError = null;
        _playlistsError = null;
        _favoritesError = null;
      }
      _lastAccountKey = accountKey;
      loadLibraries();
      if (libraryId != null) {
        loadAllLibraryData(forceRefresh: true);
      } else {
        _clearLibraryData();
        notifyListeners();
      }
      return;
    }

    // Same session, another library: drop the old library's data first so
    // it never shows (or gets cached) under the new one.
    _clearLibraryData();
    notifyListeners();
    if (libraryId != null) {
      loadAllLibraryData(forceRefresh: true);
    }
  }

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
  static const int _albumsPageSize = 50;
  SortOption _albumSortBy = SortOption.name;
  SortOrder _albumSortOrder = SortOrder.ascending;

  // Artists (with pagination)
  bool _isLoadingArtists = false;
  Object? _artistsError;
  List<JellyfinArtist>? _artists;
  bool _isLoadingMoreArtists = false;
  bool _hasMoreArtists = true;
  static const int _artistsPageSize = 50;
  SortOption _artistSortBy = SortOption.name;
  SortOrder _artistSortOrder = SortOrder.ascending;
  // Monotonic IDs to discard stale results when sort changes mid-fetch.
  int _albumsLoadId = 0;
  int _artistsLoadId = 0;

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

  // Getters - Sort
  SortOption get albumSortBy => _albumSortBy;
  SortOrder get albumSortOrder => _albumSortOrder;
  SortOption get artistSortBy => _artistSortBy;
  SortOrder get artistSortOrder => _artistSortOrder;

  /// Update album sort and reload from server.
  Future<void> setAlbumSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_albumSortBy == sortBy && _albumSortOrder == sortOrder) return;
    _albumSortBy = sortBy;
    _albumSortOrder = sortOrder;
    await loadAlbums(forceRefresh: true);
  }

  /// Update artist sort and reload from server.
  Future<void> setArtistSort(SortOption sortBy, SortOrder sortOrder) async {
    if (_artistSortBy == sortBy && _artistSortOrder == sortOrder) return;
    _artistSortBy = sortBy;
    _artistSortOrder = sortOrder;
    await loadArtists(forceRefresh: true);
  }

  /// Seed sort state at startup without triggering a reload.
  void seedSortState({
    SortOption? albumSortBy,
    SortOrder? albumSortOrder,
    SortOption? artistSortBy,
    SortOrder? artistSortOrder,
  }) {
    if (albumSortBy != null) _albumSortBy = albumSortBy;
    if (albumSortOrder != null) _albumSortOrder = albumSortOrder;
    if (artistSortBy != null) _artistSortBy = artistSortBy;
    if (artistSortOrder != null) _artistSortOrder = artistSortOrder;
  }

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

  /// Reads a cached list, treating a missing key or a read failure as "none".
  Future<List<T>?> _readCache<T>(
    String? cacheKey,
    Future<List<T>?> Function(String key) read,
  ) async {
    if (cacheKey == null) return null;
    try {
      final cached = await read(cacheKey);
      return (cached == null || cached.isEmpty) ? null : cached;
    } catch (error) {
      debugPrint('LibraryDataProvider: cache read failed: $error');
      return null;
    }
  }

  static bool _isEmpty(List<Object?>? list) => list == null || list.isEmpty;

  /// Apply a bootstrap snapshot for fast startup.
  void applySnapshot(BootstrapSnapshot snapshot) {
    if (snapshot.libraries != null) {
      _libraries = snapshot.libraries;
      _librariesError = null;
      _isLoadingLibraries = false;
    }

    if (snapshot.playlists != null) {
      _playlists = snapshot.playlists;
      _playlistsError = null;
      _isLoadingPlaylists = false;
    }

    if (snapshot.albums != null) {
      _albums = snapshot.albums;
      _albumsError = null;
      _isLoadingAlbums = false;
    }

    if (snapshot.artists != null) {
      _artists = snapshot.artists;
      _artistsError = null;
      _isLoadingArtists = false;
    }

    if (snapshot.recentTracks != null) {
      _recentTracks = snapshot.recentTracks;
      _recentError = null;
      _isLoadingRecent = false;
    }

    if (snapshot.recentlyAddedAlbums != null) {
      _recentlyAddedAlbums = snapshot.recentlyAddedAlbums;
      _recentlyAddedError = null;
      _isLoadingRecentlyAdded = false;
    }

    notifyListeners();
  }

  void _resetLoadingFlags() {
    _isLoadingLibraries = false;
    _isLoadingAlbums = false;
    _isLoadingArtists = false;
    _isLoadingMoreAlbums = false;
    _isLoadingMoreArtists = false;
    _isLoadingPlaylists = false;
    _isLoadingRecent = false;
    _isLoadingRecentlyAdded = false;
    _isLoadingFavorites = false;
    _isLoadingGenres = false;
  }

  /// Clears the data that belongs to the selected library (albums, artists,
  /// recent, recently added, genres). Playlists and favorites are per user.
  void _clearLibraryData() {
    // Invalidate in-flight album/artist loads and pages.
    _albumsLoadId++;
    _artistsLoadId++;
    _albums = null;
    _artists = null;
    _recentTracks = null;
    _recentlyAddedAlbums = null;
    _genres = null;
    _albumsError = null;
    _artistsError = null;
    _recentError = null;
    _recentlyAddedError = null;
    _genresError = null;
    _isLoadingAlbums = false;
    _isLoadingArtists = false;
    _isLoadingMoreAlbums = false;
    _isLoadingMoreArtists = false;
    _isLoadingRecent = false;
    _isLoadingRecentlyAdded = false;
    _isLoadingGenres = false;
    _hasMoreAlbums = true;
    _hasMoreArtists = true;
  }

  /// Clear all library data (called on logout or library change).
  void clearAllData() {
    _generation++;
    _clearLibraryData();
    _libraries = null;
    _playlists = null;
    _favoriteTracks = null;

    _librariesError = null;
    _playlistsError = null;
    _favoritesError = null;

    _resetLoadingFlags();

    notifyListeners();
  }

  /// Load libraries from Jellyfin.
  Future<void> loadLibraries() async {
    if (_isDemo) return;
    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _librariesError = null;
    _isLoadingLibraries = true;
    notifyListeners();

    try {
      if (_offline) {
        final cached = await _readCache(cacheKey, _cacheService.readLibraries);
        if (gen != _generation) return;
        if (cached != null) _libraries = cached;
        return;
      }
      final results = await _jellyfinService.loadLibraries();
      if (gen != _generation) return;
      final audioLibraries = results.where((lib) => lib.isAudioLibrary).toList();
      _libraries = audioLibraries;

      if (cacheKey != null) {
        await _cacheService.saveLibraries(cacheKey, audioLibraries);
      }
      if (gen != _generation) return;

      await _ensureSelectedLibraryStillValid();
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load libraries: $error');

      final cached = await _readCache(cacheKey, _cacheService.readLibraries);
      if (gen != _generation) return;
      if (cached != null) _libraries = cached;
      if (_isEmpty(_libraries)) _librariesError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingLibraries = false;
        notifyListeners();
      }
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
      // The session listener clears the library's data when the selection
      // goes away.
      await _sessionProvider.clearSelectedLibrary();
    }
  }

  /// Load albums for the currently selected library.
  Future<void> loadAlbums({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _albums = null;
      _albumsError = null;
      _isLoadingAlbums = false;
      notifyListeners();
      return;
    }

    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _albumsError = null;
    _isLoadingAlbums = true;
    _hasMoreAlbums = true;
    final loadId = ++_albumsLoadId;
    // A page still loading for the previous load id is discarded and won't
    // clear its flag (it only clears its own), so clear it here.
    _isLoadingMoreAlbums = false;
    notifyListeners();
    bool current() => gen == _generation && loadId == _albumsLoadId;

    Future<List<JellyfinAlbum>?> readCached() => _readCache(
        cacheKey, (key) => _cacheService.readAlbums(key, libraryId: libraryId));

    try {
      if (_offline) {
        final cached = await readCached();
        if (!current()) return;
        if (cached != null) {
          _albums = cached;
          _hasMoreAlbums = cached.length >= _albumsPageSize;
        }
        return;
      }
      final albums = await _jellyfinService.loadAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        startIndex: 0,
        limit: _albumsPageSize,
        sortBy: sortOptionToJellyfin(_albumSortBy),
        sortOrder: sortOrderToJellyfin(_albumSortOrder),
      );
      // Discard if a newer load started while awaiting.
      if (!current()) return;
      _albums = albums;
      _hasMoreAlbums = albums.length == _albumsPageSize;

      if (cacheKey != null) {
        await _cacheService.saveAlbums(
          cacheKey,
          libraryId: libraryId,
          data: albums,
        );
      }
    } catch (error) {
      if (!current()) return;
      debugPrint('LibraryDataProvider: Failed to load albums: $error');

      final cached = await readCached();
      if (!current()) return;
      if (cached != null) _albums = cached;
      if (_isEmpty(_albums)) _albumsError = error;
    } finally {
      if (current()) {
        _isLoadingAlbums = false;
        notifyListeners();
      }
    }
  }

  /// Load the next page of albums. Pages continue from the loaded count,
  /// so a failed or discarded request never skips or repeats items.
  Future<void> loadMoreAlbums() => _pageAlbums(loadAll: false);

  /// Load every remaining album page (in large chunks), e.g. before an A-Z
  /// jump to a letter that isn't loaded yet. Waits for a page that is
  /// already loading instead of giving up.
  Future<void> loadAllAlbums() => _pageAlbums(loadAll: true);

  Future<void>? _albumsPaging;

  Future<void> _pageAlbums({required bool loadAll}) async {
    while (_albumsPaging != null) {
      if (!loadAll) return;
      await _albumsPaging;
    }
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (_isDemo ||
        _offline ||
        libraryId == null ||
        _isLoadingAlbums ||
        !_hasMoreAlbums ||
        _albums == null) {
      return;
    }

    final done = Completer<void>();
    _albumsPaging = done.future;
    _isLoadingMoreAlbums = true;
    final loadId = _albumsLoadId;
    notifyListeners();

    try {
      do {
        final limit = loadAll ? _loadAllChunk : _albumsPageSize;
        final page = await _jellyfinService.loadAlbums(
          libraryId: libraryId,
          startIndex: _albums!.length,
          limit: limit,
          sortBy: sortOptionToJellyfin(_albumSortBy),
          sortOrder: sortOrderToJellyfin(_albumSortOrder),
        );
        // Discard if sort/load changed (or data was cleared) while awaiting.
        if (loadId != _albumsLoadId || _albums == null) return;
        _albums = List.of(_albums!)..addAll(page);
        _hasMoreAlbums = page.length == limit;
      } while (loadAll && _hasMoreAlbums);
    } catch (error) {
      debugPrint('LibraryDataProvider: Error loading more albums: $error');
    } finally {
      _albumsPaging = null;
      if (loadId == _albumsLoadId) _isLoadingMoreAlbums = false;
      done.complete();
      notifyListeners();
    }
  }

  static const int _loadAllChunk = 1000;

  /// Load artists for the currently selected library.
  Future<void> loadArtists({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _artists = null;
      _artistsError = null;
      _isLoadingArtists = false;
      notifyListeners();
      return;
    }

    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _artistsError = null;
    _isLoadingArtists = true;
    _hasMoreArtists = true;
    final loadId = ++_artistsLoadId;
    // A page still loading for the previous load id is discarded and won't
    // clear its flag (it only clears its own), so clear it here.
    _isLoadingMoreArtists = false;
    notifyListeners();
    bool current() => gen == _generation && loadId == _artistsLoadId;

    Future<List<JellyfinArtist>?> readCached() => _readCache(
        cacheKey, (key) => _cacheService.readArtists(key, libraryId: libraryId));

    try {
      if (_offline) {
        final cached = await readCached();
        if (!current()) return;
        if (cached != null) {
          _artists = cached;
          _hasMoreArtists = cached.length >= _artistsPageSize;
        }
        return;
      }
      final artists = await _jellyfinService.loadArtists(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        startIndex: 0,
        limit: _artistsPageSize,
        sortBy: sortOptionToJellyfin(_artistSortBy),
        sortOrder: sortOrderToJellyfin(_artistSortOrder),
      );
      if (!current()) return;
      _artists = artists;
      _hasMoreArtists = artists.length == _artistsPageSize;

      if (cacheKey != null) {
        await _cacheService.saveArtists(
          cacheKey,
          libraryId: libraryId,
          data: artists,
        );
      }
    } catch (error) {
      if (!current()) return;
      debugPrint('LibraryDataProvider: Failed to load artists: $error');

      final cached = await readCached();
      if (!current()) return;
      if (cached != null) _artists = cached;
      if (_isEmpty(_artists)) _artistsError = error;
    } finally {
      if (current()) {
        _isLoadingArtists = false;
        notifyListeners();
      }
    }
  }

  /// Load the next page of artists (see [loadMoreAlbums]).
  Future<void> loadMoreArtists() => _pageArtists(loadAll: false);

  /// Load every remaining artist page (see [loadAllAlbums]).
  Future<void> loadAllArtists() => _pageArtists(loadAll: true);

  Future<void>? _artistsPaging;

  Future<void> _pageArtists({required bool loadAll}) async {
    while (_artistsPaging != null) {
      if (!loadAll) return;
      await _artistsPaging;
    }
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (_isDemo ||
        _offline ||
        libraryId == null ||
        _isLoadingArtists ||
        !_hasMoreArtists ||
        _artists == null) {
      return;
    }

    final done = Completer<void>();
    _artistsPaging = done.future;
    _isLoadingMoreArtists = true;
    final loadId = _artistsLoadId;
    notifyListeners();

    try {
      do {
        final limit = loadAll ? _loadAllChunk : _artistsPageSize;
        final page = await _jellyfinService.loadArtists(
          libraryId: libraryId,
          startIndex: _artists!.length,
          limit: limit,
          sortBy: sortOptionToJellyfin(_artistSortBy),
          sortOrder: sortOrderToJellyfin(_artistSortOrder),
        );
        if (loadId != _artistsLoadId || _artists == null) return;
        _artists = List.of(_artists!)..addAll(page);
        _hasMoreArtists = page.length == limit;
      } while (loadAll && _hasMoreArtists);
    } catch (error) {
      debugPrint('LibraryDataProvider: Error loading more artists: $error');
    } finally {
      _artistsPaging = null;
      if (loadId == _artistsLoadId) _isLoadingMoreArtists = false;
      done.complete();
      notifyListeners();
    }
  }

  /// Load playlists (global, not library-specific).
  Future<void> loadPlaylists({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _playlistsError = null;
    _isLoadingPlaylists = true;
    notifyListeners();

    Future<List<JellyfinPlaylist>?> readCached() async =>
        await _readCache(cacheKey, _cacheService.readPlaylists) ??
        await _readCache<JellyfinPlaylist>('store', (_) => _playlistStore.load());

    try {
      if (_offline) {
        final cached = await readCached();
        if (gen != _generation) return;
        if (cached != null) _playlists = cached;
        return;
      }
      final playlists = await _jellyfinService.loadPlaylists(
        libraryId: null,
        forceRefresh: forceRefresh,
      );
      if (gen != _generation) return;
      _playlists = playlists;
      await _playlistStore.save(playlists);

      if (cacheKey != null) {
        await _cacheService.savePlaylists(cacheKey, playlists);
      }
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load playlists: $error');

      final cached = await readCached();
      if (gen != _generation) return;
      if (cached != null) _playlists = cached;
      if (_isEmpty(_playlists)) _playlistsError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingPlaylists = false;
        notifyListeners();
      }
    }
  }

  /// Load recent tracks for the currently selected library.
  Future<void> loadRecentTracks({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _recentTracks = null;
      _recentError = null;
      _isLoadingRecent = false;
      notifyListeners();
      return;
    }

    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _recentError = null;
    _isLoadingRecent = true;
    notifyListeners();

    Future<List<JellyfinTrack>?> readCached() => _readCache(cacheKey,
        (key) => _cacheService.readRecentTracks(key, libraryId: libraryId));

    try {
      if (_offline) {
        final cached = await readCached();
        if (gen != _generation) return;
        if (cached != null) _recentTracks = cached;
        return;
      }
      final tracks = await _jellyfinService.loadRecentTracks(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      if (gen != _generation) return;
      _recentTracks = tracks;

      if (cacheKey != null) {
        await _cacheService.saveRecentTracks(
          cacheKey,
          libraryId: libraryId,
          data: tracks,
        );
      }
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load recent tracks: $error');

      final cached = await readCached();
      if (gen != _generation) return;
      if (cached != null) _recentTracks = cached;
      if (_isEmpty(_recentTracks)) _recentError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingRecent = false;
        notifyListeners();
      }
    }
  }

  /// Load recently added albums for the currently selected library.
  Future<void> loadRecentlyAddedAlbums({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _recentlyAddedAlbums = null;
      _recentlyAddedError = null;
      _isLoadingRecentlyAdded = false;
      notifyListeners();
      return;
    }

    final gen = _generation;
    final cacheKey = _sessionCacheKey;
    _recentlyAddedError = null;
    _isLoadingRecentlyAdded = true;
    notifyListeners();

    Future<List<JellyfinAlbum>?> readCached() => _readCache(cacheKey,
        (key) => _cacheService.readRecentlyAddedAlbums(key, libraryId: libraryId));

    try {
      if (_offline) {
        final cached = await readCached();
        if (gen != _generation) return;
        if (cached != null) _recentlyAddedAlbums = cached;
        return;
      }
      final albums = await _jellyfinService.loadRecentlyAddedAlbums(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
        limit: 20,
      );
      if (gen != _generation) return;
      _recentlyAddedAlbums = albums;

      if (cacheKey != null) {
        await _cacheService.saveRecentlyAddedAlbums(
          cacheKey,
          libraryId: libraryId,
          data: albums,
        );
      }
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load recently added: $error');

      final cached = await readCached();
      if (gen != _generation) return;
      if (cached != null) _recentlyAddedAlbums = cached;
      if (_isEmpty(_recentlyAddedAlbums)) _recentlyAddedError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingRecentlyAdded = false;
        notifyListeners();
      }
    }
  }

  /// Load favorite tracks. Offline this keeps the current list (there is no
  /// local copy to refresh from).
  Future<void> loadFavorites({bool forceRefresh = false}) async {
    if (_isDemo || _offline) return;
    final gen = _generation;
    _favoritesError = null;
    _isLoadingFavorites = true;
    notifyListeners();

    try {
      final tracks = await _jellyfinService.getFavoriteTracks();
      if (gen != _generation) return;
      _favoriteTracks = tracks;
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load favorites: $error');
      // Keep the list we had: a failed refresh must not wipe favorites that
      // are still browsable.
      if (_isEmpty(_favoriteTracks)) _favoritesError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingFavorites = false;
        notifyListeners();
      }
    }
  }

  /// Load genres for the currently selected library.
  Future<void> loadGenres({bool forceRefresh = false}) async {
    if (_isDemo) return;
    final libraryId = _sessionProvider.session?.selectedLibraryId;
    if (libraryId == null) {
      _genres = null;
      _genresError = null;
      _isLoadingGenres = false;
      notifyListeners();
      return;
    }
    if (_offline) return; // Genres aren't browsable offline.

    final gen = _generation;
    _genresError = null;
    _isLoadingGenres = true;
    notifyListeners();

    try {
      final genres = await _jellyfinService.loadGenres(
        libraryId: libraryId,
        forceRefresh: forceRefresh,
      );
      if (gen != _generation) return;
      _genres = genres;
    } catch (error) {
      if (gen != _generation) return;
      debugPrint('LibraryDataProvider: Failed to load genres: $error');
      if (_isEmpty(_genres)) _genresError = error;
    } finally {
      if (gen == _generation) {
        _isLoadingGenres = false;
        notifyListeners();
      }
    }
  }

  /// Load all library-dependent content at once.
  Future<void> loadAllLibraryData({bool forceRefresh = false}) async {
    if (_isDemo) return;
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

  @override
  void dispose() {
    _sessionProvider.removeListener(_onSessionChanged);
    // Clear all library data on dispose
    clearAllData();
    super.dispose();
  }
}
