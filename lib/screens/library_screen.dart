import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../providers/syncplay_provider.dart';
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
import '../services/helm_service.dart';
import '../services/listenbrainz_service.dart';
import '../services/share_service.dart';
import '../services/smart_playlist_service.dart';
import '../widgets/helm_mode_selector.dart';
import '../models/listenbrainz_config.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/jellyfin_image.dart';
import '../utils/debouncer.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/skeleton_loader.dart';
import '../widgets/sync_status_indicator.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'genre_detail_screen.dart';
import 'offline_library_screen.dart';
import 'collab_playlist_screen.dart';
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

part 'tabs/albums_tab.dart';
part 'tabs/artists_tab.dart';
part 'tabs/favorites_tab.dart';
part 'tabs/genres_tab.dart';
part 'tabs/home_tab.dart';
part 'tabs/playlists_tab.dart';
part 'tabs/search_tab.dart';
part '../widgets/alphabet_scrollbar.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    this.collabBrowseMode = false,
  });

  /// When true, shows "Add to Collab" buttons instead of normal play buttons
  final bool collabBrowseMode;

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
  HelmService? _helmService;
  String? _helmSessionDeviceId; // Track which session the helm service was created for

  // Provider-based state
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;

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
      _hasInitialized = true;
      _tabOrder = List<int>.from(_appState!.navTabOrder);
      _appState!.addListener(_onConnectivityChanged);

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

  void _onConnectivityChanged() {
    if (!mounted || _appState == null) return;
    final offline = _appState!.isOfflineMode;
    final network = _appState!.networkAvailable;
    if (_previousOfflineMode != offline || _previousNetworkAvailable != network) {
      debugPrint('🔄 LibraryScreen: Connectivity changed (offline: $_previousOfflineMode -> $offline, network: $_previousNetworkAvailable -> $network)');
      _previousOfflineMode = offline;
      _previousNetworkAvailable = network;
      if (!network || offline) {
        _helmService?.suspendPolling();
      } else {
        _helmService?.resumePolling();
      }
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onConnectivityChanged);
    _helmService?.dispose();
    _helmService = null;
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
        if (mounted) {
          context.read<SyncPlayProvider>().refreshGroups();
        }
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
                  onTap: () {
                    appState.toggleOfflineMode();
                  },
                  onLongPressStart: (details) {
                    // Show downloads management on long press (iOS/Android)
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            OfflineLibraryScreen(),
                      ),
                    );
                  },
                  onSecondaryTap: () {
                    // Show downloads management on right click (Linux/Desktop)
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            OfflineLibraryScreen(),
                      ),
                    );
                  },
                  child: Tooltip(
                    message: appState.isOfflineMode ? 'Offline library' : 'Go to offline library',
                    child: Container(
                      padding: const EdgeInsets.all(8.0),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        Icons.waves,
                        color: appState.isOfflineMode
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withValues(alpha: 0.7),
                        size: 28,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const SettingsScreen(),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                    child: Row(
                      children: [
                        Text(
                          'Nautune',
                          style: GoogleFonts.pacifico(
                            fontSize: 24,
                            color: theme.colorScheme.primary.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (appState.isOfflineMode) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.offline_bolt,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              const SyncStatusIndicator(),
              if (appState.isOfflineMode)
                Tooltip(
                  message: 'Offline Mode',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.cloud_off,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                  ),
                ),
              if (selectedId != null)
                IconButton(
                  icon: const Icon(Icons.library_books_outlined),
                  onPressed: () => appState.clearLibrarySelection(),
                ),
              if (!appState.isDemoMode && !appState.isOfflineMode)
                Builder(
                  builder: (ctx) {
                    final isHelmActive = _helmService?.isActive ?? false;
                    return IconButton(
                      icon: Icon(
                        Icons.sailing,
                        color: isHelmActive ? theme.colorScheme.primary : null,
                      ),
                      tooltip: 'Helm Mode',
                      onPressed: () {
                        final jellyfinService = appState.jellyfinService;
                        final client = jellyfinService.jellyfinClient;
                        final session = jellyfinService.session;
                        if (client == null || session == null) return;

                        // Recreate if session changed (prevents stale credentials)
                        if (_helmService == null || _helmSessionDeviceId != session.deviceId) {
                          _helmService?.dispose();
                          _helmService = HelmService(
                            client: client,
                            credentials: session.credentials,
                            ownDeviceId: session.deviceId,
                          );
                          _helmSessionDeviceId = session.deviceId;
                        }

                        HelmModeSelector.show(ctx, _helmService!);
                      },
                    );
                  },
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
                icon: const Icon(Icons.logout),
                onPressed: () async {
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
                },
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'No internet connection. Showing downloaded content only.',
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
                    onReorder: (oldIndex, newIndex) {
                      setSheetState(() {
                        if (newIndex > oldIndex) newIndex--;
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
          const SizedBox(height: 16),
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
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
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
              const SizedBox(width: 16),
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

    return NestedScrollView(
      headerSliverBuilder: (context, innerBoxIsScrolled) {
        return [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  SegmentedButton<String>(
                    segments: [
                      const ButtonSegment(
                        value: 'albums',
                        label: Text('Albums'),
                        icon: Icon(Icons.album),
                      ),
                      const ButtonSegment(
                        value: 'artists',
                        label: Text('Artists'),
                        icon: Icon(Icons.person),
                      ),
                      if (!isOffline)
                        const ButtonSegment(
                          value: 'genres',
                          label: Text('Genres'),
                          icon: Icon(Icons.category),
                        ),
                    ],
                    selected: {_selectedView},
                    onSelectionChanged: (Set<String> newSelection) {
                      setState(() {
                        _selectedView = newSelection.first;
                      });
                    },
                  ),
                  // Sort controls for albums and artists (not genres)
                  if (!isOffline && _selectedView != 'genres')
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _SortControls(
                        appState: widget.appState,
                        isAlbums: _selectedView == 'albums',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ];
      },
      body: isOffline ? _buildOfflineContent() : _buildOnlineContent(),
    );
  }

  Widget _buildOfflineContent() {
    final downloads = widget.appState.downloadService.completedDownloads;

    if (_selectedView == 'albums') {
      final Map<String, List<dynamic>> albumsMap = {};
      for (final download in downloads) {
        final albumName = download.track.album ?? 'Unknown Album';
        albumsMap.putIfAbsent(albumName, () => []).add(download);
      }

      final offlineAlbums = albumsMap.entries.map((entry) {
        final firstTrack = entry.value.first.track;
        return JellyfinAlbum(
          id: firstTrack.albumId ?? firstTrack.id, // Fallback to track ID if album ID missing
          name: entry.key,
          artists: [firstTrack.displayArtist],
          artistIds: const [], // IDs might not be available offline
          primaryImageTag: firstTrack.albumPrimaryImageTag,
        );
      }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

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

      final offlineArtists = artistsMap.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

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

// ignore: unused_element
class _DownloadsTab extends StatelessWidget {
  const _DownloadsTab({required this.appState});

  final NautuneAppState appState;

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: appState.downloadService,
      builder: (context, _) {
        final downloads = appState.downloadService.downloads;
        final completedCount = appState.downloadService.completedCount;
        final activeCount = appState.downloadService.activeCount;

        if (downloads.isEmpty) {
          return RefreshIndicator(
            onRefresh: () async {
              // Trigger a refresh check
              await Future.delayed(const Duration(milliseconds: 100));
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height - 200,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.download_outlined,
                            size: 64, color: theme.colorScheme.secondary),
                        const SizedBox(height: 16),
                        Text(
                          'No Downloads',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            'Download albums and tracks for offline listening',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            final totalSize =
                await appState.downloadService.getTotalDownloadSize();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Total: $completedCount downloaded (${_formatFileSize(totalSize)})'),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          },
          child: Column(
            children: [
              if (activeCount > 0 || completedCount > 0)
                Container(
                  padding: const EdgeInsets.all(16),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '$completedCount completed • $activeCount active',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (completedCount > 0)
                        TextButton.icon(
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Clear All Downloads'),
                                content: Text(
                                    'Delete all $completedCount downloaded tracks?'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(true),
                                    child: const Text('Delete All'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await appState.downloadService
                                  .clearAllDownloads();
                            }
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Clear All'),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
                  itemCount: downloads.length,
                  itemBuilder: (context, index) {
                    final download = downloads[index];
                    final track = download.track;

                    return ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: theme.colorScheme.primaryContainer,
                        ),
                        child: Center(
                          child: download.isCompleted
                              ? Icon(Icons.check_circle,
                                  color: theme.colorScheme.primary)
                              : download.isDownloading
                                  ? SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: CircularProgressIndicator(
                                        value: download.progress,
                                        strokeWidth: 3,
                                        color: theme.colorScheme.primary,
                                      ),
                                    )
                                  : download.isFailed
                                      ? Icon(Icons.error,
                                          color: theme.colorScheme.error)
                                      : Icon(Icons.schedule,
                                          color: theme.colorScheme.onPrimaryContainer),
                        ),
                      ),
                      title: Text(
                        track.name,
                        style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.displayArtist,
                            style: TextStyle(color: theme.colorScheme.tertiary.withValues(alpha: 0.7)),  // Ocean blue
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (download.isDownloading)
                            Text(
                              '${(download.progress * 100).toStringAsFixed(0)}% • ${_formatFileSize(download.downloadedBytes ?? 0)} / ${_formatFileSize(download.totalBytes ?? 0)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            )
                          else if (download.isCompleted && download.totalBytes != null)
                            Text(
                              _formatFileSize(download.totalBytes!),
                              style: theme.textTheme.bodySmall,
                            )
                          else if (download.isFailed)
                            Text(
                              'Download failed',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            )
                          else if (download.isQueued)
                            Text(
                              'Queued...',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (track.duration != null)
                            Text(
                              _formatDuration(track.duration!),
                              style: theme.textTheme.bodySmall,
                            ),
                          const SizedBox(width: 8),
                          if (download.isFailed)
                            IconButton(
                              icon: const Icon(Icons.refresh),
                              onPressed: () => appState.downloadService
                                  .retryDownload(track.id),
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Delete Download'),
                                    content: Text(
                                        'Delete "${track.name}"?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(true),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await appState.downloadService
                                      .deleteDownloadReference(track.id, 'user_initiated_from_downloads_list');
                                }
                              },
                            ),
                        ],
                      ),
                      onTap: download.isCompleted
                          ? () {
                              appState.audioPlayerService.playTrack(
                                track,
                                queueContext: [track],
                              );
                            }
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ignore: unused_element
class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
