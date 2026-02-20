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
import 'playlist_detail_screen.dart';
import 'profile_screen.dart';
import 'recently_played_screen.dart';
import 'settings_screen.dart';

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
    _playlistsScrollController.addListener(_onPlaylistsScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // Get appState with listening enabled for reactive updates
    final currentAppState = Provider.of<NautuneAppState>(context, listen: true);
    
    if (!_hasInitialized) {
      _appState = currentAppState;
      _previousOfflineMode = currentAppState.isOfflineMode;
      _previousNetworkAvailable = currentAppState.networkAvailable;
      _hasInitialized = true;
      _tabOrder = List<int>.from(currentAppState.navTabOrder);

      // Restore saved tab index after build completes
      final savedTabIndex = currentAppState.initialLibraryTabIndex;
      if (savedTabIndex != _homeTabIndex && savedTabIndex < 5) {
        _currentTabIndex = savedTabIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _tabController.index = savedTabIndex;
          }
        });
      }
    } else {
      _appState = currentAppState;
      final currentOfflineMode = currentAppState.isOfflineMode;
      final currentNetworkAvailable = currentAppState.networkAvailable;
      
      if (_previousOfflineMode != currentOfflineMode ||
          _previousNetworkAvailable != currentNetworkAvailable) {
        debugPrint('🔄 LibraryScreen: Connectivity changed (offline: $_previousOfflineMode -> $currentOfflineMode, network: $_previousNetworkAvailable -> $currentNetworkAvailable)');
        _previousOfflineMode = currentOfflineMode;
        _previousNetworkAvailable = currentNetworkAvailable;
      }
    }
  }

  @override
  void dispose() {
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

  void _onPlaylistsScroll() {
    if (_playlistsScrollController.position.pixels >=
        _playlistsScrollController.position.maxScrollExtent - 200) {
      // Load more playlists when near bottom
      // _appState?.loadMorePlaylists();
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
    
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
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

        // If we're in offline mode or have no network, prioritize showing offline content
        // if (!appState.networkAvailable || 
        //     (appState.isOfflineMode && appState.downloadService.completedCount > 0)) {
        //   // Show offline library directly
        //   return Scaffold( ... );
        // } 
        // Logic removed to maintain UI parity.
        
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
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Pick a library to explore',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ...libraries.map((library) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _LibraryTile(
                        library: library,
                        groupValue: selectedId,
                        onSelect: () => appState.selectLibrary(library),
                      ),
                    )),
              ],
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
                  child: Container(
                    padding: const EdgeInsets.all(8.0),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      Icons.waves,
                      color: appState.isOfflineMode
                          ? theme.colorScheme.primary  // Theme primary when offline
                          : theme.colorScheme.primary.withValues(alpha: 0.7),  // Theme primary (lighter) when online
                      size: 28,
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

                        _helmService ??= HelmService(
                          client: client,
                          credentials: session.credentials,
                          ownDeviceId: session.deviceId,
                        );

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
      },
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
            Icon(Icons.error, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
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

/// Sort controls for Albums/Artists tabs
class _SortControls extends StatelessWidget {
  const _SortControls({
    required this.appState,
    required this.isAlbums,
  });

  final NautuneAppState appState;
  final bool isAlbums;

  String _sortOptionLabel(SortOption option) {
    switch (option) {
      case SortOption.name:
        return 'Name';
      case SortOption.dateAdded:
        return 'Date Added';
      case SortOption.year:
        return 'Year';
      case SortOption.playCount:
        return 'Play Count';
    }
  }

  IconData _sortOptionIcon(SortOption option) {
    switch (option) {
      case SortOption.name:
        return Icons.sort_by_alpha;
      case SortOption.dateAdded:
        return Icons.calendar_today;
      case SortOption.year:
        return Icons.date_range;
      case SortOption.playCount:
        return Icons.play_circle_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentSort = isAlbums ? appState.albumSortBy : appState.artistSortBy;
    final currentOrder = isAlbums ? appState.albumSortOrder : appState.artistSortOrder;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Sort by dropdown - icon only
        PopupMenuButton<SortOption>(
          initialValue: currentSort,
          tooltip: 'Sort by ${_sortOptionLabel(currentSort)}',
          onSelected: (SortOption option) {
            if (isAlbums) {
              appState.setAlbumSort(option, currentOrder);
            } else {
              appState.setArtistSort(option, currentOrder);
            }
          },
          itemBuilder: (context) => [
            _buildMenuItem(SortOption.name, currentSort),
            _buildMenuItem(SortOption.dateAdded, currentSort),
            if (isAlbums) _buildMenuItem(SortOption.year, currentSort),
            _buildMenuItem(SortOption.playCount, currentSort),
          ],
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              _sortOptionIcon(currentSort),
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Sort order toggle
        IconButton(
          icon: Icon(
            currentOrder == SortOrder.ascending
                ? Icons.arrow_upward
                : Icons.arrow_downward,
            size: 20,
          ),
          tooltip: currentOrder == SortOrder.ascending ? 'Ascending' : 'Descending',
          onPressed: () {
            final newOrder = currentOrder == SortOrder.ascending
                ? SortOrder.descending
                : SortOrder.ascending;
            if (isAlbums) {
              appState.setAlbumSort(currentSort, newOrder);
            } else {
              appState.setArtistSort(currentSort, newOrder);
            }
          },
          style: IconButton.styleFrom(
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  PopupMenuItem<SortOption> _buildMenuItem(SortOption option, SortOption current) {
    return PopupMenuItem<SortOption>(
      value: option,
      child: Row(
        children: [
          if (option == current)
            const Icon(Icons.check, size: 18)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(_sortOptionLabel(option)),
        ],
      ),
    );
  }
}

class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({
    required this.albums,
    required this.isLoading,
    required this.isLoadingMore,
    required this.error,
    required this.scrollController,
    required this.onRefresh,
    required this.onAlbumTap,
    required this.appState,
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController scrollController;
  final VoidCallback onRefresh;
  final Function(JellyfinAlbum) onAlbumTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text('Failed to load albums'),
            const SizedBox(height: 8),
            ElevatedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }
    if (isLoading && (albums == null || albums!.isEmpty)) return const Center(child: CircularProgressIndicator());
    if (albums == null || albums!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album, size: 64, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            const Text('No albums found'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;
          final useListMode = uiState.useListMode;

          // List mode rendering
          if (useListMode) {
            // Only show section headers when sorted by name
            final showHeaders = appState.albumSortBy == SortOption.name;
            final letterGroups = showHeaders
                ? AlphabetSectionBuilder.groupByLetter<JellyfinAlbum>(
                    albums!,
                    (album) => album.name,
                    appState.albumSortOrder,
                  )
                : <(String, List<JellyfinAlbum>)>[];

            return Stack(
              children: [
                CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: showHeaders
                          ? SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  // Calculate which group and item we're at
                                  int currentIndex = 0;
                                  for (final (letter, items) in letterGroups) {
                                    // Header
                                    if (index == currentIndex) {
                                      return _AlphabetSectionHeader(letter: letter);
                                    }
                                    currentIndex++;
                                    // Items in this group
                                    if (index < currentIndex + items.length) {
                                      final album = items[index - currentIndex];
                                      return _AlbumListTile(
                                        album: album,
                                        onTap: () => onAlbumTap(album),
                                        appState: appState,
                                      );
                                    }
                                    currentIndex += items.length;
                                  }
                                  // Loading indicator
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                },
                                childCount: letterGroups.fold(0, (sum, g) => sum + 1 + g.$2.length) + (isLoadingMore ? 1 : 0),
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= albums!.length) {
                                    return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                  }
                                  final album = albums![index];
                                  return _AlbumListTile(
                                    album: album,
                                    onTap: () => onAlbumTap(album),
                                    appState: appState,
                                  );
                                },
                                childCount: albums!.length + (isLoadingMore ? 1 : 0),
                              ),
                            ),
                    ),
                  ],
                ),
                AlphabetScrollbar(
                  items: albums!,
                  getItemName: (album) => (album as JellyfinAlbum).name,
                  scrollController: scrollController,
                  itemHeight: 72, // List tile height
                  crossAxisCount: 1,
                  sortOrder: appState.albumSortOrder,
                  sortBy: appState.albumSortBy,
                ),
              ],
            );
          }

          // Grid mode rendering
          final showGridHeaders = appState.albumSortBy == SortOption.name;
          final gridLetterGroups = showGridHeaders
              ? AlphabetSectionBuilder.groupByLetter<JellyfinAlbum>(
                  albums!,
                  (album) => album.name,
                  appState.albumSortOrder,
                )
              : <(String, List<JellyfinAlbum>)>[];
          final itemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 16) / crossAxisCount) / 0.75 + 16;

          return Stack(
            children: [
              CustomScrollView(
                controller: scrollController,
                slivers: showGridHeaders
                    ? [
                        // Build alternating headers and grids for each letter group
                        for (final (letter, items) in gridLetterGroups) ...[
                          SliverToBoxAdapter(
                            child: _AlphabetSectionHeader(letter: letter),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            sliver: SliverGrid(
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 0.7,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= items.length) return null;
                                  final album = items[index];
                                  return _AlbumCard(
                                    album: album,
                                    onTap: () => onAlbumTap(album),
                                    appState: appState,
                                  );
                                },
                                childCount: items.length,
                              ),
                            ),
                          ),
                        ],
                        if (isLoadingMore)
                          const SliverToBoxAdapter(
                            child: Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator())),
                          ),
                      ]
                    : [
                        // Original single grid without headers
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 0.7,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index >= albums!.length) {
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                }
                                final album = albums![index];
                                return _AlbumCard(
                                  album: album,
                                  onTap: () => onAlbumTap(album),
                                  appState: appState,
                                );
                              },
                              childCount: albums!.length + (isLoadingMore ? 2 : 0),
                            ),
                          ),
                        ),
                      ],
              ),
              AlphabetScrollbar(
                items: albums!,
                getItemName: (album) => (album as JellyfinAlbum).name,
                scrollController: scrollController,
                itemHeight: itemHeight,
                crossAxisCount: crossAxisCount,
                sortOrder: appState.albumSortOrder,
                sortBy: appState.albumSortBy,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AlbumListTile extends StatelessWidget {
  const _AlbumListTile({required this.album, required this.onTap, required this.appState});
  final JellyfinAlbum album;
  final VoidCallback onTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('Add to Playlist'),
                  onTap: () async {
                    Navigator.pop(context);
                    await showAddToPlaylistDialog(
                      context: context,
                      appState: appState,
                      album: album,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 56,
          height: 56,
          child: album.primaryImageTag != null
              ? JellyfinImage(
                  itemId: album.id,
                  imageTag: album.primaryImageTag,
                  boxFit: BoxFit.cover,
                  errorBuilder: (context, url, error) => Image.asset(
                    'assets/no_album_art.png',
                    fit: BoxFit.cover,
                  ),
                )
              : Image.asset(
                  'assets/no_album_art.png',
                  fit: BoxFit.cover,
                ),
        ),
      ),
      title: Text(
        album.name,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.tertiary,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: album.artists.isNotEmpty
          ? Text(
              album.displayArtist,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
    );
  }
}

class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({
    required this.title,
    this.subtitle,
    required this.onRefresh,
    required this.isLoading,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onRefresh;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isLoading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (isLoading) const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

class _ContinueListeningShelf extends StatelessWidget {
  const _ContinueListeningShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Continue Listening',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Nothing waiting for you yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _TrackChip extends StatelessWidget {
  const _TrackChip({required this.track, required this.onTap});

  final JellyfinTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 240,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: (track.albumId != null && track.albumPrimaryImageTag != null)
                    ? JellyfinImage(
                        itemId: track.albumId!,
                        imageTag: track.albumPrimaryImageTag,
                        maxWidth: 300,
                        boxFit: BoxFit.cover,
                        errorBuilder: (context, url, error) => Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
                      )
                    : Image.asset(
                        'assets/no_album_art.png',
                        fit: BoxFit.cover,
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        track.displayArtist,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentlyAddedShelf extends StatelessWidget {
  const _RecentlyAddedShelf({
    required this.albums,
    required this.isLoading,
    required this.appState,
    required this.onAlbumTap,
    required this.onRefresh,
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
  final NautuneAppState appState;
  final void Function(JellyfinAlbum) onAlbumTap;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = albums != null && albums!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Recently Added',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 240,
          child: !hasData && isLoading
              ? const SkeletonAlbumShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: albums!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final album = albums![index];
                        return _MiniAlbumCard(
                          album: album,
                          appState: appState,
                          onTap: () => onAlbumTap(album),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No new albums yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _MiniAlbumCard extends StatelessWidget {
  const _MiniAlbumCard({
    required this.album,
    required this.appState,
    required this.onTap,
  });

  final JellyfinAlbum album;
  final NautuneAppState appState;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 150,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: album.primaryImageTag != null
                      ? JellyfinImage(
                          itemId: album.id,
                          imageTag: album.primaryImageTag,
                          maxWidth: 400,
                          boxFit: BoxFit.cover,
                          errorBuilder: (context, url, error) => Image.asset(
                            'assets/no_album_art.png',
                            fit: BoxFit.cover,
                          ),
                        )
                      : Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      album.displayArtist,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap, required this.appState});
  final JellyfinAlbum album;
  final VoidCallback onTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('Add to Playlist'),
                    onTap: () async {
                      Navigator.pop(context);
                      await showAddToPlaylistDialog(
                        context: context,
                        appState: appState,
                        album: album,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: album.primaryImageTag != null
                    ? JellyfinImage(
                        itemId: album.id,
                        imageTag: album.primaryImageTag,
                        boxFit: BoxFit.cover,
                        errorBuilder: (context, url, error) => Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
                      )
                    : Image.asset(
                        'assets/no_album_art.png',
                        fit: BoxFit.cover,
                      ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        album.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.tertiary,  // Ocean blue
                          height: 1.15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (album.artists.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        album.displayArtist,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue slightly transparent
                          height: 1.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentlyPlayedShelf extends StatelessWidget {
  const _RecentlyPlayedShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
    required this.appState,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ShelfHeader(
                title: 'Recently Played',
                onRefresh: onRefresh,
                isLoading: isLoading,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 16),
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecentlyPlayedScreen(appState: appState),
                    ),
                  );
                },
                child: Text(
                  'View All',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No recently played tracks.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _DiscoverShelf extends StatelessWidget {
  const _DiscoverShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Discover',
          subtitle: 'Albums you rarely play',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No tracks to discover yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _RecommendationsShelf extends StatelessWidget {
  const _RecommendationsShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
    this.seedTrackName,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;
  final String? seedTrackName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;
    final subtitle = seedTrackName != null
        ? 'Based on "$seedTrackName"'
        : 'Based on your listening';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'For You',
          subtitle: subtitle,
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Play some music to get recommendations.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

/// ListenBrainz Discovery shelf - shows personalized recommendations from ListenBrainz
class _ListenBrainzDiscoveryShelf extends StatefulWidget {
  const _ListenBrainzDiscoveryShelf({
    required this.appState,
  });

  final NautuneAppState appState;

  @override
  State<_ListenBrainzDiscoveryShelf> createState() => _ListenBrainzDiscoveryShelfState();
}

class _ListenBrainzDiscoveryShelfState extends State<_ListenBrainzDiscoveryShelf> {
  List<ListenBrainzRecommendation>? _recommendations;
  List<JellyfinTrack>? _matchedTracks;
  bool _isLoading = false;
  bool _hasChecked = false;

  @override
  void initState() {
    super.initState();
    _loadRecommendations();
  }

  Future<void> _loadRecommendations() async {
    debugPrint('🎵 ListenBrainz Discovery: Starting to load recommendations...');
    final listenBrainz = ListenBrainzService();

    // Wait for ListenBrainz to initialize if not ready yet (max 3 seconds)
    if (!listenBrainz.isInitialized) {
      debugPrint('🎵 ListenBrainz Discovery: Waiting for service to initialize...');
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (listenBrainz.isInitialized) break;
      }
    }

    // Only show if user has connected and enabled scrobbling
    if (!listenBrainz.isConfigured) {
      debugPrint('🎵 ListenBrainz Discovery: Not configured, skipping');
      if (mounted) setState(() => _hasChecked = true);
      return;
    }
    if (!listenBrainz.isScrobblingEnabled) {
      debugPrint('🎵 ListenBrainz Discovery: Scrobbling disabled, skipping');
      if (mounted) setState(() => _hasChecked = true);
      return;
    }
    debugPrint('🎵 ListenBrainz Discovery: User ${listenBrainz.username} is configured, fetching...');

    if (mounted) setState(() => _isLoading = true);

    try {
      // Use efficient batch matching - stops early when we have enough matches
      final libraryId = widget.appState.selectedLibraryId;
      if (libraryId == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasChecked = true;
          });
        }
        return;
      }

      final matched = await listenBrainz.getDiscoveryRecommendations(
        jellyfin: widget.appState.jellyfinService,
        libraryId: libraryId,
        targetMatches: 20,
        maxFetch: 50,
      );

      debugPrint('🎵 ListenBrainz Discovery: Got ${matched.length} recommendations (${matched.where((r) => r.isInLibrary).length} in library)');

      if (!mounted) return;

      if (matched.isEmpty) {
        debugPrint('🎵 ListenBrainz Discovery: No recommendations returned from API');
        setState(() {
          _recommendations = [];
          _matchedTracks = [];
          _isLoading = false;
          _hasChecked = true;
        });
        return;
      }

      // Get tracks that are in library
      final inLibraryRecs = matched.where((r) => r.isInLibrary).toList();
      final tracks = <JellyfinTrack>[];

      for (final rec in inLibraryRecs.take(20)) {
        if (rec.jellyfinTrackId != null) {
          try {
            final track = await widget.appState.jellyfinService.getTrack(rec.jellyfinTrackId!);
            if (track != null) {
              tracks.add(track);
            }
          } catch (e) {
            // Skip failed track fetches
          }
        }
      }

      if (!mounted) return;

      setState(() {
        _recommendations = matched;
        _matchedTracks = tracks;
        _isLoading = false;
        _hasChecked = true;
      });
    } catch (e) {
      debugPrint('ListenBrainz discovery error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasChecked = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listenBrainz = ListenBrainzService();

    // Don't show if not connected or scrobbling is disabled
    if ((!listenBrainz.isConfigured || !listenBrainz.isScrobblingEnabled) && _hasChecked) {
      return const SizedBox.shrink();
    }

    // Get recommendations NOT in library (for discovery section)
    // Only show LB Radio and Fresh Release items — CF recommendations are
    // excluded because unmatched CF results are usually false negatives
    // (library tracks that failed fuzzy matching), not true discoveries.
    final notInLibraryRecs = _recommendations
        ?.where((r) => !r.isInLibrary && r.artistName != null &&
            (r.trackName != null || r.albumName != null) &&
            r.source != RecommendationSource.cfRecommendation)
        .take(10)
        .toList() ?? [];

    final hasMatchedData = _matchedTracks != null && _matchedTracks!.isNotEmpty;
    final hasDiscoveryData = notInLibraryRecs.isNotEmpty;

    // Don't show if no recommendations at all
    if (_hasChecked && !hasMatchedData && !hasDiscoveryData) {
      return const SizedBox.shrink();
    }

    final inLibraryCount = _recommendations?.where((r) => r.isInLibrary).length ?? 0;
    final totalCount = _recommendations?.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ListenBrainz Mix - tracks in your library
        if (hasMatchedData || _isLoading) ...[
          _ShelfHeader(
            title: 'ListenBrainz Mix',
            subtitle: '$inLibraryCount of $totalCount in your library',
            onRefresh: _loadRecommendations,
            isLoading: _isLoading,
          ),
          SizedBox(
            height: 140,
            child: !hasMatchedData && _isLoading
                ? const SkeletonTrackShelf()
                : hasMatchedData
                    ? ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _matchedTracks!.length,
                        separatorBuilder: (context, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final track = _matchedTracks![index];
                          return _TrackChip(
                            track: track,
                            onTap: () {
                              widget.appState.audioPlayerService.playTrack(
                                track,
                                queueContext: _matchedTracks!,
                              );
                            },
                          );
                        },
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Getting recommendations from ListenBrainz...',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
          ),
          const SizedBox(height: 20),
        ],

        // Discover New Music - tracks NOT in your library
        if (hasDiscoveryData) ...[
          _ShelfHeader(
            title: 'Discover New Music',
            subtitle: 'Based on your ListenBrainz history',
            onRefresh: _loadRecommendations,
            isLoading: _isLoading,
          ),
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: notInLibraryRecs.length,
              separatorBuilder: (context, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final rec = notInLibraryRecs[index];
                return _DiscoveryChip(
                  trackName: rec.trackName,
                  artistName: rec.artistName!,
                  albumName: rec.albumName,
                  coverArtUrl: rec.coverArtUrl,
                  source: rec.source,
                );
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

/// Chip for discovery recommendations (tracks not in library)
class _DiscoveryChip extends StatelessWidget {
  const _DiscoveryChip({
    this.trackName,
    required this.artistName,
    this.albumName,
    this.coverArtUrl,
    this.source = RecommendationSource.cfRecommendation,
  });

  final String? trackName;
  final String artistName;
  final String? albumName;
  final String? coverArtUrl;
  final RecommendationSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFreshRelease = source == RecommendationSource.freshRelease;
    final badgeIcon = isFreshRelease ? Icons.new_releases : Icons.explore;
    final badgeText = isFreshRelease ? 'New Release' : 'Discover';
    final displayName = trackName ?? albumName ?? 'Unknown';

    return SizedBox(
      width: 200,
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            // Album art from Cover Art Archive
            if (coverArtUrl != null)
              SizedBox(
                width: 80,
                height: 100,
                child: CachedNetworkImage(
                  imageUrl: coverArtUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (context, url, error) => Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.album,
                      size: 32,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: 80,
                height: 100,
                color: theme.colorScheme.surfaceContainerHigh,
                child: Icon(
                  Icons.album,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            // Track info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          badgeIcon,
                          size: 12,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            badgeText,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayName,
                      style: theme.textTheme.titleSmall?.copyWith(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      artistName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnThisDayShelf extends StatelessWidget {
  const _OnThisDayShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;
    final now = DateTime.now();
    final dayOrdinal = _ordinal(now.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'On This Day',
          subtitle: 'Tracks you played on the $dayOrdinal',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No listening history for this date.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }

  String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1: return '${day}st';
      case 2: return '${day}nd';
      case 3: return '${day}rd';
      default: return '${day}th';
    }
  }
}

class _PlaylistsTab extends StatefulWidget {
  const _PlaylistsTab({
    required this.playlists,
    required this.isLoading,
    required this.error,
    required this.scrollController,
    required this.onRefresh,
    required this.appState,
  });

  final List<JellyfinPlaylist>? playlists;
  final bool isLoading;
  final Object? error;
  final ScrollController scrollController;
  final VoidCallback onRefresh;
  final NautuneAppState appState;

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  Mood? _loadingMood;

  @override
  void initState() {
    super.initState();
    // Refresh available SyncPlay groups when entering the tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<SyncPlayProvider>().refreshGroups();
      }
    });
  }

  // Convenience getters
  List<JellyfinPlaylist>? get playlists => widget.playlists;
  bool get isLoading => widget.isLoading;
  Object? get error => widget.error;
  ScrollController get scrollController => widget.scrollController;
  VoidCallback get onRefresh => widget.onRefresh;
  NautuneAppState get appState => widget.appState;

  Future<void> _playMoodMix(Mood mood) async {
    if (_loadingMood != null) return; // Already loading

    setState(() => _loadingMood = mood);

    try {
      final libraryId = appState.selectedLibraryId;
      if (libraryId == null) {
        throw StateError('No library selected');
      }

      final service = SmartPlaylistService(
        jellyfinService: appState.jellyfinService,
        libraryId: libraryId,
      );

      final tracks = await service.generateMoodMix(mood, limit: 50);

      if (tracks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No ${mood.displayName.toLowerCase()} tracks found'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        // Play the mood mix
        appState.audioService.playTrack(
          tracks.first,
          queueContext: tracks,
          fromShuffle: true,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Playing ${mood.displayName} Mix - ${tracks.length} tracks'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Smart Mix error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate mix: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMood = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text('Failed to load playlists'),
            const SizedBox(height: 8),
            ElevatedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }
    if (isLoading && (playlists == null || playlists!.isEmpty)) return const Center(child: CircularProgressIndicator());
    if (playlists == null || playlists!.isEmpty) {
      final theme = Theme.of(context);
      return RefreshIndicator(
        onRefresh: () async => onRefresh(),
        child: CustomScrollView(
          slivers: [
            // Active Collab Session Card (if in session and online)
            SliverToBoxAdapter(
              child: Consumer<SyncPlayProvider>(
                builder: (context, syncPlay, _) {
                  if (!syncPlay.isInSession || appState.isOfflineMode) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      color: theme.colorScheme.primaryContainer,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const CollabPlaylistScreen(),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.group,
                                  color: theme.colorScheme.onPrimary,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Active Collab Session',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      syncPlay.groupName ?? 'Fleet Mode',
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${syncPlay.participants.length} listeners • ${syncPlay.queue.length} tracks',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Available Collab Sessions (Empty State)
            SliverToBoxAdapter(
              child: Consumer<SyncPlayProvider>(
                builder: (context, syncPlay, _) {
                  if (syncPlay.isInSession || syncPlay.availableGroups.isEmpty || appState.isOfflineMode) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Join a Session',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...syncPlay.availableGroups.map((group) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.group_add,
                                color: theme.colorScheme.onSecondaryContainer,
                                size: 20,
                              ),
                            ),
                            title: Text(group.groupName),
                            subtitle: Text('${group.participantCount} active listeners'),
                            trailing: FilledButton.tonal(
                              onPressed: () async {
                                try {
                                  await syncPlay.joinCollabPlaylist(group.groupId);
                                  if (context.mounted) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => const CollabPlaylistScreen(),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to join: $e')),
                                    );
                                  }
                                }
                              },
                              child: const Text('Join'),
                            ),
                          ),
                        )),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Empty state content
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.playlist_play, size: 64, color: Colors.grey.shade600),
                    const SizedBox(height: 16),
                    const Text('No playlists found'),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await _showCreatePlaylistDialog(context);
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Create Playlist'),
                    ),
                    const SizedBox(height: 12),
                    if (!appState.isOfflineMode)
                      OutlinedButton.icon(
                        onPressed: () {
                          _showCreateCollabPlaylistDialog(context);
                        },
                        icon: const Icon(Icons.group_add),
                        label: const Text('Create Fleet'),
                      ),
                    if (!appState.isOfflineMode)
                      const SizedBox(height: 12),
                    if (!appState.isOfflineMode)
                      OutlinedButton.icon(
                        onPressed: () {
                          _showJoinCollabPlaylistDialog(context);
                        },
                        icon: const Icon(Icons.link),
                        label: const Text('Join via Link'),
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
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        controller: scrollController,
        cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.all(16),
        itemCount: playlists!.length + (isLoading ? 1 : 0) + 1, // +1 for header button
        itemBuilder: (context, index) {
          // Add header buttons as first items
          if (index == 0) {
            final theme = Theme.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Active Collab Session Card (hidden in offline mode)
                Consumer<SyncPlayProvider>(
                  builder: (context, syncPlay, _) {
                    if (!syncPlay.isInSession || appState.isOfflineMode) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Card(
                        color: theme.colorScheme.primaryContainer,
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const CollabPlaylistScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.group,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Active Collab Session',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        syncPlay.groupName ?? 'Fleet Mode',
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: theme.colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${syncPlay.participants.length} listeners • ${syncPlay.queue.length} tracks',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // Available Collab Sessions
                Consumer<SyncPlayProvider>(
                  builder: (context, syncPlay, _) {
                    if (syncPlay.isInSession || syncPlay.availableGroups.isEmpty || appState.isOfflineMode) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Join a Session',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...syncPlay.availableGroups.map((group) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.group_add,
                                color: theme.colorScheme.onSecondaryContainer,
                                size: 20,
                              ),
                            ),
                            title: Text(group.groupName),
                            subtitle: Text('${group.participantCount} active listeners'),
                            trailing: FilledButton.tonal(
                              onPressed: () async {
                                try {
                                  await syncPlay.joinCollabPlaylist(group.groupId);
                                  if (context.mounted) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => const CollabPlaylistScreen(),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to join: $e')),
                                    );
                                  }
                                }
                              },
                              child: const Text('Join'),
                            ),
                          ),
                        )),
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                ),

                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await _showCreatePlaylistDialog(context);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create New Playlist'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
                if (!appState.isOfflineMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showCreateCollabPlaylistDialog(context);
                      },
                      icon: const Icon(Icons.group_add),
                      label: const Text('Create Fleet'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        side: BorderSide(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                if (!appState.isOfflineMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showJoinCollabPlaylistDialog(context);
                      },
                      icon: const Icon(Icons.link),
                      label: const Text('Join via Link'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        side: BorderSide(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                // Smart Mix Section
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Smart Mix',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Generate a playlist based on mood',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                // Horizontal 1x4 Mood Cards (compact layout)
                SizedBox(
                  height: 70,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: Mood.values.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) => _buildCompactMoodCard(Mood.values[index], theme),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Text(
                    'Your Playlists',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          }
          
          final listIndex = index - 1;
          if (listIndex >= playlists!.length) {
            return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
          }
          final playlist = playlists![listIndex];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(Icons.playlist_play, color: Theme.of(context).colorScheme.secondary),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PlaylistDetailScreen(
                      playlist: playlist,
                    ),
                  ),
                );
              },
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'edit') {
                    _showEditPlaylistDialog(context, playlist);
                  } else if (value == 'delete') {
                    _showDeletePlaylistDialog(context, playlist);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit),
                        SizedBox(width: 8),
                        Text('Edit'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Delete', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Compact mood card for horizontal 1x4 layout
  Widget _buildCompactMoodCard(Mood mood, ThemeData theme) {
    final isLoading = _loadingMood == mood;
    final gradientColors = _getMoodGradient(mood, theme);
    // Extract first genre from subtitle (e.g., "Jazz" from "Jazz, Blues, Ambient...")
    final firstGenre = mood.subtitle.split(',').first.trim();

    return SizedBox(
      width: 100,
      child: Material(
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isLoading ? null : () => _playMoodMix(mood),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        mood.displayName,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isLoading)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  firstGenre,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Color> _getMoodGradient(Mood mood, ThemeData theme) {
    switch (mood) {
      case Mood.chill:
        return [
          const Color(0xFF1A237E), // Deep blue
          const Color(0xFF4FC3F7), // Light blue
        ];
      case Mood.energetic:
        return [
          const Color(0xFFE65100), // Deep orange
          const Color(0xFFFFD54F), // Amber
        ];
      case Mood.melancholy:
        return [
          const Color(0xFF4A148C), // Deep purple
          const Color(0xFF9575CD), // Light purple
        ];
      case Mood.upbeat:
        return [
          const Color(0xFFC2185B), // Pink
          const Color(0xFFFFAB91), // Light coral
        ];
    }
  }

  Future<void> _showCreatePlaylistDialog(BuildContext context) async {
    final nameController = TextEditingController();
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Playlist'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Playlist Name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty && context.mounted) {
      try {
        await appState.createPlaylist(name: nameController.text);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Created playlist "${nameController.text}"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create playlist: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showCreateCollabPlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const CreateCollabDialog(),
    );
  }

  void _showJoinCollabPlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const JoinCollabDialog(),
    );
  }

  void _showEditPlaylistDialog(BuildContext context, JellyfinPlaylist playlist) async {
    final nameController = TextEditingController(text: playlist.name);
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Playlist'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Playlist Name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty && context.mounted) {
      try {
        await appState.updatePlaylist(
          playlistId: playlist.id,
          newName: nameController.text,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Renamed to "${nameController.text}"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to rename: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  void _showDeletePlaylistDialog(BuildContext context, JellyfinPlaylist playlist) async {
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      try {
        await appState.deletePlaylist(playlist.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "${playlist.name}"'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}

class _FavoritesTab extends StatelessWidget {
  const _FavoritesTab({
    required this.recentTracks,
    required this.isLoading,
    required this.error,
    required this.onRefresh,
    required this.onTrackTap,
    required this.appState,
  });

  final List<JellyfinTrack>? recentTracks;
  final bool isLoading;
  final Object? error;
  final VoidCallback onRefresh;
  final Function(JellyfinTrack) onTrackTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text('Failed to load favorites'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (isLoading && (recentTracks == null || recentTracks!.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (recentTracks == null || recentTracks!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_outline, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'No favorite tracks',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Mark tracks as favorites to see them here',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.all(16),
        itemCount: recentTracks?.length ?? 0,
        itemBuilder: (context, index) {
          if (recentTracks == null || index >= recentTracks!.length) {
            return const SizedBox.shrink();
          }
          final track = recentTracks![index];
          return RepaintBoundary(
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: (track.albumId != null && track.albumPrimaryImageTag != null)
                      ? JellyfinImage(
                          itemId: track.albumId!,
                          imageTag: track.albumPrimaryImageTag,
                          trackId: track.id, // Enable offline artwork support
                          maxWidth: 200,
                          boxFit: BoxFit.cover,
                          placeholderBuilder: (context, url) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.album,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          errorBuilder: (context, url, error) => Image.asset(
                            'assets/no_album_art.png',
                            fit: BoxFit.cover,
                          ),
                        )
                      : Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
                ),
              ),
              title: Text(
                track.name,
                style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
              ),
              subtitle: Text(
                track.displayArtist,
                style: TextStyle(color: theme.colorScheme.tertiary.withValues(alpha: 0.7)),  // Ocean blue
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (track.duration != null)
                    Text(
                      _formatDuration(track.duration!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                      ),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: () {
                      final parentContext = context;
                      showModalBottomSheet(
                        context: parentContext,
                        builder: (sheetContext) {
                          final syncPlay = context.read<SyncPlayProvider>();
                          return SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Add to Fleet (if session active)
                              if (syncPlay.isInSession)
                                ListTile(
                                  leading: Icon(Icons.group_add, color: Theme.of(sheetContext).colorScheme.primary),
                                  title: Text(
                                    'Add to ${syncPlay.groupName ?? "Fleet"}',
                                    style: TextStyle(color: Theme.of(sheetContext).colorScheme.primary),
                                  ),
                                  onTap: () async {
                                    Navigator.pop(sheetContext);
                                    try {
                                      await syncPlay.addTrackToQueue(track);
                                      if (parentContext.mounted) {
                                        ScaffoldMessenger.of(parentContext).showSnackBar(
                                          SnackBar(content: Text('${track.name} added to fleet')),
                                        );
                                      }
                                    } catch (e) {
                                      if (parentContext.mounted) {
                                        ScaffoldMessenger.of(parentContext).showSnackBar(
                                          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ListTile(
                                leading: const Icon(Icons.play_arrow),
                                title: const Text('Play Next'),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  appState.audioPlayerService.playNext([track]);
                                  ScaffoldMessenger.of(parentContext).showSnackBar(
                                    SnackBar(
                                      content: Text('${track.name} will play next'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.queue_music),
                                title: const Text('Add to Queue'),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  appState.audioPlayerService.addToQueue([track]);
                                  ScaffoldMessenger.of(parentContext).showSnackBar(
                                    SnackBar(
                                      content: Text('${track.name} added to queue'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.playlist_add),
                                title: const Text('Add to Playlist'),
                                onTap: () async {
                                  Navigator.pop(sheetContext);
                                  await showAddToPlaylistDialog(
                                    context: parentContext,
                                    appState: appState,
                                    tracks: [track],
                                  );
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.auto_awesome),
                                title: const Text('Instant Mix'),
                                onTap: () async {
                                  Navigator.pop(sheetContext);
                                  try {
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      const SnackBar(
                                        content: Text('Creating instant mix...'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                    final mixTracks = await appState.jellyfinService.getInstantMix(
                                      itemId: track.id,
                                      limit: 50,
                                    );
                                    if (!parentContext.mounted) return;
                                    if (mixTracks.isEmpty) {
                                      ScaffoldMessenger.of(parentContext).showSnackBar(
                                        const SnackBar(
                                          content: Text('No similar tracks found'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                      return;
                                    }
                                    await appState.audioPlayerService.playTrack(
                                      mixTracks.first,
                                      queueContext: mixTracks,
                                    );
                                    if (!parentContext.mounted) return;
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      SnackBar(
                                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } catch (e) {
                                    if (!parentContext.mounted) return;
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to create mix: $e'),
                                        backgroundColor: Theme.of(parentContext).colorScheme.error,
                                      ),
                                    );
                                  }
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.download),
                                title: const Text('Download Track'),
                                onTap: () async {
                                  Navigator.pop(sheetContext);
                                  final messenger = ScaffoldMessenger.of(parentContext);
                                  final theme = Theme.of(parentContext);
                                  final downloadService = appState.downloadService;
                                  try {
                                    final existing = downloadService.getDownload(track.id);
                                    if (existing != null) {
                                      if (existing.isCompleted) {
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('"${track.name}" is already downloaded'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                        return;
                                      }
                                      if (existing.isFailed) {
                                        await downloadService.retryDownload(track.id);
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Retrying download for ${track.name}'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                        return;
                                      }
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('"${track.name}" is already in the download queue'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                      return;
                                    }
                                    await downloadService.downloadTrack(track);
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content: Text('Downloading ${track.name}'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } catch (e) {
                                    messenger.showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to download ${track.name}: $e'),
                                        backgroundColor: theme.colorScheme.error,
                                      ),
                                    );
                                  }
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.share),
                                title: const Text('Share'),
                                onTap: () async {
                                  Navigator.pop(sheetContext);
                                  final messenger = ScaffoldMessenger.of(parentContext);
                                  final theme = Theme.of(parentContext);
                                  final downloadService = appState.downloadService;
                                  final shareService = ShareService.instance;

                                  if (!shareService.isAvailable) {
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('Sharing not available on this platform'),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                    return;
                                  }

                                  final result = await shareService.shareTrack(
                                    track: track,
                                    downloadService: downloadService,
                                  );

                                  if (!parentContext.mounted) return;

                                  switch (result) {
                                    case ShareResult.success:
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('Shared "${track.name}"'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
                                      break;
                                    case ShareResult.cancelled:
                                      break;
                                    case ShareResult.notDownloaded:
                                      final shouldDownload = await showDialog<bool>(
                                        context: parentContext,
                                        builder: (dialogContext) => AlertDialog(
                                          title: const Text('Track Not Downloaded'),
                                          content: Text(
                                            'To share "${track.name}", it needs to be downloaded first. '
                                            'Would you like to download it now?'
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () => Navigator.pop(dialogContext, false),
                                              child: const Text('Cancel'),
                                            ),
                                            FilledButton(
                                              onPressed: () => Navigator.pop(dialogContext, true),
                                              child: const Text('Download'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (shouldDownload == true && parentContext.mounted) {
                                        await downloadService.downloadTrack(track);
                                        messenger.showSnackBar(
                                          SnackBar(
                                            content: Text('Downloading "${track.name}"...'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                      break;
                                    case ShareResult.fileNotFound:
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('File for "${track.name}" not found'),
                                          backgroundColor: theme.colorScheme.error,
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                      break;
                                    case ShareResult.error:
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text('Failed to share "${track.name}"'),
                                          backgroundColor: theme.colorScheme.error,
                                          duration: const Duration(seconds: 3),
                                        ),
                                      );
                                      break;
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                        },
                      );
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              onTap: () => onTrackTap(track),
            ),
          ));
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }
}

// Most Tab with toggles for different views
class _MostPlayedTab extends StatefulWidget {
  const _MostPlayedTab({
    required this.appState,
    required this.onAlbumTap,
  });

  final NautuneAppState appState;
  final Function(JellyfinAlbum) onAlbumTap;

  @override
  State<_MostPlayedTab> createState() => _MostPlayedTabState();
}

class _MostPlayedTabState extends State<_MostPlayedTab> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heroShelves = _buildHomeHeroShelves();

    return _buildContent(theme, heroShelves);
  }

  Widget _buildContent(ThemeData theme, Widget? heroShelves) {
    if (heroShelves == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.music_note,
                size: 64,
                color: theme.colorScheme.secondary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No content available',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Start playing some music to see recommendations here',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return _buildScrollableState(
      [heroShelves],
      null,
      applyBodyPadding: false,
    );
  }

  Widget _buildScrollableState(
    List<Widget> header,
    Widget? body, {
    bool applyBodyPadding = true,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        ...header,
        if (body != null)
          if (applyBodyPadding)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: body,
            )
          else
            body,
        const SizedBox(height: 16),
      ],
    );
  }

  Widget? _buildHomeHeroShelves() {
    if (widget.appState.isOfflineMode) {
      return null;
    }

    final continueTracks = widget.appState.recentTracks;
    final continueLoading = widget.appState.isLoadingRecent;
    final recentlyPlayed = widget.appState.recentlyPlayedTracks;
    final recentlyPlayedLoading = widget.appState.isLoadingRecentlyPlayed;
    final recentlyAdded = widget.appState.recentlyAddedAlbums;
    final recentlyAddedLoading = widget.appState.isLoadingRecentlyAdded;
    final discoverTracks = widget.appState.discoverTracks;
    final discoverLoading = widget.appState.isLoadingDiscover;
    final onThisDayTracks = widget.appState.onThisDayTracks;
    final onThisDayLoading = widget.appState.isLoadingOnThisDay;
    final recommendationTracks = widget.appState.recommendationTracks;
    final recommendationLoading = widget.appState.isLoadingRecommendations;
    final recommendationSeedName = widget.appState.recommendationSeedTrackName;

    final showContinue = continueLoading || (continueTracks != null && continueTracks.isNotEmpty);
    final showRecentlyPlayed = recentlyPlayedLoading || (recentlyPlayed != null && recentlyPlayed.isNotEmpty);
    final showRecentlyAdded = recentlyAddedLoading || (recentlyAdded != null && recentlyAdded.isNotEmpty);
    final showDiscover = discoverLoading || (discoverTracks != null && discoverTracks.isNotEmpty);
    final showOnThisDay = onThisDayLoading || (onThisDayTracks != null && onThisDayTracks.isNotEmpty);
    final showRecommendations = recommendationLoading || (recommendationTracks != null && recommendationTracks.isNotEmpty);

    if (!showContinue && !showRecentlyPlayed && !showRecentlyAdded && !showDiscover && !showOnThisDay && !showRecommendations) {
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        if (showContinue) ...[
          _ContinueListeningShelf(
            tracks: continueTracks,
            isLoading: continueLoading,
            onPlay: (track) {
              final queue = continueTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecent(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecentlyPlayed) ...[
          _RecentlyPlayedShelf(
            tracks: recentlyPlayed,
            isLoading: recentlyPlayedLoading,
            appState: widget.appState,
            onPlay: (track) {
              final queue = recentlyPlayed ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecentlyPlayed(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecentlyAdded) ...[
          _RecentlyAddedShelf(
            albums: recentlyAdded,
            isLoading: recentlyAddedLoading,
            appState: widget.appState,
            onAlbumTap: widget.onAlbumTap,
            onRefresh: () => widget.appState.refreshRecentlyAdded(),
          ),
          const SizedBox(height: 20),
        ],
        if (showDiscover) ...[
          _DiscoverShelf(
            tracks: discoverTracks,
            isLoading: discoverLoading,
            onPlay: (track) {
              final queue = discoverTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshDiscover(),
          ),
          const SizedBox(height: 20),
        ],
        if (showOnThisDay) ...[
          _OnThisDayShelf(
            tracks: onThisDayTracks,
            isLoading: onThisDayLoading,
            onPlay: (track) {
              final queue = onThisDayTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshOnThisDay(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecommendations) ...[
          _RecommendationsShelf(
            tracks: recommendationTracks,
            isLoading: recommendationLoading,
            seedTrackName: recommendationSeedName,
            onPlay: (track) {
              final queue = recommendationTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecommendations(),
          ),
          const SizedBox(height: 20),
        ],
        // ListenBrainz Discovery - only show if connected
        _ListenBrainzDiscoveryShelf(
          appState: widget.appState,
        ),
      ],
    );
  }
}

class _RecentTab extends StatefulWidget {
  const _RecentTab({
    required this.appState,
  });

  final NautuneAppState appState;

  @override
  State<_RecentTab> createState() => _RecentTabState();
}

class _RecentTabState extends State<_RecentTab> {
  bool _showRecentlyPlayed = true;
  List<JellyfinTrack>? _recentlyPlayedTracks;
  List<JellyfinAlbum>? _recentlyAddedAlbums;
  bool _isLoadingPlayed = false;
  bool _isLoadingAdded = false;

  @override
  void initState() {
    super.initState();
    _loadRecentlyPlayed();
    _loadRecentlyAdded();
  }

  Future<void> _loadRecentlyPlayed() async {
    final libraryId = widget.appState.selectedLibraryId;
    if (libraryId == null) return;

    setState(() => _isLoadingPlayed = true);
    try {
      final tracks = await widget.appState.jellyfinService.loadRecentlyPlayedTracks(
        libraryId: libraryId,
        limit: 50,
      );
      if (mounted) {
        setState(() {
          _recentlyPlayedTracks = tracks;
          _isLoadingPlayed = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPlayed = false);
      }
    }
  }

  Future<void> _loadRecentlyAdded() async {
    final libraryId = widget.appState.selectedLibraryId;
    if (libraryId == null) return;

    setState(() => _isLoadingAdded = true);
    try {
      final albums = await widget.appState.jellyfinService.loadRecentlyAddedAlbums(
        libraryId: libraryId,
        limit: 20,
      );
      if (mounted) {
        setState(() {
          _recentlyAddedAlbums = albums;
          _isLoadingAdded = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingAdded = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text('Played', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.history, size: 18),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text('Added', style: TextStyle(fontSize: 13)),
                      icon: Icon(Icons.new_releases, size: 18),
                    ),
                  ],
                  selected: {_showRecentlyPlayed},
                  onSelectionChanged: (Set<bool> newSelection) {
                    setState(() {
                      _showRecentlyPlayed = newSelection.first;
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _showRecentlyPlayed
              ? _buildRecentlyPlayed(theme, _recentlyPlayedTracks, _isLoadingPlayed)
              : _buildRecentlyAdded(theme, _recentlyAddedAlbums, _isLoadingAdded),
        ),
      ],
    );
  }

  Widget _buildRecentlyPlayed(ThemeData theme, List<JellyfinTrack>? recentTracks, bool isLoading) {
    if (isLoading && (recentTracks == null || recentTracks.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    
    if (recentTracks == null || recentTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'No recently played tracks',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Start listening to see your history',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _loadRecentlyPlayed(),
      child: ListView.builder(
        cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.all(16),
        itemCount: recentTracks.length,
        itemBuilder: (context, index) {
          if (index >= recentTracks.length) {
            return const SizedBox.shrink();
          }
          final track = recentTracks[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(Icons.music_note, color: theme.colorScheme.secondary),
              title: Text(
                track.name,
                style: TextStyle(color: theme.colorScheme.tertiary),  // Ocean blue
              ),
              subtitle: Text(
                track.displayArtist,
                style: TextStyle(color: theme.colorScheme.tertiary.withValues(alpha: 0.7)),  // Ocean blue
              ),
              trailing: track.duration != null
                  ? Text(
                      _formatDuration(track.duration!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                      ),
                    )
                  : null,
              onTap: () {
                widget.appState.audioPlayerService.playTrack(
                  track,
                  queueContext: [track],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecentlyAdded(ThemeData theme, List<JellyfinAlbum>? albums, bool isLoading) {
    if (isLoading && (albums == null || albums.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (albums == null || albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.album, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'No recently added albums',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _loadRecentlyAdded(),
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.7,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: albums.length,
        itemBuilder: (context, index) {
          final album = albums[index];
          return _AlbumCard(
            album: album,
            appState: widget.appState,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AlbumDetailScreen(
                    album: album,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }
}

class _ArtistsTab extends StatelessWidget {
  const _ArtistsTab({
    required this.appState,
    this.artists,
    this.isLoading = false,
    this.isLoadingMore = false,
    this.error,
    this.scrollController,
    this.onRefresh,
  });

  final NautuneAppState appState;
  final List<JellyfinArtist>? artists;
  final bool isLoading;
  final bool isLoadingMore;
  final Object? error;
  final ScrollController? scrollController;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Use passed values or fallback to appState (online mode)
    final effectiveArtists = artists ?? appState.artists;
    final effectiveIsLoading = artists != null ? isLoading : appState.isLoadingArtists;
    final effectiveIsLoadingMore = artists != null ? isLoadingMore : appState.isLoadingMoreArtists;
    final effectiveError = artists != null ? error : appState.artistsError;

    if (effectiveIsLoading && effectiveArtists == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (effectiveError != null && effectiveArtists == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                'Failed to load artists',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                effectiveError.toString(),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (onRefresh != null)
                TextButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
            ],
          ),
        ),
      );
    }

    if (effectiveArtists == null || effectiveArtists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text(
              'No Artists Found',
              style: theme.textTheme.titleLarge,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        if (onRefresh != null) {
          onRefresh!();
        } else {
          await appState.refreshArtists();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;
          final useListMode = uiState.useListMode;
          final controller = scrollController ?? ScrollController();

          // List mode rendering
          final effectiveSortBy = artists != null ? SortOption.name : appState.artistSortBy;
          final effectiveSortOrder = artists != null ? SortOrder.ascending : appState.artistSortOrder;
          final showArtistHeaders = effectiveSortBy == SortOption.name;
          final artistLetterGroups = showArtistHeaders
              ? AlphabetSectionBuilder.groupByLetter<JellyfinArtist>(
                  effectiveArtists,
                  (artist) => artist.name,
                  effectiveSortOrder,
                )
              : <(String, List<JellyfinArtist>)>[];

          if (useListMode) {
            return Stack(
              children: [
                CustomScrollView(
                  controller: controller,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: showArtistHeaders
                          ? SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  int currentIndex = 0;
                                  for (final (letter, items) in artistLetterGroups) {
                                    if (index == currentIndex) {
                                      return _AlphabetSectionHeader(letter: letter);
                                    }
                                    currentIndex++;
                                    if (index < currentIndex + items.length) {
                                      final artist = items[index - currentIndex];
                                      return _ArtistListTile(artist: artist, appState: appState);
                                    }
                                    currentIndex += items.length;
                                  }
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                },
                                childCount: artistLetterGroups.fold(0, (sum, g) => sum + 1 + g.$2.length) + (effectiveIsLoadingMore ? 1 : 0),
                              ),
                            )
                          : SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= effectiveArtists.length) {
                                    return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                  }
                                  final artist = effectiveArtists[index];
                                  return _ArtistListTile(artist: artist, appState: appState);
                                },
                                childCount: effectiveArtists.length + (effectiveIsLoadingMore ? 1 : 0),
                              ),
                            ),
                    ),
                  ],
                ),
                AlphabetScrollbar(
                  items: effectiveArtists,
                  getItemName: (artist) => (artist as JellyfinArtist).name,
                  scrollController: controller,
                  itemHeight: 72,
                  crossAxisCount: 1,
                  sortOrder: effectiveSortOrder,
                  sortBy: effectiveSortBy,
                ),
              ],
            );
          }

          // Grid mode rendering
          final artistItemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 12) / crossAxisCount) / 0.75 + 12;

          return Stack(
            children: [
              CustomScrollView(
                controller: controller,
                slivers: showArtistHeaders
                    ? [
                        for (final (letter, items) in artistLetterGroups) ...[
                          SliverToBoxAdapter(
                            child: _AlphabetSectionHeader(letter: letter),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            sliver: SliverGrid(
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 0.7,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index >= items.length) return null;
                                  final artist = items[index];
                                  return _ArtistCard(artist: artist, appState: appState);
                                },
                                childCount: items.length,
                              ),
                            ),
                          ),
                        ],
                        if (effectiveIsLoadingMore)
                          const SliverToBoxAdapter(
                            child: Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator())),
                          ),
                      ]
                    : [
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 0.7,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                if (index >= effectiveArtists.length) {
                                  return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
                                }
                                final artist = effectiveArtists[index];
                                return _ArtistCard(artist: artist, appState: appState);
                              },
                              childCount: effectiveArtists.length + (effectiveIsLoadingMore ? 2 : 0),
                            ),
                          ),
                        ),
                      ],
              ),
              AlphabetScrollbar(
                items: effectiveArtists,
                getItemName: (artist) => (artist as JellyfinArtist).name,
                scrollController: controller,
                itemHeight: artistItemHeight,
                crossAxisCount: crossAxisCount,
                sortOrder: effectiveSortOrder,
                sortBy: effectiveSortBy,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ArtistListTile extends StatelessWidget {
  const _ArtistListTile({required this.artist, required this.appState});

  final JellyfinArtist artist;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = artist.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      artwork = ClipOval(
        child: JellyfinImage(
          itemId: artist.id,
          imageTag: tag,
          artistId: artist.id,
          maxWidth: 100,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => ClipOval(
            child: Image.asset(
              'assets/no_artist_art.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    } else {
      artwork = ClipOval(
        child: Image.asset(
          'assets/no_artist_art.png',
          fit: BoxFit.cover,
        ),
      );
    }

    return ListTile(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailScreen(
              artist: artist,
            ),
          ),
        );
      },
      leading: SizedBox(
        width: 56,
        height: 56,
        child: artwork,
      ),
      title: Text(
        artist.name,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// Genres Tab
class _GenresTab extends StatefulWidget {
  const _GenresTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_GenresTab> createState() => _GenresTabState();
}

class _GenresTabState extends State<_GenresTab> {
  late ScrollController _genresScrollController;

  @override
  void initState() {
    super.initState();
    _genresScrollController = ScrollController();
  }

  @override
  void dispose() {
    _genresScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final genres = widget.appState.genres;
    final isLoading = widget.appState.isLoadingGenres;
    final error = widget.appState.genresError;

    if (isLoading && genres == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error != null && genres == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text('Failed to load genres', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(error.toString(), style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (genres == null || genres.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.category, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text('No Genres Found', style: theme.textTheme.titleLarge),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => widget.appState.refreshGenres(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // User-controlled grid size - directly sets columns per row
          final uiState = context.watch<UIStateProvider>();
          final crossAxisCount = uiState.gridSize;

          // Genres are always sorted by name
          final genreLetterGroups = AlphabetSectionBuilder.groupByLetter<JellyfinGenre>(
            genres,
            (genre) => genre.name,
            SortOrder.ascending,
          );
          final genreItemHeight = ((constraints.maxWidth - 32 - (crossAxisCount - 1) * 12) / crossAxisCount) / 1.5 + 12;

          return Stack(
            children: [
              CustomScrollView(
                controller: _genresScrollController,
                slivers: [
                  for (final (letter, items) in genreLetterGroups) ...[
                    SliverToBoxAdapter(
                      child: _AlphabetSectionHeader(letter: letter),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 1.5,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index >= items.length) return null;
                            final genre = items[index];
                            return _GenreCard(genre: genre, appState: widget.appState);
                          },
                          childCount: items.length,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              AlphabetScrollbar(
                items: genres,
                getItemName: (genre) => (genre as JellyfinGenre).name,
                scrollController: _genresScrollController,
                itemHeight: genreItemHeight,
                crossAxisCount: crossAxisCount,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GenreCard extends StatelessWidget {
  const _GenreCard({required this.genre, required this.appState});

  final JellyfinGenre genre;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => GenreDetailScreen(
                genre: genre,
              ),
            ),
          );
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary.withValues(alpha: 0.3),
                theme.colorScheme.secondary.withValues(alpha: 0.3),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  genre.name,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (genre.albumCount != null || genre.trackCount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    [
                      if (genre.albumCount != null) '${genre.albumCount} albums',
                      if (genre.trackCount != null) '${genre.trackCount} tracks',
                    ].join(' • '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}



class _SearchTab extends StatefulWidget {
  const _SearchTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final TextEditingController _controller = TextEditingController();
  final Debouncer _debouncer = Debouncer();
  List<String> _recentQueries = [];
  String _lastQuery = '';
  bool _isLoading = false;
  bool _showRelaxEasterEgg = false;
  bool _showNetworkEasterEgg = false;
  bool _showEssentialEasterEgg = false;
  bool _showFireEasterEgg = false;
  List<JellyfinAlbum> _albumResults = const [];
  List<JellyfinArtist> _artistResults = const [];
  List<JellyfinTrack> _trackResults = const [];
  Object? _error;
  static const int _historyLimit = 10;
  static const String _boxName = 'nautune_search_history';
  static const String _historyKey = 'global_search_history';

  @override
  void initState() {
    super.initState();
    _loadRecentQueries();
  }

  @override
  void dispose() {
    _debouncer.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<void> _loadRecentQueries() async {
    final box = await _box();
    if (!mounted) return;
    final raw = box.get(_historyKey);
    setState(() {
      if (raw is List) {
        _recentQueries = raw.cast<String>();
      } else {
        _recentQueries = [];
      }
    });
  }

  Future<void> _persistRecentQueries() async {
    final box = await _box();
    await box.put(_historyKey, _recentQueries);
  }

  Future<void> _clearRecentQueries() async {
    if (_recentQueries.isEmpty) return;
    setState(() {
      _recentQueries = [];
    });
    final box = await _box();
    await box.delete(_historyKey);
  }
  
  Future<void> _rememberQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final list = List<String>.from(_recentQueries);
    list.removeWhere((item) => item.toLowerCase() == trimmed.toLowerCase());
    list.insert(0, trimmed);
    while (list.length > _historyLimit) {
      list.removeLast();
    }
    setState(() {
      _recentQueries = list;
    });
    await _persistRecentQueries();
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    final lowerQuery = trimmed.toLowerCase();
    setState(() {
      _lastQuery = trimmed;
      _error = null;
    });

    if (trimmed.isEmpty) {
      setState(() {
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
        _isLoading = false;
        _showRelaxEasterEgg = false;
        _showNetworkEasterEgg = false;
        _showEssentialEasterEgg = false;
        _showFireEasterEgg = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      // Easter eggs: show special cards when searching certain keywords
      _showRelaxEasterEgg = lowerQuery.contains('relax');
      _showNetworkEasterEgg = lowerQuery.contains('network');
      _showEssentialEasterEgg = lowerQuery.contains('essential');
      _showFireEasterEgg = lowerQuery.contains('fire') || lowerQuery.contains('frets');
    });
    unawaited(_rememberQuery(trimmed));

    // Demo mode: search bundled showcase data (all types)
    if (widget.appState.isDemoMode) {
      final albums = widget.appState.demoAlbums
          .where((album) =>
              album.name.toLowerCase().contains(lowerQuery) ||
              album.displayArtist.toLowerCase().contains(lowerQuery))
          .toList();
      final artists = widget.appState.demoArtists
          .where((artist) => artist.name.toLowerCase().contains(lowerQuery))
          .toList();
      final tracks = widget.appState.demoTracks
          .where((track) =>
              track.name.toLowerCase().contains(lowerQuery) ||
              (track.album?.toLowerCase().contains(lowerQuery) ?? false) ||
              track.displayArtist.toLowerCase().contains(lowerQuery))
          .toList();
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _albumResults = albums;
        _artistResults = artists;
        _trackResults = tracks;
        _isLoading = false;
      });
      return;
    }
    
    // Offline mode: search downloaded content only (global search)
    if (widget.appState.isOfflineMode) {
      try {
        final downloads = widget.appState.downloadService.completedDownloads;

        // Build album groups for album search
        final Map<String, List<DownloadItem>> albumGroups = {};
        for (final download in downloads) {
          final albumName = download.track.album ?? 'Unknown Album';
          if (!albumGroups.containsKey(albumName)) {
            albumGroups[albumName] = [];
          }
          albumGroups[albumName]!.add(download);
        }

        // Filter albums by query
        final matchingAlbums = albumGroups.entries
            .where((entry) => entry.key.toLowerCase().contains(lowerQuery))
            .map((entry) {
          final firstTrack = entry.value.first.track;
          return JellyfinAlbum(
            id: firstTrack.albumId ?? firstTrack.id,
            name: entry.key,
            artists: [firstTrack.displayArtist],
            artistIds: const [],
          );
        }).toList();

        // Build artist groups for artist search
        final Map<String, List<DownloadItem>> artistGroups = {};
        for (final download in downloads) {
          final artistName = download.track.displayArtist;
          if (!artistGroups.containsKey(artistName)) {
            artistGroups[artistName] = [];
          }
          artistGroups[artistName]!.add(download);
        }

        // Filter artists by query
        final matchingArtists = artistGroups.keys
            .where((name) => name.toLowerCase().contains(lowerQuery))
            .map((name) => JellyfinArtist(
              id: 'offline_$name',
              name: name,
            ))
            .toList();

        // Filter tracks by query
        final matchingTracks = downloads
            .map((download) => download.track)
            .where((track) {
              final albumName = track.album?.toLowerCase() ?? '';
              return track.name.toLowerCase().contains(lowerQuery) ||
                  track.displayArtist.toLowerCase().contains(lowerQuery) ||
                  albumName.contains(lowerQuery);
            })
            .toList();

        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _albumResults = matchingAlbums;
          _artistResults = matchingArtists;
          _trackResults = matchingTracks;
          _isLoading = false;
        });
      } catch (e) {
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _error = e;
          _albumResults = const [];
          _artistResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      }
      return;
    }

    // Online mode: search Jellyfin server
    final libraryId = widget.appState.session?.selectedLibraryId;
    if (libraryId == null) {
      setState(() {
        _error = 'Select a music library to search.';
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
        _isLoading = false;
      });
      return;
    }

    try {
      // Global search - search all content types in parallel
      final results = await widget.appState.jellyfinService.searchAllBatch(
        libraryId: libraryId,
        query: trimmed,
      );
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _albumResults = results.albums;
        _artistResults = results.artists;
        _trackResults = results.tracks;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _error = error;
        _isLoading = false;
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final libraryId = widget.appState.session?.selectedLibraryId;

    // Allow search in demo mode and offline mode even without a library
    if (libraryId == null && !widget.appState.isDemoMode && !widget.appState.isOfflineMode) {
      return Center(
        child: Text(
          'Choose a library to enable search.',
          style: theme.textTheme.titleMedium,
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _controller,
            onChanged: (value) {
              _debouncer.run(() => _performSearch(value));
            },
            onSubmitted: (value) {
              _debouncer.cancel();
              _performSearch(value);
            },
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search albums, artists, tracks...',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => _performSearch(_controller.text),
              ),
            ),
          ),
        ),
        if (_controller.text.trim().isEmpty && _recentQueries.isNotEmpty)
          _buildRecentQueriesSection(theme),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error.toString(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _buildResults(theme),
        ),
      ],
    );
  }
  
  Widget _buildRecentQueriesSection(ThemeData theme) {
    if (_recentQueries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Recent searches',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Clear recent searches',
                icon: const Icon(Icons.close),
                onPressed: () => unawaited(_clearRecentQueries()),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in _recentQueries)
                ActionChip(
                  label: Text(query),
                  onPressed: () {
                    _controller.text = query;
                    _performSearch(query);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_lastQuery.isEmpty) {
      return Center(
        child: Text(
          'Search across albums, artists, and tracks.',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    final hasResults = _albumResults.isNotEmpty ||
                      _artistResults.isNotEmpty ||
                      _trackResults.isNotEmpty ||
                      _showRelaxEasterEgg ||
                      _showNetworkEasterEgg ||
                      _showEssentialEasterEgg ||
                      _showFireEasterEgg;

    if (!hasResults) {
      return Center(
        child: Text(
          'No results found for "$_lastQuery"',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        // Easter egg: Relax Mode card
        if (_showRelaxEasterEgg)
          _buildRelaxModeCard(theme),
        // Easter egg: Network radio card
        if (_showNetworkEasterEgg)
          _buildNetworkModeCard(theme),
        // Easter egg: Essential Mix card
        if (_showEssentialEasterEgg)
          _buildEssentialMixCard(theme),
        // Easter egg: Frets on Fire card
        if (_showFireEasterEgg)
          _buildFretsOnFireCard(theme),
        // Artists section
        if (_artistResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Artists', Icons.person, _artistResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _artistResults.length,
            (index) => _buildArtistTile(theme, _artistResults[index]),
          ),
          const SizedBox(height: 16),
        ],
        // Albums section
        if (_albumResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Albums', Icons.album, _albumResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _albumResults.length,
            (index) => _buildAlbumTile(theme, _albumResults[index]),
          ),
          const SizedBox(height: 16),
        ],
        // Tracks section
        if (_trackResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Tracks', Icons.music_note, _trackResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _trackResults.length,
            (index) => _buildTrackTile(theme, _trackResults[index]),
          ),
        ],
      ],
    );
  }

  Widget _buildRelaxModeCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        leading: Icon(Icons.spa, color: theme.colorScheme.primary),
        title: const Text('Relax Mode'),
        subtitle: const Text('Ambient sound mixer'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const RelaxModeScreen()),
        ),
      ),
    );
  }

  Widget _buildNetworkModeCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: Colors.black,
      child: ListTile(
        leading: const Icon(Icons.radio, color: Colors.white),
        title: const Text(
          'The Network',
          style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
        ),
        subtitle: const Text(
          'Other People Radio 0-333',
          style: TextStyle(color: Colors.white70, fontFamily: 'monospace'),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const NetworkScreen()),
        ),
      ),
    );
  }

  Widget _buildEssentialMixCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xFF1A1A2E),
      child: ListTile(
        leading: const Icon(Icons.album, color: Colors.deepPurple),
        title: const Text(
          'Essential Mix',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Soulwax / 2ManyDJs • BBC Radio 1',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const EssentialMixScreen()),
        ),
      ),
    );
  }

  Widget _buildFretsOnFireCard(ThemeData theme) {
    return Card(
      color: Colors.deepOrange.shade900,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.local_fire_department, color: Colors.orange),
        title: const Text(
          'Frets on Fire',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Guitar Hero-style rhythm game',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const FretsOnFireScreen()),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon, int count) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistTile(ThemeData theme, JellyfinArtist artist) {
    return Card(
      child: ListTile(
        leading: artist.primaryImageTag != null
            ? ClipOval(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: JellyfinImage(
                    itemId: artist.id,
                    imageTag: artist.primaryImageTag!,
                    artistId: artist.id, // Enable offline artist image support
                    maxWidth: 100,
                    boxFit: BoxFit.cover,
                    errorBuilder: (context, url, error) =>
                        const CircleAvatar(child: Icon(Icons.person_outline)),
                  ),
                ),
              )
            : const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(
          artist.name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: const Color(0xFF8CB1D9),
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: artist.songCount != null
            ? Text('${artist.songCount} songs')
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtistDetailScreen(artist: artist),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAlbumTile(ThemeData theme, JellyfinAlbum album) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.album_outlined),
        title: Text(album.name),
        subtitle: Text(album.displayArtist),
        trailing: album.productionYear != null
            ? Text('${album.productionYear}')
            : null,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AlbumDetailScreen(album: album),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrackTile(ThemeData theme, JellyfinTrack track) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.music_note,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          track.name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.tertiary,
          ),
        ),
        subtitle: Text(
          '${track.displayArtist}${track.album != null ? ' • ${track.album}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: track.duration != null
            ? Text(
                _formatDuration(track.duration!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        onTap: () {
          widget.appState.audioPlayerService.playTrack(
            track,
            queueContext: _trackResults,
          );
        },
      ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.artist, required this.appState});

  final JellyfinArtist artist;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = artist.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      artwork = ClipOval(
        child: JellyfinImage(
          itemId: artist.id,
          imageTag: tag,
          artistId: artist.id, // Enable offline artist image support
          maxWidth: 400,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => ClipOval(
            child: Image.asset(
              'assets/no_artist_art.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
      );
    } else {
      artwork = ClipOval(
        child: Image.asset(
          'assets/no_artist_art.png',
          fit: BoxFit.cover,
        ),
      );
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailScreen(
              artist: artist,
            ),
          ),
        );
      },
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: AspectRatio(
              aspectRatio: 1,
              child: artwork,
            ),
          ),
          Expanded(
            flex: 1,
            child: ClipRect(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  artist.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.tertiary,  // Ocean blue
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
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

/// Section header widget for alphabet groups
class _AlphabetSectionHeader extends StatelessWidget {
  const _AlphabetSectionHeader({required this.letter});
  final String letter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(
        letter,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Helper to build a flat list with section headers for SliverList
class AlphabetSectionBuilder {
  AlphabetSectionBuilder._();

  /// Groups items by first letter and returns a list of (letter, items) pairs
  static List<(String, List<T>)> groupByLetter<T>(
    List<T> items,
    String Function(T) getItemName,
    SortOrder sortOrder,
  ) {
    if (items.isEmpty) return [];

    final isAscending = sortOrder == SortOrder.ascending;

    // Group items by first letter
    final Map<String, List<T>> letterGroups = {};
    for (final item in items) {
      final name = getItemName(item).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      final letter = RegExp(r'[0-9]').hasMatch(firstChar) ? '#' : firstChar;
      letterGroups.putIfAbsent(letter, () => []).add(item);
    }

    // Sort letters
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    return sortedLetters.map((letter) => (letter, letterGroups[letter]!)).toList();
  }
}

/// Helper class to map letters to their positions in a list with section headers
class LetterPositions {
  LetterPositions._();

  /// Build a map of letter -> flat index accounting for section headers
  /// Returns (letterToFlatIndex, totalItemCount including headers)
  static (Map<String, int>, int) buildWithHeaders(
    List items,
    String Function(dynamic) getItemName,
    SortOrder sortOrder,
  ) {
    if (items.isEmpty) return ({}, 0);

    final Map<String, int> letterToIndex = {};
    final isAscending = sortOrder == SortOrder.ascending;

    // Group items by first letter
    final Map<String, List<int>> letterGroups = {};
    for (int i = 0; i < items.length; i++) {
      final name = getItemName(items[i]).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      final letter = RegExp(r'[0-9]').hasMatch(firstChar) ? '#' : firstChar;
      letterGroups.putIfAbsent(letter, () => []).add(i);
    }

    // Sort letters appropriately
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        // # comes first in ascending, last in descending
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    // Calculate flat positions (each letter group adds 1 header)
    int flatIndex = 0;
    for (final letter in sortedLetters) {
      letterToIndex[letter] = flatIndex;
      flatIndex++; // The header
      flatIndex += letterGroups[letter]!.length; // The items
    }

    return (letterToIndex, flatIndex);
  }

  /// Get the letter for an item at a given index
  static String getLetterForItem(dynamic item, String Function(dynamic) getItemName) {
    final name = getItemName(item).toUpperCase();
    if (name.isEmpty) return '#';
    final firstChar = name[0];
    return RegExp(r'[0-9]').hasMatch(firstChar) ? '#' : firstChar;
  }
}

// Alphabet scrollbar for quick navigation
class AlphabetScrollbar extends StatefulWidget {
  const AlphabetScrollbar({
    super.key,
    required this.items,
    required this.getItemName,
    required this.scrollController,
    required this.itemHeight,
    required this.crossAxisCount,
    this.sortOrder = SortOrder.ascending,
    this.sortBy,
    this.headerHeight = 40.0,
    this.useHeaders = true,
  });

  final List items;
  final String Function(dynamic) getItemName;
  final ScrollController scrollController;
  final double itemHeight;
  final int crossAxisCount;
  final SortOrder sortOrder;
  final SortOption? sortBy;
  final double headerHeight;
  final bool useHeaders;

  @override
  State<AlphabetScrollbar> createState() => _AlphabetScrollbarState();
}

class _AlphabetScrollbarState extends State<AlphabetScrollbar> {
  static const _alphabet = ['#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I',
                             'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
                             'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];

  String? _activeLetter;
  double _bubbleY = 0.0;

  /// Normalizes accented characters to their base A-Z letter.
  /// E.g., 'É' → 'E', 'Ñ' → 'N', 'Ü' → 'U'
  static String _normalizeToBaseLetter(String char) {
    if (char.isEmpty) return '#';
    final code = char.codeUnitAt(0);

    // Already a standard A-Z letter
    if (code >= 65 && code <= 90) return char;

    // Already a digit
    if (code >= 48 && code <= 57) return '#';

    // Map common accented characters to base letters
    // This covers most Latin-based languages
    const accentMap = {
      // A variants
      'À': 'A', 'Á': 'A', 'Â': 'A', 'Ã': 'A', 'Ä': 'A', 'Å': 'A', 'Ă': 'A', 'Ą': 'A',
      // C variants
      'Ç': 'C', 'Ć': 'C', 'Č': 'C',
      // D variants
      'Ď': 'D', 'Đ': 'D',
      // E variants
      'È': 'E', 'É': 'E', 'Ê': 'E', 'Ë': 'E', 'Ě': 'E', 'Ę': 'E',
      // G variants
      'Ğ': 'G',
      // I variants
      'Ì': 'I', 'Í': 'I', 'Î': 'I', 'Ï': 'I', 'İ': 'I',
      // L variants
      'Ł': 'L',
      // N variants
      'Ñ': 'N', 'Ń': 'N', 'Ň': 'N',
      // O variants
      'Ò': 'O', 'Ó': 'O', 'Ô': 'O', 'Õ': 'O', 'Ö': 'O', 'Ø': 'O', 'Ő': 'O',
      // R variants
      'Ř': 'R',
      // S variants
      'Ś': 'S', 'Ş': 'S', 'Š': 'S',
      // T variants
      'Ť': 'T', 'Ţ': 'T',
      // U variants
      'Ù': 'U', 'Ú': 'U', 'Û': 'U', 'Ü': 'U', 'Ů': 'U', 'Ű': 'U',
      // Y variants
      'Ý': 'Y', 'Ÿ': 'Y',
      // Z variants
      'Ź': 'Z', 'Ż': 'Z', 'Ž': 'Z',
      // Ligatures and special
      'Æ': 'A', 'Œ': 'O', 'Þ': 'T', 'Ð': 'D',
    };

    return accentMap[char] ?? '#';
  }

  // Build a map from first letter to scroll position for fast lookup
  // Returns (letterToPosition, totalHeight)
  (Map<String, double>, double) _buildLetterPositions() {
    final Map<String, double> letterToPosition = {};
    final isAscending = widget.sortOrder == SortOrder.ascending;

    // Group items by first letter (normalized to base A-Z)
    final Map<String, List<int>> letterGroups = {};
    for (int i = 0; i < widget.items.length; i++) {
      final name = widget.getItemName(widget.items[i]).toUpperCase();
      if (name.isEmpty) continue;
      final firstChar = name[0];
      // Use normalizer to map accented chars to base letters
      final letter = RegExp(r'[0-9]').hasMatch(firstChar)
          ? '#'
          : _normalizeToBaseLetter(firstChar);
      letterGroups.putIfAbsent(letter, () => []).add(i);
    }

    // Sort letters appropriately
    final sortedLetters = letterGroups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return isAscending ? -1 : 1;
        if (b == '#') return isAscending ? 1 : -1;
        return isAscending ? a.compareTo(b) : b.compareTo(a);
      });

    // Calculate scroll positions accounting for headers
    // Grid mode (crossAxisCount > 1): no initial padding, first header at 0
    // List mode (crossAxisCount == 1): 8px initial padding from SliverPadding
    final isListMode = widget.crossAxisCount == 1;
    double currentPosition = isListMode ? 8.0 : 0.0;

    for (final letter in sortedLetters) {
      letterToPosition[letter] = currentPosition;
      currentPosition += widget.headerHeight; // Header (40px)
      final itemCount = letterGroups[letter]!.length;
      final rowCount = (itemCount / widget.crossAxisCount).ceil();
      currentPosition += rowCount * widget.itemHeight;
    }
    
    // Add bottom padding
    currentPosition += 100.0; 

    return (letterToPosition, currentPosition);
  }

  void _scrollToLetter(String letter) {
    if (widget.items.isEmpty) return;
    if (!widget.scrollController.hasClients) return;

    final (letterPositions, totalHeight) = _buildLetterPositions();
    double targetPosition;

    // Direct match
    if (letterPositions.containsKey(letter)) {
      targetPosition = letterPositions[letter]!;
    } else {
      // No exact match - find nearest letter
      final isAscending = widget.sortOrder == SortOrder.ascending;

      if (letter == '#') {
        // Looking for numbers but none found - go to start/end
        targetPosition = isAscending ? 0.0 : totalHeight;
      } else {
        // Find the closest available letter
        final letterCode = letter.codeUnitAt(0);
        String? bestMatch;
        final sortedKeys = letterPositions.keys.toList()
          ..sort((a, b) {
            if (a == '#') return isAscending ? -1 : 1;
            if (b == '#') return isAscending ? 1 : -1;
            return isAscending ? a.compareTo(b) : b.compareTo(a);
          });

        // Filter to only standard A-Z letters for fallback (ignore accented chars like Á, †, etc.)
        final standardKeys = sortedKeys.where((k) => k == '#' || (k.codeUnitAt(0) >= 65 && k.codeUnitAt(0) <= 90)).toList();

        if (isAscending) {
          // Ascending: Find first existing letter >= target
          for (final key in standardKeys) {
            if (key == '#') continue;
            if (key.codeUnitAt(0) >= letterCode) {
              bestMatch = key;
              break;
            }
          }
        } else {
          // Descending: Find first existing letter <= target
          for (final key in standardKeys) {
            if (key == '#') continue;
            if (key.codeUnitAt(0) <= letterCode) {
              bestMatch = key;
              break;
            }
          }
        }

        if (bestMatch != null) {
          targetPosition = letterPositions[bestMatch]!;
        } else {
          // If no letter found after target (e.g. target Z, only have A-Y), go to end
          // Use calculated totalHeight instead of maxScrollExtent which might be inaccurate
          targetPosition = isAscending ? totalHeight : 0.0;
        }
      }
    }

    // Ensure we don't scroll before the start
    // We do NOT clamp to maxScrollExtent because in List View (SliverList),
    // the maxExtent might be estimated and much smaller than the real content height.
    // Jumping to the calculated position usually forces the list to build and update the extent.
    final safePosition = targetPosition < 0.0 ? 0.0 : targetPosition;

    // Use jumpTo during drag for immediate response
    if (_activeLetter != null) {
      widget.scrollController.jumpTo(safePosition);
    } else {
      widget.scrollController.animateTo(
        safePosition,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _handleInput(Offset localPosition, double height, List<String> displayLetters) {
    // Divide touch area into N equal zones
    // Zone i covers y from i*H/N to (i+1)*H/N
    final int index = (localPosition.dy * displayLetters.length / height)
        .floor()
        .clamp(0, displayLetters.length - 1);
    final String letter = displayLetters[index];

    if (_activeLetter != letter) {
      setState(() {
        _activeLetter = letter;
        _bubbleY = localPosition.dy.clamp(20, height - 80);
      });
      _scrollToLetter(letter);
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hide scrollbar when not sorting by name (letters don't match content)
    if (widget.sortBy != null && widget.sortBy != SortOption.name) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The Touch Strip
        Positioned(
          right: 0,
          top: 40,
          bottom: 40,
          width: 30,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight = constraints.maxHeight;
              final letterHeight = 16.0;
              final maxLetters = (availableHeight / letterHeight).floor();
              
              // If not enough space for all letters, show subset
              List<String> displayLetters = _alphabet;
              if (maxLetters < _alphabet.length && maxLetters > 0) {
                final step = (_alphabet.length / maxLetters).ceil();
                displayLetters = [];
                for (int i = 0; i < _alphabet.length; i += step) {
                  displayLetters.add(_alphabet[i]);
                }
              }
              
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragStart: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragUpdate: (details) => _handleInput(details.localPosition, constraints.maxHeight, displayLetters),
                onVerticalDragEnd: (_) => setState(() => _activeLetter = null),
                onTapUp: (_) => setState(() => _activeLetter = null),
                child: Container(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: displayLetters.map((letter) {
                      final isActive = _activeLetter == letter;
                      return Flexible(
                        child: AnimatedScale(
                          scale: isActive ? 1.4 : 1.0,
                          duration: const Duration(milliseconds: 100),
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isActive ? FontWeight.w900 : FontWeight.w600,
                              color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
        ),

        // The Pop Out Bubble
        if (_activeLetter != null)
           Positioned(
             right: 50,
             top: _bubbleY + 40, // Offset to match touch strip positioning
             child: Container(
               width: 60, height: 60,
               alignment: Alignment.center,
               decoration: BoxDecoration(
                 color: theme.colorScheme.primaryContainer,
                 shape: BoxShape.circle,
                 boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
               ),
               child: Text(
                 _activeLetter!,
                 style: TextStyle(
                   fontSize: 32, 
                   fontWeight: FontWeight.bold, 
                   color: theme.colorScheme.onPrimaryContainer
                 ),
               ),
             ),
           ),
      ],
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
          Icon(icon, size: 64, color: Colors.grey.shade600),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
