import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_library.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.appState});

  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final session = appState.session;
        final libraries = appState.libraries;
        final isLoadingLibraries = appState.isLoadingLibraries;
        final libraryError = appState.librariesError;
        final selectedId = appState.selectedLibraryId;
        final albums = appState.albums;
        final isLoadingAlbums = appState.isLoadingAlbums;
        final albumsError = appState.albumsError;

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
        } else {
          body = RefreshIndicator(
            onRefresh: () => appState.refreshLibraries(),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  sliver: SliverToBoxAdapter(
                    child: _Header(
                      username: session?.username ?? 'Explorer',
                      serverUrl: session?.serverUrl ?? '',
                      selectedLibraryName: session?.selectedLibraryName,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    selectedId == null ? 24 : 12,
                  ),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final library = libraries[index];
                        return Padding(
                          padding: EdgeInsets.only(bottom: index == libraries.length - 1 ? 0 : 12),
                          child: _LibraryTile(
                            library: library,
                            groupValue: selectedId,
                            onSelect: () => appState.selectLibrary(library),
                          ),
                        );
                      },
                      childCount: libraries.length,
                    ),
                  ),
                ),
                if (selectedId != null) ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    sliver: SliverToBoxAdapter(
                      child: _AlbumsHeader(
                        libraryName: session?.selectedLibraryName ?? '',
                        isLoading: isLoadingAlbums,
                        onRefresh: () => appState.refreshAlbums(),
                      ),
                    ),
                  ),
                  if (isLoadingAlbums && (albums == null || albums.isEmpty))
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (albumsError != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _AlbumError(
                          message:
                              'We lost sight of your albums.\n${albumsError.toString()}',
                          onRetry: () => appState.refreshAlbums(),
                        ),
                      ),
                    )
                  else if (albums == null || albums.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: const _AlbumEmpty(),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.72,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final album = albums[index];
                            return _AlbumCard(
                              album: album,
                              appState: appState,
                            );
                          },
                          childCount: albums.length,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Nautune'),
            actions: [
              IconButton(
                onPressed: () => appState.logout(),
                icon: const Icon(Icons.logout),
                tooltip: 'Sign out',
              ),
            ],
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: body,
          ),
        );
      },
    );
  }
}

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
          'Ahoy, $username!',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Connected to $serverUrl',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Select your Jellyfin audio library',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        if (selectedLibraryName != null)
          Text(
            'Currently linked: $selectedLibraryName',
            style: theme.textTheme.bodySmall,
          )
        else
          Text(
            'Pick one to sync Nautune with your tunes.',
            style: theme.textTheme.bodySmall,
          ),
        Text(
          'Only audio-compatible libraries are shown.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            'No audio libraries found.',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Add a music, audiobooks, or music videos library in Jellyfin and refresh.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () {
              onRefresh();
            },
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'Signal lost',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                onRetry();
              },
              child: const Text('Retry'),
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

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surface.withOpacity(0.6),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.secondary
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: RadioListTile<String>(
        value: library.id,
        groupValue: groupValue,
        onChanged: (_) => onSelect(),
        title: Text(library.name),
        subtitle: library.collectionType != null
            ? Text(
                library.collectionType!,
                style: theme.textTheme.bodySmall,
              )
            : null,
        secondary: const Icon(Icons.library_music_outlined),
        controlAffinity: ListTileControlAffinity.trailing,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    );
  }
}

class _AlbumsHeader extends StatelessWidget {
  const _AlbumsHeader({
    required this.libraryName,
    required this.isLoading,
    required this.onRefresh,
  });

  final String libraryName;
  final bool isLoading;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Albums',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                libraryName.isEmpty
                    ? 'Surfacing tunes from your deck.'
                    : 'Surfacing tunes from $libraryName.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        if (isLoading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          IconButton(
            tooltip: 'Refresh albums',
            onPressed: () {
              onRefresh();
            },
            icon: const Icon(Icons.refresh),
          ),
      ],
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.appState,
  });

  final JellyfinAlbum album;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget artwork;
    final tag = album.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      final imageUrl = appState.jellyfinService.buildImageUrl(
        itemId: album.id,
        tag: tag,
        maxWidth: 600,
      );
      artwork = ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          headers: appState.jellyfinService.imageHeaders(),
          errorBuilder: (_, __, ___) => const _TritonArtwork(),
        ),
      );
    } else {
      artwork = const _TritonArtwork();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          // Album tap will navigate to detail view in a future iteration.
        },
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: theme.colorScheme.surface.withOpacity(0.6),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: artwork,
              ),
              const SizedBox(height: 12),
              Text(
                album.name,
                style: theme.textTheme.titleMedium,
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
              if (album.productionYear != null) ...[
                const SizedBox(height: 2),
                Text(
                  '${album.productionYear}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumEmpty extends StatelessWidget {
  const _AlbumEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.album_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            'No albums washed ashore yet.',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Add music to this library in Jellyfin and refresh to see it here.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AlbumError extends StatelessWidget {
  const _AlbumError({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(
            'Choppy waters',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              onRetry();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _TritonArtwork extends StatelessWidget {
  const _TritonArtwork();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withOpacity(0.85),
            theme.colorScheme.secondary.withOpacity(0.85),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          '🔱',
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: Colors.white,
              ) ??
              const TextStyle(fontSize: 48),
        ),
      ),
    );
  }
}
