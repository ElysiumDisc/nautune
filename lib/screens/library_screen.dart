import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/now_playing_bar.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _albumsScrollController.addListener(_onAlbumsScroll);
    _playlistsScrollController.addListener(_onPlaylistsScroll);
  }

  @override
  void dispose() {
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
                _Header(
                  username: session?.username ?? 'Explorer',
                  serverUrl: session?.serverUrl ?? '',
                  selectedLibraryName: session?.selectedLibraryName,
                ),
                const SizedBox(height: 16),
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
          body = Column(
            children: [
              Container(
                color: theme.colorScheme.surface,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _Header(
                        username: session?.username ?? 'Explorer',
                        serverUrl: session?.serverUrl ?? '',
                        selectedLibraryName: session?.selectedLibraryName,
                      ),
                    ),
                    TabBar(
                      controller: _tabController,
                      indicatorColor: theme.colorScheme.secondary,
                      labelColor: theme.colorScheme.onSurface,
                      unselectedLabelColor:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      tabs: const [
                        Tab(icon: Icon(Icons.album), text: 'Albums'),
                        Tab(icon: Icon(Icons.person), text: 'Artists'),
                        Tab(icon: Icon(Icons.favorite), text: 'Favorites'),
                        Tab(icon: Icon(Icons.playlist_play), text: 'Playlists'),
                        Tab(icon: Icon(Icons.download), text: 'Downloads'),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Albums Tab
                    _AlbumsTab(
                      albums: albums,
                      isLoading: isLoadingAlbums,
                      error: albumsError,
                      scrollController: _albumsScrollController,
                      onRefresh: () => widget.appState.refreshAlbums(),
                      onAlbumTap: (album) => _navigateToAlbum(context, album),
                      appState: widget.appState,
                    ),
                    // Artists Tab
                    _ArtistsTab(
                      appState: widget.appState,
                    ),
                    // Favorites Tab
                    _FavoritesTab(
                      recentTracks: recentTracks,
                      isLoading: isLoadingRecent,
                      error: recentError,
                      onRefresh: () => widget.appState.refreshRecent(),
                      onTrackTap: (track) => _playTrack(track),
                    ),
                    // Playlists Tab
                    _PlaylistsTab(
                      playlists: playlists,
                      isLoading: isLoadingPlaylists,
                      error: playlistsError,
                      scrollController: _playlistsScrollController,
                      onRefresh: () => widget.appState.refreshPlaylists(),
                    ),
                    // Downloads Tab
                    _DownloadsTab(),
                  ],
                ),
              ),
            ],
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(
              'Nautune',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.secondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            actions: [
              if (selectedId != null)
                IconButton(
                  icon: const Icon(Icons.library_music),
                  onPressed: () => widget.appState.clearLibrarySelection(),
                  tooltip: 'Change Library',
                ),
              IconButton(
                icon: const Icon(Icons.logout),
                onPressed: () => widget.appState.disconnect(),
                tooltip: 'Disconnect',
              ),
            ],
          ),
          body: body,
          bottomNavigationBar: NowPlayingBar(
            audioService: widget.appState.audioPlayerService,
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

class _Header extends StatelessWidget {
  const _Header({
    required this.username,
    required this.serverUrl,
    this.selectedLibraryName,
  });

  final String username;
  final String serverUrl;
  final String? selectedLibraryName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Welcome, $username',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.secondary,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (selectedLibraryName != null) ...[
          const SizedBox(height: 4),
          Text(
            selectedLibraryName!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

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
  });

  final List<JellyfinPlaylist>? playlists;
  final bool isLoading;
  final Object? error;
  final ScrollController scrollController;
  final VoidCallback onRefresh;

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
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: playlists!.length + (isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= playlists!.length) {
            return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
          }
          final playlist = playlists![index];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(Icons.playlist_play, color: Theme.of(context).colorScheme.secondary),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
            ),
          );
        },
      ),
    );
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
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Colors.red.shade300),
            const SizedBox(height: 16),
            const Text('Failed to load favorites'),
            const SizedBox(height: 8),
            ElevatedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }
    if (isLoading && (recentTracks == null || recentTracks!.isEmpty)) return const Center(child: CircularProgressIndicator());
    if (recentTracks == null || recentTracks!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite, size: 64, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            const Text('No recent tracks'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: recentTracks!.length,
        itemBuilder: (context, index) {
          if (index >= recentTracks!.length) {
            return const SizedBox.shrink();
          }
          final track = recentTracks![index];
          final theme = Theme.of(context);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(Icons.music_note, color: theme.colorScheme.secondary),
              title: Text(track.name),
              subtitle: Text(track.displayArtist),
              trailing: track.duration != null ? Text(_formatDuration(track.duration!), style: theme.textTheme.bodySmall) : null,
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
  const _DownloadsTab();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return RefreshIndicator(
      onRefresh: () async {
        // TODO: Implement downloads refresh
      },
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download, size: 64, color: theme.colorScheme.secondary),
            const SizedBox(height: 16),
            Text(
              'Offline Downloads',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Download your favorite albums and tracks\nfor offline listening',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                // TODO: Implement offline mode
              },
              icon: const Icon(Icons.download_for_offline),
              label: const Text('Start Downloading'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                // TODO: Show download settings
              },
              icon: const Icon(Icons.settings),
              label: const Text('Download Settings'),
            ),
          ],
        ),
      ),
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
