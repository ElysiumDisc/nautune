import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_genre.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../repositories/music_repository.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'genre_detail_screen.dart';
import 'offline_library_screen.dart';
import 'playlist_detail_screen.dart';
import 'settings_screen.dart';

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
  
  // Provider-based state
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;

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
    // Refresh favorites when switching to favorites tab (tab index 1)
    if (_currentTabIndex == 1) {
      _appState?.refreshFavorites();
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
        var favoriteTracks = appState.favoriteTracks;
        if (appState.isOfflineMode && favoriteTracks != null) {
          favoriteTracks = favoriteTracks.where((t) => 
            appState.downloadService.isDownloaded(t.id)
          ).toList();
        }
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

        return Scaffold(
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
                          ? const Color(0xFF7A3DF1)  // Violet when offline
                          : const Color(0xFFB39DDB),  // Light purple when online
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
                            color: const Color(0xFFB39DDB),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (appState.isOfflineMode) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.offline_bolt,
                            size: 20,
                            color: const Color(0xFF7A3DF1),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              if (selectedId != null)
                IconButton(
                  icon: const Icon(Icons.library_books_outlined),
                  onPressed: () => appState.clearLibrarySelection(),
                ),
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: () => appState.disconnect(),
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
              NavigationBar(
                selectedIndex: _currentTabIndex,
                onDestinationSelected: (index) {
                  setState(() => _currentTabIndex = index);
                  _tabController.animateTo(index);
                },
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.library_music),
                    label: 'Library',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.favorite_outline),
                    label: 'Favorites',
                  ),
                  NavigationDestination(
                    icon: Icon(appState.isOfflineMode ? Icons.download : Icons.home_outlined),
                    label: appState.isOfflineMode ? 'Downloads' : 'Home',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.queue_music),
                    label: 'Playlists',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                ],
              ),
              NowPlayingBar(
                audioService: appState.audioPlayerService,
                appState: appState,
              ),
            ],
          ),
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

  @override
  void initState() {
    super.initState();
    _albumsScrollController = ScrollController();
    _albumsScrollController.addListener(_onAlbumsScroll);
  }

  @override
  void dispose() {
    _albumsScrollController.dispose();
    super.dispose();
  }

  void _onAlbumsScroll() {
    if (_albumsScrollController.position.pixels >=
        _albumsScrollController.position.maxScrollExtent - 200) {
      widget.appState.loadMoreAlbums();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = widget.appState.isOfflineMode;
    final theme = Theme.of(context);
    
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
      final Map<String, List<dynamic>> artistsMap = {};
      for (final download in downloads) {
        final artistName = download.track.displayArtist;
        artistsMap.putIfAbsent(artistName, () => []).add(download);
      }

      final offlineArtists = artistsMap.keys.map((name) {
        return JellyfinArtist(
          id: 'offline_$name',
          name: name,
        );
      }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

      return _ArtistsTab(
        appState: widget.appState,
        artists: offlineArtists,
        isLoading: false,
        isLoadingMore: false,
        error: null,
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
      return _ArtistsTab(appState: widget.appState);
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
          // 4 columns on desktop (>800px), 2 columns on mobile
          final crossAxisCount = constraints.maxWidth > 800 ? 4 : 2;

          return Stack(
            children: [
              CustomScrollView(
                controller: scrollController,
                slivers: [
                  // Albums grid
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.75,
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
                itemHeight: (constraints.maxWidth / crossAxisCount) * (1 / 0.75) + 16,
                crossAxisCount: crossAxisCount,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({
    required this.title,
    required this.onRefresh,
    required this.isLoading,
  });

  final String title;
  final VoidCallback onRefresh;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
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
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.tertiary,  // Ocean blue
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (album.artists.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      album.displayArtist,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue slightly transparent
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
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
          title: 'Recently Played',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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

class _MostPlayedAlbumsShelf extends StatelessWidget {
  const _MostPlayedAlbumsShelf({
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
          title: 'Most Played Albums',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 240,
          child: !hasData && isLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
                        'No play history yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _MostPlayedTracksShelf extends StatelessWidget {
  const _MostPlayedTracksShelf({
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
          title: 'Most Played Tracks',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
                        'No play history yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _LongestTracksShelf extends StatelessWidget {
  const _LongestTracksShelf({
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
          title: 'Longest Tracks',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
                        'No tracks found.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _PlaylistsTab extends StatelessWidget {
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
      return Center(
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
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: playlists!.length + (isLoading ? 1 : 0) + 1, // +1 for header button
        itemBuilder: (context, index) {
          // Add header buttons as first items
          if (index == 0) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
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
        padding: const EdgeInsets.all(16),
        itemCount: recentTracks?.length ?? 0,
        itemBuilder: (context, index) {
          if (recentTracks == null || index >= recentTracks!.length) {
            return const SizedBox.shrink();
          }
          final track = recentTracks![index];
          return Card(
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
                        builder: (sheetContext) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      SnackBar(
                                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } catch (e) {
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
                            ],
                          ),
                        ),
                      );
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              onTap: () => onTrackTap(track),
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(duration.inMinutes.remainder(60))}:${twoDigits(duration.inSeconds.remainder(60))}';
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
    final mostPlayedAlbums = widget.appState.mostPlayedAlbums;
    final mostPlayedAlbumsLoading = widget.appState.isLoadingMostPlayedAlbums;
    final mostPlayedTracks = widget.appState.mostPlayedTracks;
    final mostPlayedTracksLoading = widget.appState.isLoadingMostPlayedTracks;
    final longestTracks = widget.appState.longestTracks;
    final longestTracksLoading = widget.appState.isLoadingLongestTracks;

    final showContinue = continueLoading || (continueTracks != null && continueTracks.isNotEmpty);
    final showRecentlyPlayed = recentlyPlayedLoading || (recentlyPlayed != null && recentlyPlayed.isNotEmpty);
    final showRecentlyAdded = recentlyAddedLoading || (recentlyAdded != null && recentlyAdded.isNotEmpty);
    final showMostPlayedAlbums = mostPlayedAlbumsLoading || (mostPlayedAlbums != null && mostPlayedAlbums.isNotEmpty);
    final showMostPlayedTracks = mostPlayedTracksLoading || (mostPlayedTracks != null && mostPlayedTracks.isNotEmpty);
    final showLongestTracks = longestTracksLoading || (longestTracks != null && longestTracks.isNotEmpty);

    if (!showContinue && !showRecentlyPlayed && !showRecentlyAdded && !showMostPlayedAlbums && !showMostPlayedTracks && !showLongestTracks) {
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
        if (showMostPlayedAlbums) ...[
          _MostPlayedAlbumsShelf(
            albums: mostPlayedAlbums,
            isLoading: mostPlayedAlbumsLoading,
            appState: widget.appState,
            onAlbumTap: widget.onAlbumTap,
            onRefresh: () => widget.appState.refreshMostPlayedAlbums(),
          ),
          const SizedBox(height: 20),
        ],
        if (showMostPlayedTracks) ...[
          _MostPlayedTracksShelf(
            tracks: mostPlayedTracks,
            isLoading: mostPlayedTracksLoading,
            onPlay: (track) {
              final queue = mostPlayedTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshMostPlayedTracks(),
          ),
          const SizedBox(height: 20),
        ],
        if (showLongestTracks) ...[
          _LongestTracksShelf(
            tracks: longestTracks,
            isLoading: longestTracksLoading,
            onPlay: (track) {
              final queue = longestTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshLongestTracks(),
          ),
          const SizedBox(height: 12),
        ],
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
    return '${twoDigits(duration.inMinutes.remainder(60))}:${twoDigits(duration.inSeconds.remainder(60))}';
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
          // 4 columns on desktop (>800px), 3 columns on mobile
          final crossAxisCount = constraints.maxWidth > 800 ? 4 : 3;
          final controller = scrollController ?? ScrollController();

          return Stack(
            children: [
              CustomScrollView(
                controller: controller,
                slivers: [
                  // Artists grid
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 0.75,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index >= effectiveArtists.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16.0),
                                child: CircularProgressIndicator(),
                              ),
                            );
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
                itemHeight: (constraints.maxWidth / crossAxisCount) * (1 / 0.75) + 12,
                crossAxisCount: crossAxisCount,
              ),
            ],
          );
        },
      ),
    );
  }
}

// Offline Albums View
class _OfflineAlbumsView extends StatelessWidget {
  const _OfflineAlbumsView({required this.appState, required this.onAlbumTap});

  final NautuneAppState appState;
  final Function(JellyfinAlbum) onAlbumTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: appState.downloadService,
      builder: (context, _) {
        final downloads = appState.downloadService.completedDownloads;
        
        if (downloads.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.offline_bolt, size: 64, color: theme.colorScheme.secondary),
                const SizedBox(height: 16),
                Text('No Offline Albums', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Download albums to listen offline', style: theme.textTheme.bodyMedium),
              ],
            ),
          );
        }

        // Group by album
        final albumsMap = <String, List<dynamic>>{};
        for (final download in downloads) {
          final albumName = download.track.album ?? 'Unknown Album';
          albumsMap.putIfAbsent(albumName, () => []).add(download);
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth > 800 ? 4 : 2;
            final albums = albumsMap.entries.toList();

            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: 0.75,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final entry = albums[index];
                final albumName = entry.key;
                final albumDownloads = entry.value;
                final firstTrack = albumDownloads.first.track;

                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      // Navigate to album detail instead of immediate playback
                      // Create a JellyfinAlbum object from the downloaded tracks
                      final album = JellyfinAlbum(
                        id: firstTrack.albumId,
                        name: albumName,
                        artists: [firstTrack.displayArtist],
                        artistIds: firstTrack.albumArtistIds ?? [],
                      );
                      onAlbumTap(album);
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: FutureBuilder<File?>(
                            future: appState.downloadService.getArtworkFile(firstTrack.id),
                            builder: (context, snapshot) {
                              if (snapshot.hasData && snapshot.data != null) {
                                return Image.file(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                );
                              }
                              return Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: Image.asset(
                                  'assets/no_album_art.png',
                                  fit: BoxFit.cover,
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                albumName,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.tertiary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                firstTrack.displayArtist,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${albumDownloads.length} tracks',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

// Offline Artists View
class _OfflineArtistsView extends StatelessWidget {
  const _OfflineArtistsView({required this.appState});

  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: appState.downloadService,
      builder: (context, _) {
        final downloads = appState.downloadService.completedDownloads;
        
        if (downloads.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.offline_bolt, size: 64, color: theme.colorScheme.secondary),
                const SizedBox(height: 16),
                Text('No Offline Artists', style: theme.textTheme.titleLarge),
              ],
            ),
          );
        }

        // Group by artist
        final artistsMap = <String, List<dynamic>>{};
        for (final download in downloads) {
          final artistName = download.track.displayArtist;
          artistsMap.putIfAbsent(artistName, () => []).add(download);
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = constraints.maxWidth > 800 ? 4 : 3;
            final artists = artistsMap.entries.toList();

            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                childAspectRatio: 0.75,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: artists.length,
              itemBuilder: (context, index) {
                final entry = artists[index];
                final artistName = entry.key;
                final artistDownloads = entry.value;

                return InkWell(
                  onTap: () {
                    // Play all tracks by artist
                    final tracks = artistDownloads.map((d) => d.track as JellyfinTrack).toList();
                    appState.audioPlayerService.playTrack(
                      tracks.first,
                      queueContext: tracks,
                    );
                  },
                  child: Column(
                    children: [
                      Expanded(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ClipOval(
                            child: Image.asset(
                              'assets/no_artist_art.png',
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        artistName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.tertiary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        '${artistDownloads.length} tracks',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
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
          final crossAxisCount = constraints.maxWidth > 800 ? 4 : 2;

          return Stack(
            children: [
              GridView.builder(
                controller: _genresScrollController,
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 1.5,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: genres.length,
                itemBuilder: (context, index) {
                  final genre = genres[index];
                  return _GenreCard(genre: genre, appState: widget.appState);
                },
              ),
              AlphabetScrollbar(
                items: genres,
                getItemName: (genre) => (genre as JellyfinGenre).name,
                scrollController: _genresScrollController,
                itemHeight: (constraints.maxWidth / crossAxisCount) * (1 / 1.5) + 12,
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



enum _SearchScope { albums, artists, tracks }

class _SearchTab extends StatefulWidget {
  const _SearchTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final TextEditingController _controller = TextEditingController();
  final Map<_SearchScope, List<String>> _recentQueries = {
    for (final s in _SearchScope.values) s: <String>[],
  };
  String _lastQuery = '';
  _SearchScope _scope = _SearchScope.albums;
  bool _isLoading = false;
  List<JellyfinAlbum> _albumResults = const [];
  List<JellyfinArtist> _artistResults = const [];
  List<JellyfinTrack> _trackResults = const [];
  Object? _error;
  static const int _historyLimit = 10;
  static const String _boxName = 'nautune_search_history';

  @override
  void initState() {
    super.initState();
    _loadRecentQueries();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  String _prefKeyForScope(_SearchScope scope) =>
      'search_history_${scope.name}';

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }
  
  Future<void> _loadRecentQueries() async {
    final box = await _box();
    if (!mounted) return;
    setState(() {
      for (final scope in _SearchScope.values) {
        final raw = box.get(_prefKeyForScope(scope));
        if (raw is List) {
          _recentQueries[scope] = raw.cast<String>();
        } else {
          _recentQueries[scope] = const [];
        }
      }
    });
  }
  
  Future<void> _persistRecentQueries(_SearchScope scope) async {
    final box = await _box();
    await box.put(
      _prefKeyForScope(scope),
      _recentQueries[scope]!,
    );
  }
  
  Future<void> _clearRecentQueries(_SearchScope scope) async {
    if (_recentQueries[scope]!.isEmpty) return;
    setState(() {
      _recentQueries[scope] = <String>[];
    });
    final box = await _box();
    await box.delete(_prefKeyForScope(scope));
  }
  
  Future<void> _rememberQuery(_SearchScope scope, String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final list = _recentQueries[scope]!;
    list.removeWhere((item) => item.toLowerCase() == trimmed.toLowerCase());
    list.insert(0, trimmed);
    while (list.length > _historyLimit) {
      list.removeLast();
    }
    setState(() {
      _recentQueries[scope] = List<String>.from(list);
    });
    await _persistRecentQueries(scope);
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
      });
      return;
    }

    setState(() => _isLoading = true);
    unawaited(_rememberQuery(_scope, trimmed));

    // Demo mode: search bundled showcase data
    if (widget.appState.isDemoMode) {
      if (_scope == _SearchScope.albums) {
        final albums = widget.appState.demoAlbums;
        final matches = albums
            .where((album) =>
                album.name.toLowerCase().contains(lowerQuery) ||
                album.displayArtist.toLowerCase().contains(lowerQuery))
            .toList();
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _albumResults = matches;
          _artistResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      } else if (_scope == _SearchScope.artists) {
        final artists = widget.appState.demoArtists;
        final matches = artists
            .where((artist) => artist.name.toLowerCase().contains(lowerQuery))
            .toList();
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _artistResults = matches;
          _albumResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      } else {
        final tracks = widget.appState.demoTracks;
        final matches = tracks
            .where((track) =>
                track.name.toLowerCase().contains(lowerQuery) ||
                (track.album?.toLowerCase().contains(lowerQuery) ?? false) ||
                track.displayArtist.toLowerCase().contains(lowerQuery))
            .toList();
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _trackResults = matches;
          _albumResults = const [];
          _artistResults = const [];
          _isLoading = false;
        });
      }
      return;
    }
    
    // Offline mode: search downloaded content only
    if (widget.appState.isOfflineMode) {
      try {
        final downloads = widget.appState.downloadService.completedDownloads;
        if (_scope == _SearchScope.albums) {
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
          
          if (!mounted || _lastQuery != trimmed) return;
          setState(() {
            _albumResults = matchingAlbums;
            _artistResults = const [];
            _trackResults = const [];
            _isLoading = false;
          });
        } else if (_scope == _SearchScope.artists) {
          // Search artists in offline mode
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
          
          if (!mounted || _lastQuery != trimmed) return;
          setState(() {
            _albumResults = const [];
            _artistResults = matchingArtists;
            _trackResults = const [];
            _isLoading = false;
          });
        } else {
          final matches = downloads
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
            _albumResults = const [];
            _artistResults = const [];
            _trackResults = matches;
            _isLoading = false;
          });
        }
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
      if (_scope == _SearchScope.albums) {
        final albums = await widget.appState.jellyfinService.searchAlbums(
          libraryId: libraryId,
          query: trimmed,
        );
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _albumResults = albums;
          _artistResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      } else if (_scope == _SearchScope.artists) {
        final artists = await widget.appState.jellyfinService.searchArtists(
          libraryId: libraryId,
          query: trimmed,
        );
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _artistResults = artists;
          _albumResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      } else {
        final tracks = await widget.appState.jellyfinService.searchTracks(
          libraryId: libraryId,
          query: trimmed,
        );
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _trackResults = tracks;
          _albumResults = const [];
          _artistResults = const [];
          _isLoading = false;
        });
      }
      if (!mounted || _lastQuery != trimmed) return;
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

    if (libraryId == null) {
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: SegmentedButton<_SearchScope>(
            segments: const [
              ButtonSegment(
                value: _SearchScope.albums,
                icon: Icon(Icons.album_outlined),
                label: Text('Albums'),
              ),
              ButtonSegment(
                value: _SearchScope.artists,
                icon: Icon(Icons.person_outline),
                label: Text('Artists'),
              ),
              ButtonSegment(
                value: _SearchScope.tracks,
                icon: Icon(Icons.music_note_outlined),
                label: Text('Tracks'),
              ),
            ],
            selected: {_scope},
            onSelectionChanged: (selection) {
              final scope = selection.first;
              setState(() {
                _scope = scope;
                _albumResults = const [];
                _artistResults = const [];
                _trackResults = const [];
              });
              if (_lastQuery.isNotEmpty) {
                _performSearch(_lastQuery);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _controller,
            onSubmitted: _performSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: switch (_scope) {
                _SearchScope.albums => 'Search albums',
                _SearchScope.artists => 'Search artists',
                _SearchScope.tracks => 'Search tracks',
              },
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
        if (_controller.text.trim().isEmpty &&
            (_recentQueries[_scope]?.isNotEmpty ?? false))
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
    final history = _recentQueries[_scope] ?? const <String>[];
    if (history.isEmpty) {
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
                onPressed: () => unawaited(_clearRecentQueries(_scope)),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in history)
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
          switch (_scope) {
            _SearchScope.albums =>
              'Search your library by album name.',
            _SearchScope.artists =>
              'Search your library by artist name.',
            _SearchScope.tracks =>
              'Search across tracks you can play.',
          },
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_scope == _SearchScope.albums) {
      if (_albumResults.isEmpty) {
        return Center(
          child: Text(
            'No albums found for "$_lastQuery"',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: _albumResults.length,
        separatorBuilder: (context, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final album = _albumResults[index];
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
                    builder: (_) => AlbumDetailScreen(
                      album: album,
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    }

    if (_scope == _SearchScope.artists) {
      if (_artistResults.isEmpty) {
        return Center(
          child: Text(
            'No artists found for "$_lastQuery"',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        );
      }

      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        itemCount: _artistResults.length,
        separatorBuilder: (context, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final artist = _artistResults[index];
          
          // Build subtitle with genres and counts
          final subtitleParts = <String>[];
          if (artist.genres != null && artist.genres!.isNotEmpty) {
            subtitleParts.add(artist.genres!.take(3).join(', '));
          }
          if (artist.albumCount != null && artist.albumCount! > 0) {
            subtitleParts.add('${artist.albumCount} albums');
          }
          if (artist.songCount != null && artist.songCount! > 0) {
            subtitleParts.add('${artist.songCount} songs');
          }
          
          final subtitle = subtitleParts.isNotEmpty
              ? subtitleParts.join(' • ')
              : null;
          
          return Card(
            child: ListTile(
              leading: artist.primaryImageTag != null
                  ? CircleAvatar(
                      backgroundImage: NetworkImage(
                        widget.appState.jellyfinService.buildImageUrl(
                          itemId: artist.id,
                          tag: artist.primaryImageTag!,
                          maxWidth: 100,
                        ),
                      ),
                    )
                  : const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
              title: Text(
                artist.name,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF8CB1D9),
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: subtitle != null
                  ? Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF9CC7F2),
                      ),
                    )
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ArtistDetailScreen(
                      artist: artist,
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    }

    if (_trackResults.isEmpty) {
      return Center(
        child: Text(
          'No tracks found for "$_lastQuery"',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _trackResults.length,
      separatorBuilder: (context, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final track = _trackResults[index];
        final subtitleParts = <String>[
          track.displayArtist,
          if (track.album != null && track.album!.isNotEmpty) track.album!,
        ];
        final visibleSubtitleParts =
            subtitleParts.where((part) => part.isNotEmpty).toList();

        return Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.music_note,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            title: Text(
              track.name,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
            subtitle: visibleSubtitleParts.isNotEmpty
                ? Text(
                    visibleSubtitleParts.join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  )
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (track.duration != null)
                  Text(
                    _formatDuration(track.duration!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.more_vert, size: 20),
                  onPressed: () {
                    final parentContext = context;
                    showModalBottomSheet(
                      context: parentContext,
                      builder: (sheetContext) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.play_arrow),
                              title: const Text('Play Next'),
                              onTap: () {
                                Navigator.pop(sheetContext);
                                widget.appState.audioPlayerService.playNext([track]);
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
                                widget.appState.audioPlayerService.addToQueue([track]);
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
                                  appState: widget.appState,
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
                                  final mixTracks = await widget.appState.jellyfinService.getInstantMix(
                                    itemId: track.id,
                                    limit: 50,
                                  );
                                  if (mixTracks.isEmpty) {
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      const SnackBar(
                                        content: Text('No similar tracks found'),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                    return;
                                  }
                                  await widget.appState.audioPlayerService.playTrack(
                                    mixTracks.first,
                                    queueContext: mixTracks,
                                  );
                                  ScaffoldMessenger.of(parentContext).showSnackBar(
                                    SnackBar(
                                      content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                } catch (e) {
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
                                final downloadService = widget.appState.downloadService;
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
                          ],
                        ),
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            onTap: () {
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: _trackResults,
              );
            },
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
      final imageUrl = appState.jellyfinService.buildImageUrl(
        itemId: artist.id,
        tag: tag,
        maxWidth: 400,
      );
      artwork = ClipOval(
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          headers: appState.jellyfinService.imageHeaders(),
          errorBuilder: (context, error, stackTrace) => ClipOval(
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
            child: AspectRatio(
              aspectRatio: 1,
              child: artwork,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            artist.name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.tertiary,  // Ocean blue
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
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
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
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
                  itemCount: downloads.length,
                  itemBuilder: (context, index) {
                    final download = downloads[index];
                    final track = download.track;

                    return ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: theme.colorScheme.primaryContainer,
                        ),
                        child: download.isCompleted
                            ? Icon(Icons.check_circle,
                                color: theme.colorScheme.primary)
                            : download.isDownloading
                                ? CircularProgressIndicator(
                                    value: download.progress,
                                    strokeWidth: 3,
                                  )
                                : download.isFailed
                                    ? Icon(Icons.error,
                                        color: theme.colorScheme.error)
                                    : Icon(Icons.schedule,
                                        color: theme.colorScheme.onPrimaryContainer),
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

// Alphabet scrollbar for quick navigation
class AlphabetScrollbar extends StatefulWidget {
  const AlphabetScrollbar({
    super.key,
    required this.items,
    required this.getItemName,
    required this.scrollController,
    required this.itemHeight,
    required this.crossAxisCount,
  });

  final List items;
  final String Function(dynamic) getItemName;
  final ScrollController scrollController;
  final double itemHeight;
  final int crossAxisCount;

  @override
  State<AlphabetScrollbar> createState() => _AlphabetScrollbarState();
}

class _AlphabetScrollbarState extends State<AlphabetScrollbar> {
  static const _alphabet = ['#', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I',
                             'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S',
                             'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];
  
  String? _activeLetter;
  double _bubbleY = 0.0;

  void _scrollToLetter(String letter) {
    if (widget.items.isEmpty) return;

    int targetIndex = -1;
    for (int i = 0; i < widget.items.length; i++) {
      final itemName = widget.getItemName(widget.items[i]).toUpperCase();
      final firstChar = itemName.isNotEmpty ? itemName[0] : '';

      if (letter == '#') {
        // Looking for numbers
        if (RegExp(r'[0-9]').hasMatch(firstChar)) {
          targetIndex = i;
          break;
        }
      } else if (firstChar == letter) {
        // Exact match found
        targetIndex = i;
        break;
      } else if (firstChar.compareTo(letter) > 0 && !RegExp(r'[0-9]').hasMatch(firstChar)) {
        // No exact match, but this item comes alphabetically after the letter
        // Use this as fallback (first item past the selected letter)
        targetIndex = i;
        break;
      }
    }

    // If still no match and not looking for '#', scroll to end for letters near Z
    if (targetIndex < 0 && letter != '#') {
      targetIndex = widget.items.length - 1;
    }

    if (targetIndex >= 0) {
      final row = targetIndex ~/ widget.crossAxisCount;
      final targetPosition = (row * widget.itemHeight) - 100.0;
      
      // Use jumpTo for immediate response during drag, or animateTo for tap
      if (_activeLetter != null) {
        widget.scrollController.jumpTo(math.max(0, targetPosition));
      } else {
        widget.scrollController.animateTo(
          math.max(0, targetPosition),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _handleInput(Offset localPosition, double height) {
    final double letterHeight = height / _alphabet.length;
    final int index = (localPosition.dy / letterHeight)
        .clamp(0, _alphabet.length - 1)
        .toInt();
    final String letter = _alphabet[index];

    if (_activeLetter != letter) {
      setState(() {
        _activeLetter = letter;
        _bubbleY = localPosition.dy.clamp(0, height - 60);
      });
      _scrollToLetter(letter);
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
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
              // Calculate if we need to reduce letters based on available height
              final availableHeight = constraints.maxHeight;
              final letterHeight = 16.0; // Approximate height per letter
              final maxLetters = (availableHeight / letterHeight).floor();
              
              // If not enough space for all letters, show subset
              List<String> displayLetters = _alphabet;
              if (maxLetters < _alphabet.length && maxLetters > 0) {
                // Show every Nth letter to fit
                final step = (_alphabet.length / maxLetters).ceil();
                displayLetters = [];
                for (int i = 0; i < _alphabet.length; i += step) {
                  displayLetters.add(_alphabet[i]);
                }
              }
              
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _handleInput(details.localPosition, constraints.maxHeight),
                onVerticalDragUpdate: (details) => _handleInput(details.localPosition, constraints.maxHeight),
                onVerticalDragEnd: (_) => setState(() => _activeLetter = null),
                onTapUp: (_) => setState(() => _activeLetter = null),
                child: Container(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    mainAxisSize: MainAxisSize.min,
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
             top: _bubbleY + 10, // Adjust based on layout
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
