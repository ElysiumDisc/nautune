import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../providers/ui_state_provider.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../repositories/music_repository.dart';
import '../services/haptic_service.dart';
import '../services/listenbrainz_service.dart';
import '../services/smart_playlist_service.dart';
import '../models/listenbrainz_config.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/download_indicators.dart';
import '../widgets/indexed_collection_view.dart';
import '../widgets/ios/action_sheet.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/library_tiles.dart';
import '../utils/debouncer.dart';
import '../utils/download_library.dart';
import '../utils/easter_egg_keywords.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/skeleton_loader.dart';
import '../widgets/sync_status_indicator.dart';
import '../widgets/track_context_menu.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'genre_detail_screen.dart';
import 'offline_library_screen.dart';
import 'essential_mix_screen.dart';
import 'frets_on_fire_screen.dart';
import 'relax_mode_screen.dart';
import 'network_screen.dart';
import 'piano_screen.dart';
import 'healing_frequencies_screen.dart';
import 'playlist_detail_screen.dart';
import 'profile_screen.dart';
import 'recently_played_screen.dart';
import 'settings_screen.dart';
import '../theme/nautune_spacing.dart';
import '../theme/nautune_theme.dart';

part 'tabs/albums_tab.dart';
part 'tabs/artists_tab.dart';
part 'tabs/favorites_tab.dart';
part 'tabs/genres_tab.dart';
part 'tabs/home_tab.dart';
part 'tabs/playlists_tab.dart';
part 'tabs/search_tab.dart';

