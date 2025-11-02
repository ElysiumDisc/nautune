import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'offline_library_screen.dart';
import 'playlist_detail_screen.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.appState});

  final NautuneAppState appState;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _albumsScrollController = ScrollController();
  final ScrollController _playlistsScrollController = ScrollController();
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(_handleTabChange);
    _albumsScrollController.addListener(_onAlbumsScroll);
    _playlistsScrollController.addListener(_onPlaylistsScroll);
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
      // widget.appState.loadMoreAlbums();
    }
  }

  void _onPlaylistsScroll() {
    if (_playlistsScrollController.position.pixels >=
        _playlistsScrollController.position.maxScrollExtent - 200) {
      // Load more playlists when near bottom
      // widget.appState.loadMorePlaylists();
    }
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      _currentTabIndex = _tabController.index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final session = widget.appState.session;
        final libraries = widget.appState.libraries;
        final isLoadingLibraries = widget.appState.isLoadingLibraries;
        final libraryError = widget.appState.librariesError;
        final selectedId = widget.appState.selectedLibraryId;
        final albums = widget.appState.albums;
        final isLoadingAlbums = widget.appState.isLoadingAlbums;
        final albumsError = widget.appState.albumsError;
        final playlists = widget.appState.playlists;
        final isLoadingPlaylists = widget.appState.isLoadingPlaylists;
        final playlistsError = widget.appState.playlistsError;
        final recentTracks = widget.appState.recentTracks;
        final isLoadingRecent = widget.appState.isLoadingRecent;
        final recentError = widget.appState.recentError;

        Widget body;

        if (isLoadingLibraries && (libraries == null || libraries.isEmpty)) {
          body = const Center(child: CircularProgressIndicator());
        } else if (libraryError != null) {
          body = _ErrorState(
            message: 'Could not reach Jellyfin.\n${libraryError.toString()}',
            onRetry: () => widget.appState.refreshLibraries(),
          );
        } else if (libraries == null || libraries.isEmpty) {
          body = _EmptyState(
            onRefresh: () => widget.appState.refreshLibraries(),
          );
        } else if (selectedId == null) {
          // Show library selection
          body = RefreshIndicator(
            onRefresh: () => widget.appState.refreshLibraries(),
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
                        onSelect: () => widget.appState.selectLibrary(library),
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
              _AlbumsTab(
                albums: albums,
                isLoading: isLoadingAlbums,
                error: albumsError,
                scrollController: _albumsScrollController,
                onRefresh: () => widget.appState.refreshAlbums(),
                onAlbumTap: (album) => _navigateToAlbum(context, album),
                appState: widget.appState,
              ),
              _ArtistsTab(
                appState: widget.appState,
              ),
              _SearchTab(appState: widget.appState),
              _FavoritesTab(
                recentTracks: recentTracks,
                isLoading: isLoadingRecent,
                error: recentError,
                onRefresh: () => widget.appState.refreshRecent(),
                onTrackTap: (track) => _playTrack(track),
              ),
              _RecentTab(appState: widget.appState),
              _PlaylistsTab(
                playlists: playlists,
                isLoading: isLoadingPlaylists,
                error: playlistsError,
                scrollController: _playlistsScrollController,
                onRefresh: () => widget.appState.refreshPlaylists(),
                appState: widget.appState,
              ),
              _DownloadsTab(appState: widget.appState),
            ],
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            OfflineLibraryScreen(appState: widget.appState),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Icon(
                      Icons.waves,
                      color: const Color(0xFFB39DDB), // Light purple wavy
                      size: 28,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            SettingsScreen(appState: widget.appState),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                    child: Text(
                      'Nautune',
                      style: GoogleFonts.pacifico(
                        fontSize: 24,
                        color: const Color(0xFFB39DDB), // Light purple wavy
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              if (selectedId != null)
                IconButton(
                  icon: const Icon(Icons.library_books_outlined),
                  tooltip: 'Change Library',
                  onPressed: () => widget.appState.clearLibrarySelection(),
                ),
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: 'Logout',
                onPressed: () => widget.appState.disconnect(),
              ),
            ],
          ),
          body: body,
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NavigationBar(
                selectedIndex: _currentTabIndex,
                onDestinationSelected: (index) {
                  setState(() => _currentTabIndex = index);
                  _tabController.animateTo(index);
                },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.album_outlined),
                    label: 'Albums',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    label: 'Artists',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search),
                    label: 'Search',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.favorite_outline),
                    label: 'Favorites',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history),
                    label: 'Recent',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.queue_music),
                    label: 'Playlists',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.download_outlined),
                    label: 'Downloads',
                  ),
                ],
              ),
              NowPlayingBar(
                audioService: widget.appState.audioPlayerService,
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
          appState: widget.appState,
        ),
      ),
    );
  }

  Future<void> _playTrack(JellyfinTrack track) async {
    try {
      await widget.appState.audioPlayerService.playTrack(
        track,
        queueContext: widget.appState.recentTracks,
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

class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({
    required this.albums,
    required this.isLoading,
    required this.error,
    required this.scrollController,
    required this.onRefresh,
    required this.onAlbumTap,
    required this.appState,
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
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
      child: GridView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.75,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: albums!.length + (isLoading ? 2 : 0),
        itemBuilder: (context, index) {
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
    final imageUrl = album.primaryImageTag != null
        ? appState.buildImageUrl(itemId: album.id, tag: album.primaryImageTag)
        : null;

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
                child: imageUrl != null
                    ? Image.network(
                        imageUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.album, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
                      )
                    : Icon(Icons.album, size: 64, color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(album.name, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (album.artists.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(album.displayArtist, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
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
          // Add create button as first item
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
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
                      appState: appState,
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
  });

  final List<JellyfinTrack>? recentTracks;
  final bool isLoading;
  final Object? error;
  final VoidCallback onRefresh;
  final Function(JellyfinTrack) onTrackTap;

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
            Icon(Icons.favorite_outline, size: 64, color: theme.colorScheme.secondary.withOpacity(0.5)),
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
              leading: Icon(Icons.music_note, color: theme.colorScheme.secondary),
              title: Text(track.name),
              subtitle: Text(track.displayArtist),
              trailing: track.duration != null
                  ? Text(
                      _formatDuration(track.duration!),
                      style: theme.textTheme.bodySmall,
                    )
                  : null,
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
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text('Recently Played'),
                      icon: Icon(Icons.history, size: 18),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text('Recently Added'),
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
            Icon(Icons.history, size: 64, color: theme.colorScheme.secondary.withOpacity(0.5)),
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
              title: Text(track.name),
              subtitle: Text(track.displayArtist),
              trailing: track.duration != null
                  ? Text(
                      _formatDuration(track.duration!),
                      style: theme.textTheme.bodySmall,
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
            Icon(Icons.album, size: 64, color: theme.colorScheme.secondary.withOpacity(0.5)),
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
                    appState: widget.appState,
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
  const _ArtistsTab({required this.appState});
  
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artists = appState.artists;
    final isLoading = appState.isLoadingArtists;
    final error = appState.artistsError;
    
    if (isLoading && artists == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (error != null && artists == null) {
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
                error.toString(),
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (artists == null || artists.isEmpty) {
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
      onRefresh: () => appState.refreshLibraryData(),
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.75,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: artists.length,
        itemBuilder: (context, index) {
          final artist = artists[index];
          return _ArtistCard(artist: artist, appState: appState);
        },
      ),
    );
  }
}

enum _SearchScope { albums, artists }

class _SearchTab extends StatefulWidget {
  const _SearchTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final TextEditingController _controller = TextEditingController();
  List<JellyfinAlbum> _albumResults = const [];
  List<JellyfinArtist> _artistResults = const [];
  bool _isLoading = false;
  Object? _error;
  String _lastQuery = '';
  _SearchScope _scope = _SearchScope.albums;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    setState(() {
      _lastQuery = trimmed;
      _error = null;
    });

    if (trimmed.isEmpty) {
      setState(() {
        _albumResults = const [];
        _artistResults = const [];
        _isLoading = false;
      });
      return;
    }

    final libraryId = widget.appState.session?.selectedLibraryId;
    if (libraryId == null) {
      setState(() {
        _error = 'Select a music library to search.';
        _albumResults = const [];
        _artistResults = const [];
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);
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
          _isLoading = false;
        });
      } else {
        final artists = await widget.appState.jellyfinService.searchArtists(
          libraryId: libraryId,
          query: trimmed,
        );
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _artistResults = artists;
          _albumResults = const [];
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
            ],
            selected: {_scope},
            onSelectionChanged: (selection) {
              final scope = selection.first;
              setState(() {
                _scope = scope;
                _albumResults = const [];
                _artistResults = const [];
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
              hintText: _scope == _SearchScope.albums
                  ? 'Search albums'
                  : 'Search artists',
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

  Widget _buildResults(ThemeData theme) {
    if (_lastQuery.isEmpty) {
      return Center(
        child: Text(
          _scope == _SearchScope.albums
              ? 'Search your library by album name.'
              : 'Search your library by artist name.',
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
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final album = _albumResults[index];
          return Card(
            child: ListTile(
              leading: const Icon(Icons.album_outlined),
              title: Text(album.name),
              subtitle: Text(album.displayArtist),
              trailing:
                  album.productionYear != null ? Text('${album.productionYear}') : null,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AlbumDetailScreen(
                      album: album,
                      appState: widget.appState,
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    }

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
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final artist = _artistResults[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(artist.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ArtistDetailScreen(
                    artist: artist,
                    appState: widget.appState,
                  ),
                ),
              );
            },
          ),
        );
      },
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
          errorBuilder: (_, __, ___) => Container(
            color: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.person,
              size: 48,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      );
    } else {
      artwork = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.primaryContainer,
        ),
        child: Icon(
          Icons.person,
          size: 48,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      );
    }

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailScreen(
              artist: artist,
              appState: appState,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.displayArtist,
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
                              tooltip: 'Retry',
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
                                      .deleteDownload(track.id);
                                }
                              },
                              tooltip: 'Delete',
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
