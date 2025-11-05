import 'dart:async';
import 'dart:ui' show FontFeature;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';
import '../widgets/add_to_playlist_dialog.dart';
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
  List<Color>? _paletteColors;

  @override
  void initState() {
    super.initState();
    _loadTracks();
    _extractColors();
  }

  Future<void> _extractColors() async {
    final tag = widget.album.primaryImageTag;
    if (tag == null || tag.isEmpty) return;

    try {
      final imageUrl = widget.appState.jellyfinService.buildImageUrl(
        itemId: widget.album.id,
        tag: tag,
        maxWidth: 100,
      );
      
      final imageProvider = NetworkImage(
        imageUrl,
        headers: widget.appState.jellyfinService.imageHeaders(),
      );
      
      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        completer.complete(info.image);
        imageStream.removeListener(listener);
      });
      
      imageStream.addListener(listener);
      final image = await completer.future;
      
      final ByteData? byteData = await image.toByteData();
      if (byteData == null) return;
      
      final pixels = byteData.buffer.asUint8List();
      final colors = <Color>[];
      
      // Sample colors from the image
      for (int i = 0; i < pixels.length; i += 400) {
        if (i + 2 < pixels.length) {
          final r = pixels[i];
          final g = pixels[i + 1];
          final b = pixels[i + 2];
          colors.add(Color.fromRGBO(r, g, b, 1.0));
        }
      }
      
      // Sort by luminance to get darker colors
      colors.sort((a, b) {
        final lumA = (0.299 * (a.r * 255.0).round() + 0.587 * (a.g * 255.0).round() + 0.114 * (a.b * 255.0).round());
        final lumB = (0.299 * (b.r * 255.0).round() + 0.587 * (b.g * 255.0).round() + 0.114 * (b.b * 255.0).round());
        return lumA.compareTo(lumB);
      });
      
      if (mounted && colors.isNotEmpty) {
        setState(() {
          _paletteColors = colors;
        });
      }
    } catch (e) {
      debugPrint('Failed to extract colors: $e');
    }
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      List<JellyfinTrack> tracks;
      
      // Check if offline mode - load from downloads
      if (widget.appState.isOfflineMode || !widget.appState.networkAvailable) {
        // Get all downloaded tracks for this album
        final downloads = widget.appState.downloadService.completedDownloads;
        tracks = downloads
            .where((d) => d.track.albumId == widget.album.id)
            .map((d) => d.track)
            .toList();
        
        if (tracks.isEmpty) {
          throw Exception('No downloaded tracks found for this album');
        }
      } else {
        // Online mode - fetch from Jellyfin
        tracks = await widget.appState.jellyfinService.loadAlbumTracks(
          albumId: widget.album.id,
        );
      }
      
      final sorted = List<JellyfinTrack>.from(tracks)
        ..sort((a, b) {
          final discA = a.discNumber ?? 0;
          final discB = b.discNumber ?? 0;
          if (discA != discB) {
            return discA.compareTo(discB);
          }
          final trackA = a.indexNumber ?? 0;
          final trackB = b.indexNumber ?? 0;
          if (trackA != trackB) {
            return trackA.compareTo(trackB);
          }
          return a.name.compareTo(b.name);
        });
      if (mounted) {
        setState(() {
          _tracks = sorted;
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
    final isDesktop = MediaQuery.of(context).size.width > 600;
    final List<JellyfinTrack> tracks = _tracks ?? const <JellyfinTrack>[];
    final hasMultipleDiscs = tracks
        .map((t) => t.discNumber)
        .whereType<int>()
        .toSet()
        .length >
        1;

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
      body: Container(
        decoration: BoxDecoration(
          gradient: _paletteColors != null && _paletteColors!.length >= 3
              ? LinearGradient(
                  colors: [
                    theme.scaffoldBackgroundColor,
                    _paletteColors![_paletteColors!.length ~/ 2].withValues(alpha: 0.3),
                    _paletteColors![0].withValues(alpha: 0.6),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.5, 1.0],
                )
              : null,
        ),
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: isDesktop ? 350 : 300,
            pinned: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            actions: [
              // Shuffle button
              IconButton(
                icon: const Text(
                  '🌊🌊',
                  style: TextStyle(fontSize: 20),
                ),
                onPressed: () {
                  if (_tracks != null && _tracks!.isNotEmpty) {
                    widget.appState.audioService.playShuffled(_tracks!);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add),
                onPressed: () async {
                  await showAddToPlaylistDialog(
                    context: context,
                    appState: widget.appState,
                    album: widget.album,
                  );
                },
              ),
            ],
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            try {
                              await widget.appState.audioPlayerService.playAlbum(
                                _tracks!,
                                albumId: album.id,
                                albumName: album.name,
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
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play Album'),
                        ),
                        const SizedBox(width: 12),
                        ListenableBuilder(
                          listenable: widget.appState.downloadService,
                          builder: (context, _) {
                            final allDownloaded = _tracks!.every(
                              (track) => widget.appState.downloadService
                                  .isDownloaded(track.id),
                            );
                            final anyDownloading = _tracks!.any(
                              (track) {
                                final download = widget.appState.downloadService
                                    .getDownload(track.id);
                                return download != null &&
                                    (download.isDownloading || download.isQueued);
                              },
                            );

                            if (allDownloaded) {
                              return OutlinedButton.icon(
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Delete Downloads'),
                                      content: Text(
                                          'Delete all ${_tracks!.length} downloaded tracks from this album?'),
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
                                  if (confirm == true && mounted) {
                                    for (final track in _tracks!) {
                                      await widget.appState.downloadService
                                          .deleteDownload(track.id);
                                    }
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Album downloads deleted'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.download_done),
                                label: const Text('Downloaded'),
                              );
                            }

                            return OutlinedButton.icon(
                              onPressed: anyDownloading
                                  ? null
                                  : () async {
                                      await widget.appState.downloadService
                                          .downloadAlbum(album);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                                'Downloading ${_tracks!.length} tracks from ${album.name}'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    },
                              icon: Icon(anyDownloading
                                  ? Icons.downloading
                                  : Icons.download),
                              label: Text(anyDownloading
                                  ? 'Downloading...'
                                  : 'Download Album'),
                            );
                          },
                        ),
                      ],
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
                    final currentTracks = tracks;
                    if (index >= currentTracks.length) {
                      return const SizedBox.shrink();
                    }
                    final track = currentTracks[index];
                    final discKey = track.discNumber ?? 1;
                    final tracksBeforeDisc = currentTracks
                        .take(index)
                        .where((t) => (t.discNumber ?? 1) == discKey)
                        .length;
                    final fallbackNumber = tracksBeforeDisc + 1;
                    final trackNumber =
                        track.effectiveTrackNumber(fallbackNumber);
                    final displayNumber =
                        trackNumber.toString().padLeft(2, '0');
                    final previousDisc = index == 0
                        ? null
                        : (currentTracks[index - 1].discNumber ?? 1);
                    final showDiscHeader = hasMultipleDiscs &&
                        (index == 0 || discKey != previousDisc);

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showDiscHeader) ...[
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 16,
                              bottom: 8,
                              left: 8,
                            ),
                            child: Text(
                              'Disc $discKey',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color:
                                    theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        _TrackTile(
                          track: track,
                          displayTrackNumber: displayNumber,
                          appState: widget.appState,
                          onTap: () async {
                            try {
                              await widget.appState.audioPlayerService
                                  .playTrack(
                                track,
                                queueContext: currentTracks,
                                albumId: widget.album.id,
                                albumName: widget.album.name,
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
                          },
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                  childCount: tracks.length,
                ),
              ),
            ),
        ],
        ),
      ),
      bottomNavigationBar: NowPlayingBar(
        audioService: widget.appState.audioPlayerService,
        appState: widget.appState,
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.displayTrackNumber,
    required this.onTap,
    required this.appState,
  });

  final JellyfinTrack track;
  final String displayTrackNumber;
  final VoidCallback onTap;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = track.duration;
    final durationText =
        duration != null ? _formatDuration(duration) : '--:--';
    final showArtist = track.artists.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  displayTrackNumber,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                    fontFeatures: const [FontFeature.tabularFigures()],
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
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.tertiary,  // Ocean blue
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showArtist) ...[
                      const SizedBox(height: 2),
                      Text(
                        track.displayArtist,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.tertiary.withValues(alpha: 0.6),  // Ocean blue dimmer
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                durationText,
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
            'This album appears to be empty.\nIf tracks exist in Jellyfin, make sure the album has a Music Album folder structure and rescan the library.',
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
    return Image.asset(
      'assets/no_album_art.png',
      fit: BoxFit.cover,
    );
  }
}