/// Overflow actions in the library app bar.
enum _LibraryMenuAction { toggleOffline, offlineLibrary, switchLibrary, logOut }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  static const int _homeTabIndex = 2;
  late TabController _tabController;
  final ScrollController _albumsScrollController = ScrollController();
  final ScrollController _playlistsScrollController = ScrollController();
  int _currentTabIndex = _homeTabIndex;

  // Tab definitions: (icon, label) indexed by content position
  static const _tabDefs = <({IconData icon, String label})>[
    (icon: Icons.library_music, label: 'Library'),
    (icon: Icons.favorite_outline, label: 'Favorites'),
    (icon: Icons.home_outlined, label: 'Home'),
    (icon: Icons.queue_music, label: 'Playlists'),
    (icon: Icons.search, label: 'Search'),
  ];

  List<int> _tabOrder = const [0, 1, 2, 3, 4];

  // Provider-based state
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;

  // Tracked snapshots used by _onAppStateChanged to detect when a rebuild is
  // needed. listen:false on Provider.of (above) means the framework no longer
  // auto-rebuilds on every notifyListeners(); we manually rebuild only when one
  // of these UI-relevant fields actually changes.
  SortOption? _previousAlbumSortBy;
  SortOrder? _previousAlbumSortOrder;
  SortOption? _previousArtistSortBy;
  SortOrder? _previousArtistSortOrder;
  int? _previousAlbumsIdentity;
  int? _previousArtistsIdentity;
  int? _previousPlaylistsIdentity;
  int? _previousGenresIdentity;
  int? _previousFavoritesIdentity;
  int? _previousRecentTracksIdentity;
  int? _previousLibrariesIdentity;
  bool? _previousIsLoadingAlbums;
  bool? _previousIsLoadingArtists;
  bool? _previousIsLoadingPlaylists;
  bool? _previousIsLoadingFavorites;
  bool? _previousIsLoadingGenres;
  bool? _previousIsLoadingRecent;
  bool? _previousIsLoadingLibraries;
  bool? _previousIsLoadingMoreAlbums;
  bool? _previousIsLoadingMoreArtists;
  bool? _previousIsDemoMode;
  String? _previousSelectedLibraryId;
  Object? _previousLibrariesError;
  Object? _previousAlbumsError;
  Object? _previousArtistsError;
  Object? _previousPlaylistsError;
  Object? _previousFavoritesError;

  // Cached filtered favorites to avoid recomputing on every build
  List<JellyfinTrack>? _cachedFilteredFavorites;
  List<JellyfinTrack>? _lastFavoriteTracks;
  bool? _lastOfflineModeForFavorites;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 5,
      vsync: this,
      initialIndex: _homeTabIndex,
    );  // Library, Favorites, Home (Most), Playlists, Search
    _tabController.addListener(_handleTabChange);
    _albumsScrollController.addListener(_onAlbumsScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasInitialized) {
      _appState = Provider.of<NautuneAppState>(context, listen: false);
      _previousOfflineMode = _appState!.isOfflineMode;
      _previousNetworkAvailable = _appState!.networkAvailable;
      _previousAlbumSortBy = _appState!.albumSortBy;
      _previousAlbumSortOrder = _appState!.albumSortOrder;
      _previousArtistSortBy = _appState!.artistSortBy;
      _previousArtistSortOrder = _appState!.artistSortOrder;
      _previousAlbumsIdentity = identityHashCode(_appState!.albums);
      _previousArtistsIdentity = identityHashCode(_appState!.artists);
      _previousPlaylistsIdentity = identityHashCode(_appState!.playlists);
      _previousGenresIdentity = identityHashCode(_appState!.genres);
      _previousFavoritesIdentity = identityHashCode(_appState!.favoriteTracks);
      _previousRecentTracksIdentity = identityHashCode(_appState!.recentTracks);
      _previousLibrariesIdentity = identityHashCode(_appState!.libraries);
      _previousIsLoadingAlbums = _appState!.isLoadingAlbums;
      _previousIsLoadingArtists = _appState!.isLoadingArtists;
      _previousIsLoadingPlaylists = _appState!.isLoadingPlaylists;
      _previousIsLoadingFavorites = _appState!.isLoadingFavorites;
      _previousIsLoadingGenres = _appState!.isLoadingGenres;
      _previousIsLoadingRecent = _appState!.isLoadingRecent;
      _previousIsLoadingLibraries = _appState!.isLoadingLibraries;
      _previousIsLoadingMoreAlbums = _appState!.isLoadingMoreAlbums;
      _previousIsLoadingMoreArtists = _appState!.isLoadingMoreArtists;
      _previousIsDemoMode = _appState!.isDemoMode;
      _previousSelectedLibraryId = _appState!.selectedLibraryId;
      _previousLibrariesError = _appState!.librariesError;
      _previousAlbumsError = _appState!.albumsError;
      _previousArtistsError = _appState!.artistsError;
      _previousPlaylistsError = _appState!.playlistsError;
      _previousFavoritesError = _appState!.favoritesError;
      _hasInitialized = true;
      _tabOrder = List<int>.from(_appState!.navTabOrder);
      _appState!.addListener(_onAppStateChanged);

      // Restore saved tab index after build completes
      final savedTabIndex = _appState!.initialLibraryTabIndex;
      if (savedTabIndex != _homeTabIndex && savedTabIndex < 5) {
        _currentTabIndex = savedTabIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _tabController.index = savedTabIndex;
          }
        });
      }
    }
  }

  void _onAppStateChanged() {
    if (!mounted || _appState == null) return;
    final appState = _appState!;

    final offline = appState.isOfflineMode;
    final network = appState.networkAvailable;
    final connectivityChanged = _previousOfflineMode != offline ||
        _previousNetworkAvailable != network;

    final albumSortBy = appState.albumSortBy;
    final albumSortOrder = appState.albumSortOrder;
    final artistSortBy = appState.artistSortBy;
    final artistSortOrder = appState.artistSortOrder;
    final albumsId = identityHashCode(appState.albums);
    final artistsId = identityHashCode(appState.artists);
    final playlistsId = identityHashCode(appState.playlists);
    final genresId = identityHashCode(appState.genres);
    final favoritesId = identityHashCode(appState.favoriteTracks);
    final recentId = identityHashCode(appState.recentTracks);
    final librariesId = identityHashCode(appState.libraries);
    final isLoadingAlbums = appState.isLoadingAlbums;
    final isLoadingArtists = appState.isLoadingArtists;
    final isLoadingPlaylists = appState.isLoadingPlaylists;
    final isLoadingFavorites = appState.isLoadingFavorites;
    final isLoadingGenres = appState.isLoadingGenres;
    final isLoadingRecent = appState.isLoadingRecent;
    final isLoadingLibraries = appState.isLoadingLibraries;
    final isLoadingMoreAlbums = appState.isLoadingMoreAlbums;
    final isLoadingMoreArtists = appState.isLoadingMoreArtists;
    final isDemoMode = appState.isDemoMode;
    final selectedLibraryId = appState.selectedLibraryId;
    final librariesError = appState.librariesError;
    final albumsError = appState.albumsError;
    final artistsError = appState.artistsError;
    final playlistsError = appState.playlistsError;
    final favoritesError = appState.favoritesError;

    final dataChanged = _previousAlbumSortBy != albumSortBy ||
        _previousAlbumSortOrder != albumSortOrder ||
        _previousArtistSortBy != artistSortBy ||
        _previousArtistSortOrder != artistSortOrder ||
        _previousAlbumsIdentity != albumsId ||
        _previousArtistsIdentity != artistsId ||
        _previousPlaylistsIdentity != playlistsId ||
        _previousGenresIdentity != genresId ||
        _previousFavoritesIdentity != favoritesId ||
        _previousRecentTracksIdentity != recentId ||
        _previousLibrariesIdentity != librariesId ||
        _previousIsLoadingAlbums != isLoadingAlbums ||
        _previousIsLoadingArtists != isLoadingArtists ||
        _previousIsLoadingPlaylists != isLoadingPlaylists ||
        _previousIsLoadingFavorites != isLoadingFavorites ||
        _previousIsLoadingGenres != isLoadingGenres ||
        _previousIsLoadingRecent != isLoadingRecent ||
        _previousIsLoadingLibraries != isLoadingLibraries ||
        _previousIsLoadingMoreAlbums != isLoadingMoreAlbums ||
        _previousIsLoadingMoreArtists != isLoadingMoreArtists ||
        _previousIsDemoMode != isDemoMode ||
        _previousSelectedLibraryId != selectedLibraryId ||
        _previousLibrariesError != librariesError ||
        _previousAlbumsError != albumsError ||
        _previousArtistsError != artistsError ||
        _previousPlaylistsError != playlistsError ||
        _previousFavoritesError != favoritesError;

    if (connectivityChanged) {
      debugPrint('🔄 LibraryScreen: Connectivity changed (offline: $_previousOfflineMode -> $offline, network: $_previousNetworkAvailable -> $network)');
      _previousOfflineMode = offline;
      _previousNetworkAvailable = network;
    }

    if (dataChanged) {
      _previousAlbumSortBy = albumSortBy;
      _previousAlbumSortOrder = albumSortOrder;
      _previousArtistSortBy = artistSortBy;
      _previousArtistSortOrder = artistSortOrder;
      _previousAlbumsIdentity = albumsId;
      _previousArtistsIdentity = artistsId;
      _previousPlaylistsIdentity = playlistsId;
      _previousGenresIdentity = genresId;
      _previousFavoritesIdentity = favoritesId;
      _previousRecentTracksIdentity = recentId;
      _previousLibrariesIdentity = librariesId;
      _previousIsLoadingAlbums = isLoadingAlbums;
      _previousIsLoadingArtists = isLoadingArtists;
      _previousIsLoadingPlaylists = isLoadingPlaylists;
      _previousIsLoadingFavorites = isLoadingFavorites;
      _previousIsLoadingGenres = isLoadingGenres;
      _previousIsLoadingRecent = isLoadingRecent;
      _previousIsLoadingLibraries = isLoadingLibraries;
      _previousIsLoadingMoreAlbums = isLoadingMoreAlbums;
      _previousIsLoadingMoreArtists = isLoadingMoreArtists;
      _previousIsDemoMode = isDemoMode;
      _previousSelectedLibraryId = selectedLibraryId;
      _previousLibrariesError = librariesError;
      _previousAlbumsError = albumsError;
      _previousArtistsError = artistsError;
      _previousPlaylistsError = playlistsError;
      _previousFavoritesError = favoritesError;
    }

    if (connectivityChanged || dataChanged) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _albumsScrollController.dispose();
    _playlistsScrollController.dispose();
    super.dispose();
  }

  void _onAlbumsScroll() {
    if (_albumsScrollController.position.pixels >=
        _albumsScrollController.position.maxScrollExtent - 200) {
      // Load more albums when near bottom
      _appState?.loadMoreAlbums();
    }
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      _currentTabIndex = _tabController.index;
    });
    // Persist tab selection
    _appState?.updateLibraryTabIndex(_currentTabIndex);
    // Refresh favorites when switching to favorites tab (tab index 1)
    if (_currentTabIndex == 1) {
      _appState?.refreshFavorites();
    }
  }

  /// Returns filtered favorites with caching to avoid recomputing on every build
  List<JellyfinTrack>? _getFilteredFavorites(NautuneAppState appState) {
    final favoriteTracks = appState.favoriteTracks;
    final isOffline = appState.isOfflineMode;

    // Check if we can use cached result
    if (identical(_lastFavoriteTracks, favoriteTracks) &&
        _lastOfflineModeForFavorites == isOffline &&
        _cachedFilteredFavorites != null) {
      return _cachedFilteredFavorites;
    }

    // Update cache
    _lastFavoriteTracks = favoriteTracks;
    _lastOfflineModeForFavorites = isOffline;

    if (isOffline && favoriteTracks != null) {
      _cachedFilteredFavorites = favoriteTracks
          .where((t) => appState.downloadService.isDownloaded(t.id))
          .toList();
    } else {
      _cachedFilteredFavorites = favoriteTracks;
    }

    return _cachedFilteredFavorites;
  }

  Future<void> _handleManualRefresh() async {
    final appState = _appState;
    if (appState == null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Refreshing library...'),
        duration: Duration(seconds: 1),
      ),
    );

    // Refresh based on current tab
    switch (_currentTabIndex) {
      case 0: // Library (Albums/Artists)
        await appState.refreshLibraryData();
        break;
      case 1: // Favorites
        await appState.refreshFavorites();
        break;
      case 2: // Home/Downloads
        if (appState.isOfflineMode) {
           // Offline mode doesn't really need a "refresh" from server, maybe reload local files?
           // For now, just reload UI state is fine via notifyListeners inside logic if needed.
        } else {
           await appState.refreshLibraryData();
        }
        break;
      case 3: // Playlists
        await appState.refreshPlaylists();
        break;
      case 4: // Search
        // Search doesn't have a "refresh"
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = _appState;

    if (appState == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Provider triggers rebuilds on appState changes — no AnimatedBuilder needed.
    final libraries = appState.libraries;
        final isLoadingLibraries = appState.isLoadingLibraries;
        final libraryError = appState.librariesError;
        final selectedId = appState.selectedLibraryId;
        final playlists = appState.playlists;
        final isLoadingPlaylists = appState.isLoadingPlaylists;
        final playlistsError = appState.playlistsError;
        // Use cached filtered favorites to avoid recomputing on every build
        final favoriteTracks = _getFilteredFavorites(appState);
        final isLoadingFavorites = appState.isLoadingFavorites;
        final favoritesError = appState.favoritesError;

        Widget body;

        if (isLoadingLibraries && (libraries == null || libraries.isEmpty)) {
          body = const Center(child: CircularProgressIndicator());
        } else if (libraryError != null) {
          body = _ErrorState(
            message: 'Could not reach Jellyfin.\n${libraryError.toString()}',
            onRetry: () => appState.refreshLibraries(),
          );
        } else if (libraries == null || libraries.isEmpty) {
          body = _EmptyState(
            onRefresh: () => appState.refreshLibraries(),
          );
        } else if (selectedId == null) {
          // Show library selection
          body = RefreshIndicator(
            onRefresh: () => appState.refreshLibraries(),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: libraries.length + 1, // +1 for the header
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Pick a library to explore',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }
                final library = libraries[index - 1];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _LibraryTile(
                    library: library,
                    groupValue: selectedId,
                    onSelect: () => appState.selectLibrary(library),
                  ),
                );
              },
            ),
          );
        } else {
          // Show tabbed interface
          body = TabBarView(
            controller: _tabController,
            children: [
              _LibraryTab(
                appState: appState,
                onAlbumTap: (album) => _navigateToAlbum(context, album),
              ),
              _FavoritesTab(
                recentTracks: favoriteTracks,
                isLoading: isLoadingFavorites,
                error: favoritesError,
                onRefresh: () => appState.refreshFavorites(),
                onTrackTap: (track) => _playTrack(track),
                appState: appState,
              ),
              // Swap Most/Downloads based on offline mode
              appState.isOfflineMode
                  ? _DownloadsTab(appState: appState)
                  : _MostPlayedTab(appState: appState, onAlbumTap: (album) => _navigateToAlbum(context, album)),
              _PlaylistsTab(
                playlists: playlists,
                isLoading: isLoadingPlaylists,
                error: playlistsError,
                scrollController: _playlistsScrollController,
                onRefresh: () => appState.refreshPlaylists(),
                appState: appState,
              ),
              _SearchTab(appState: appState),
            ],
          );
        }

        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f5): _handleManualRefresh,
            const SingleActivator(LogicalKeyboardKey.keyR, control: true): _handleManualRefresh,
            const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _handleManualRefresh,
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
            title: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (details) {
                    // Long-press the logo to manage downloads.
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => OfflineLibraryScreen(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(NautuneSpacing.sm),
                    child: Icon(
                      Icons.waves,
                      color: appState.isOfflineMode
                          ? theme.colorScheme.primary
                          : theme.colorScheme.primary.withValues(alpha: 0.7),
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: NautuneSpacing.xs),
                Flexible(
                  child: InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const SettingsScreen(),
                        ),
                      );
                    },
                    borderRadius: NautuneRadius.allSm,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NautuneSpacing.sm,
                        vertical: NautuneSpacing.xs,
                      ),
                      // Scale down rather than overflow when the offline
                      // action button is also in the app bar.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Nautune',
                          style: GoogleFonts.pacifico(
                            fontSize: 24,
                            color: theme.colorScheme.primary.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              const SyncStatusIndicator(),
              if (appState.isOfflineMode)
                IconButton(
                  icon: const Icon(Icons.cloud_off, size: 20),
                  color: theme.colorScheme.primary,
                  tooltip: 'Offline mode (tap to go online)',
                  onPressed: () => appState.toggleOfflineMode(),
                ),
              IconButton(
                icon: const Icon(Icons.person_outline),
                tooltip: 'Profile & Stats',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const ProfileScreen(),
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const SettingsScreen(),
                    ),
                  );
                },
              ),
              PopupMenuButton<_LibraryMenuAction>(
                tooltip: 'More',
                onSelected: (action) async {
                  switch (action) {
                    case _LibraryMenuAction.toggleOffline:
                      appState.toggleOfflineMode();
                    case _LibraryMenuAction.offlineLibrary:
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => OfflineLibraryScreen(),
                        ),
                      );
                    case _LibraryMenuAction.switchLibrary:
                      appState.clearLibrarySelection();
                    case _LibraryMenuAction.logOut:
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Log Out'),
                          content: const Text('Are you sure you want to log out?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(dialogContext, true),
                              child: const Text('Log Out'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        appState.disconnect();
                      }
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _LibraryMenuAction.toggleOffline,
                    child: ListTile(
                      leading: Icon(appState.isOfflineMode ? Icons.cloud_queue : Icons.cloud_off),
                      title: Text(appState.isOfflineMode ? 'Go online' : 'Go offline'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: _LibraryMenuAction.offlineLibrary,
                    child: ListTile(
                      leading: Icon(Icons.download_done),
                      title: Text('Downloads'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (selectedId != null)
                    const PopupMenuItem(
                      value: _LibraryMenuAction.switchLibrary,
                      child: ListTile(
                        leading: Icon(Icons.library_books_outlined),
                        title: Text('Switch library'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: _LibraryMenuAction.logOut,
                    child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('Log out'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              // Offline mode banner
              if (appState.isOfflineMode && !appState.networkAvailable)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  color: theme.colorScheme.tertiaryContainer,
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_off,
                        size: 20,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                      const SizedBox(width: NautuneSpacing.md),
                      Expanded(
                        child: Text(
                          'You\'re offline. Showing downloaded music only.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => appState.refreshLibraries(),
                        child: Text(
                          'Retry',
                          style: TextStyle(
                            color: theme.colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(child: body),
            ],
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onLongPress: () => _showReorderSheet(context),
                child: NavigationBar(
                  selectedIndex: _tabOrder.indexOf(_currentTabIndex),
                  onDestinationSelected: (visualIndex) {
                    final contentIndex = _tabOrder[visualIndex];
                    setState(() => _currentTabIndex = contentIndex);
                    _tabController.animateTo(contentIndex);
                  },
                  destinations: _tabOrder.map((contentIndex) {
                    final def = _tabDefs[contentIndex];
                    // Special case for tab 2: dynamic icon/label based on offline mode
                    if (contentIndex == 2) {
                      return NavigationDestination(
                        icon: Icon(appState.isOfflineMode ? Icons.download : def.icon),
                        label: appState.isOfflineMode ? 'Downloads' : def.label,
                      );
                    }
                    return NavigationDestination(
                      icon: Icon(def.icon),
                      label: def.label,
                    );
                  }).toList(),
                ),
              ),
              NowPlayingBar(
                audioService: appState.audioPlayerService,
                appState: appState,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReorderSheet(BuildContext context) {
    HapticService.mediumTap();
    final reorderList = List<int>.from(_tabOrder);
    final appState = _appState;

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Text(
                          'Reorder Tabs',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            setState(() {
                              _tabOrder = reorderList;
                            });
                            appState?.updateNavTabOrder(reorderList);
                          },
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ),
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: reorderList.length,
                    onReorderItem: (oldIndex, newIndex) {
                      setSheetState(() {
                        final item = reorderList.removeAt(oldIndex);
                        reorderList.insert(newIndex, item);
                      });
                    },
                    itemBuilder: (context, index) {
                      final contentIndex = reorderList[index];
                      final def = _tabDefs[contentIndex];
                      final label = (contentIndex == 2 && (appState?.isOfflineMode ?? false))
                          ? 'Downloads'
                          : def.label;
                      final icon = (contentIndex == 2 && (appState?.isOfflineMode ?? false))
                          ? Icons.download
                          : def.icon;
                      return ListTile(
                        key: ValueKey(contentIndex),
                        leading: Icon(icon),
                        title: Text(label),
                        trailing: const Icon(Icons.drag_handle),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _navigateToAlbum(BuildContext context, JellyfinAlbum album) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AlbumDetailScreen(
          album: album,
        ),
      ),
    );
  }

  Future<void> _playTrack(JellyfinTrack track) async {
    final appState = _appState;
    if (appState == null) return;

    try {
      await appState.audioPlayerService.playTrack(
        track,
        queueContext: appState.favoriteTracks,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not start playback: $error'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

// Supporting Widgets


class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.library_music, size: 64),
          const SizedBox(height: NautuneSpacing.lg),
          const Text('No libraries found'),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: NautuneSpacing.lg),
            Text(message, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: NautuneSpacing.lg),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryTile extends StatelessWidget {
  const _LibraryTile({
    required this.library,
    required this.groupValue,
    required this.onSelect,
  });

  final JellyfinLibrary library;
  final String? groupValue;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = groupValue == library.id;
    return Card(
      elevation: isSelected ? 4 : 1,
      color: isSelected ? theme.colorScheme.secondaryContainer : theme.colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.library_music,
                color: isSelected ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: NautuneSpacing.lg),
              Expanded(
                child: Text(
                  library.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: isSelected ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurface,
                  ),
                ),
              ),
              if (isSelected) Icon(Icons.check_circle, color: theme.colorScheme.secondary),
            ],
          ),
        ),
      ),
    );
  }
}

// New combined Library tab with Albums/Artists toggle
class _LibraryTab extends StatefulWidget {
  const _LibraryTab({
    required this.appState,
    required this.onAlbumTap,
  });

  final NautuneAppState appState;
  final Function(JellyfinAlbum) onAlbumTap;

  @override
  State<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<_LibraryTab> {
  String _selectedView = 'albums'; // 'albums', 'artists', or 'genres'
  late ScrollController _albumsScrollController;
  late ScrollController _artistsScrollController;

  // Offline content cache — recompute only when the completedDownloads list
  // identity changes, not on every parent rebuild.
  int? _lastOfflineDownloadsIdentity;
  List<JellyfinAlbum>? _cachedOfflineAlbums;
  List<JellyfinArtist>? _cachedOfflineArtists;

  @override
  void initState() {
    super.initState();
    _albumsScrollController = ScrollController();
    _albumsScrollController.addListener(_onAlbumsScroll);
    _artistsScrollController = ScrollController();
    _artistsScrollController.addListener(_onArtistsScroll);
  }

  @override
  void dispose() {
    _albumsScrollController.dispose();
    _artistsScrollController.dispose();
    super.dispose();
  }

  void _onAlbumsScroll() {
    if (_albumsScrollController.position.pixels >=
        _albumsScrollController.position.maxScrollExtent - 200) {
      widget.appState.loadMoreAlbums();
    }
  }

  void _onArtistsScroll() {
    if (_artistsScrollController.position.pixels >=
        _artistsScrollController.position.maxScrollExtent - 200) {
      widget.appState.loadMoreArtists();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = widget.appState.isOfflineMode;

    final theme = Theme.of(context);
    // Header stays put while the collection scrolls under it, so the A-Z
    // index's offsets are relative to the collection alone.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NautuneSpacing.lg, NautuneSpacing.sm, NautuneSpacing.lg, NautuneSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: CupertinoSlidingSegmentedControl<String>(
                  groupValue: _selectedView,
                  thumbColor: theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                  children: {
                    for (final (value, label) in [
                      ('albums', 'Albums'),
                      ('artists', 'Artists'),
                      if (!isOffline) ('genres', 'Genres'),
                    ])
                      value: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          label,
                          style: theme.textTheme.subhead.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _selectedView == value
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                  },
                  onValueChanged: (value) {
                    if (value == null) return;
                    HapticService.selectionClick();
                    setState(() => _selectedView = value);
                  },
                ),
              ),
              // Sort controls for albums and artists (not genres)
              if (!isOffline && _selectedView != 'genres') ...[
                const SizedBox(width: NautuneSpacing.sm),
                _SortControls(
                  appState: widget.appState,
                  isAlbums: _selectedView == 'albums',
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: isOffline ? _buildOfflineContent() : _buildOnlineContent(),
        ),
      ],
    );
  }

  Widget _buildOfflineContent() {
    final downloads = widget.appState.downloadService.completedDownloads;
    final downloadsId = identityHashCode(downloads);
    if (downloadsId != _lastOfflineDownloadsIdentity) {
      _lastOfflineDownloadsIdentity = downloadsId;
      _cachedOfflineAlbums = null;
      _cachedOfflineArtists = null;
    }

    if (_selectedView == 'albums') {
      var offlineAlbums = _cachedOfflineAlbums;
      if (offlineAlbums == null) {
        // Group by album id (not name) so same-name albums stay apart.
        offlineAlbums = [
          for (final group in groupOfflineAlbums(downloads))
            JellyfinAlbum(
              id: group.albumId ?? group.items.first.track.id,
              name: group.name,
              artists: [group.artist],
              artistIds: group.items.first.track.artistIds,
              productionYear: group.year,
              primaryImageTag: group.imageTag,
            ),
        ];
        _cachedOfflineAlbums = offlineAlbums;
      }

      return _AlbumsTab(
        albums: offlineAlbums,
        isLoading: false,
        isLoadingMore: false,
        error: null,
        scrollController: _albumsScrollController,
        onRefresh: () async {}, // No-op offline
        onAlbumTap: widget.onAlbumTap,
        appState: widget.appState,
      );
    } else {
      var offlineArtists = _cachedOfflineArtists;
      if (offlineArtists == null) {
        final Map<String, JellyfinArtist> artistsMap = {};
        for (final download in downloads) {
          final track = download.track;
          final artistName = track.displayArtist;
          // Use actual artist ID if available, otherwise fall back to artist name
          final artistId = track.artistIds.isNotEmpty
              ? track.artistIds.first
              : artistName;

          if (!artistsMap.containsKey(artistId)) {
            artistsMap[artistId] = JellyfinArtist(
              id: artistId,
              name: artistName,
              primaryImageTag: 'offline', // Marker for offline image availability
            );
          }
        }

        offlineArtists = artistsMap.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        _cachedOfflineArtists = offlineArtists;
      }

      return _ArtistsTab(
        appState: widget.appState,
        artists: offlineArtists,
        isLoading: false,
        isLoadingMore: false,
        error: null,
        scrollController: _artistsScrollController,
        onRefresh: () async {},
      );
    }
  }

  Widget _buildOnlineContent() {
    if (_selectedView == 'albums') {
      return _AlbumsTab(
        albums: widget.appState.albums,
        isLoading: widget.appState.isLoadingAlbums,
        isLoadingMore: widget.appState.isLoadingMoreAlbums,
        error: widget.appState.albumsError,
        scrollController: _albumsScrollController,
        onRefresh: () => widget.appState.refreshAlbums(),
        onAlbumTap: widget.onAlbumTap,
        appState: widget.appState,
        sortBy: widget.appState.albumSortBy,
        sortOrder: widget.appState.albumSortOrder,
        hasMore: widget.appState.hasMoreAlbums,
        onLoadAll: widget.appState.loadAllAlbums,
      );
    } else if (_selectedView == 'artists') {
      return _ArtistsTab(
        appState: widget.appState,
        scrollController: _artistsScrollController,
      );
    } else {
      return _GenresTab(appState: widget.appState);
    }
  }
}

/// Home tab while offline: the downloaded library (search, Shuffle all,
/// albums/artists) with the download queue status on top.
class _DownloadsTab extends StatelessWidget {
  const _DownloadsTab({required this.appState});

  final NautuneAppState appState;

  void _openManager(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const OfflineLibraryScreen(initialTab: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = appState.downloadService;
    return Column(
      children: [
        const DownloadQueueBanner(),
        ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final active = service.activeCount;
            if (active == 0) return const SizedBox.shrink();
            return Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                dense: true,
                leading: const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                title: Text(
                  '$active ${active == 1 ? 'download' : 'downloads'} in progress',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openManager(context),
              ),
            );
          },
        ),
        Expanded(
          child: OfflineLibraryView(
            appState: appState,
            onManage: () => _openManager(context),
          ),
        ),
      ],
    );
  }
}
