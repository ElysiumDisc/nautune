import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/now_playing_bar.dart';

class AlbumDetailScreen extends StatefulWidget {
  const AlbumDetailScreen({
    super.key,
    required this.album,
    required this.appState,
  });

  final JellyfinAlbum album;
  final NautuneAppState appState;

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  bool _isLoading = false;
  Object? _error;
  List<JellyfinTrack>? _tracks;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final tracks = await widget.appState.jellyfinService.loadAlbumTracks(
        albumId: widget.album.id,
      );
      if (mounted) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final album = widget.album;

    Widget artwork;
    final tag = album.primaryImageTag;
    if (tag != null && tag.isNotEmpty) {
      final imageUrl = widget.appState.jellyfinService.buildImageUrl(
        itemId: album.id,
        tag: tag,
        maxWidth: 800,
      );
      artwork = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        headers: widget.appState.jellyfinService.imageHeaders(),
        errorBuilder: (_, __, ___) => const _TritonArtwork(),
      );
    } else {
      artwork = const _TritonArtwork();
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  artwork,
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          theme.scaffoldBackgroundColor,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.6, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    album.displayArtist,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (album.productionYear != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${album.productionYear}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_tracks != null && _tracks!.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () async {
                        await widget.appState.audioPlayerService.playAlbum(
                          _tracks!,
                          albumId: album.id,
                          albumName: album.name,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Playing ${album.name}'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play Album'),
                    ),
                ],
              ),
            ),
          ),
          if (_isLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: _ErrorWidget(
                  message: 'Could not load tracks.\n${_error.toString()}',
                  onRetry: _loadTracks,
                ),
              ),
            )
          else if (_tracks == null || _tracks!.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: _EmptyWidget(onRetry: _loadTracks),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final track = _tracks![index];
                    return _TrackTile(
                      track: track,
                      trackNumber: index + 1,
                      onTap: () async {
                        await widget.appState.audioPlayerService.playTrack(
                          track,
                          queueContext: _tracks,
                          albumId: widget.album.id,
                          albumName: widget.album.name,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Playing ${track.name}'),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                    );
                  },
                  childCount: _tracks!.length,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NowPlayingBar(
        audioService: widget.appState.audioPlayerService,
        onTap: () {
          // TODO: Navigate to full now playing screen
        },
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.trackNumber,
    required this.onTap,
  });

  final JellyfinTrack track;
  final int trackNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = track.duration;
    final durationText = duration != null ? _formatDuration(duration) : '—';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  '$trackNumber',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.name,
                      style: theme.textTheme.bodyLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (track.displayArtist.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        track.displayArtist,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                durationText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _ErrorWidget extends StatelessWidget {
  const _ErrorWidget({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(
            'Track list adrift',
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
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _EmptyWidget extends StatelessWidget {
  const _EmptyWidget({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_note_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            'No tracks found',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'This album appears to be empty.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('Refresh'),
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
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.85),
            theme.colorScheme.secondary.withValues(alpha: 0.85),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Text(
          '🔱',
          style: TextStyle(fontSize: 80),
        ),
      ),
    );
  }
}
