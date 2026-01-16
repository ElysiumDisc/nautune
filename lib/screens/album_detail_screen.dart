import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui show FontFeature, Image;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/share_service.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';

/// Top-level function for compute() - extracts colors from image bytes in isolate
List<int> _extractColorsFromBytes(Uint8List pixels) {
  final colors = <int>[];

  // Sample colors from the image (RGBA format)
  for (int i = 0; i < pixels.length; i += 400) {
    if (i + 2 < pixels.length) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      // Store as ARGB int
      colors.add(0xFF000000 | (r << 16) | (g << 8) | b);
    }
  }

  // Sort by luminance to get darker colors first
  colors.sort((a, b) {
    final rA = (a >> 16) & 0xFF;
    final gA = (a >> 8) & 0xFF;
    final bA = a & 0xFF;
    final rB = (b >> 16) & 0xFF;
    final gB = (b >> 8) & 0xFF;
    final bB = b & 0xFF;
    final lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA;
    final lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB;
    return lumA.compareTo(lumB);
  });

  return colors;
}

class AlbumDetailScreen extends StatefulWidget {
  const AlbumDetailScreen({
    super.key,
    required this.album,
  });

  final JellyfinAlbum album;

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  // Static LRU cache for palette colors - shared with FullPlayerScreen
  static final Map<String, List<Color>> _paletteCache = {};
  static const int _maxCacheSize = 50;

  bool _isLoading = false;
  Object? _error;
  List<JellyfinTrack>? _tracks;
  List<Color>? _paletteColors;
  NautuneAppState? _appState;
  bool? _previousOfflineMode;
  bool? _previousNetworkAvailable;
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get appState with listening enabled
    final currentAppState = Provider.of<NautuneAppState>(context, listen: true);

    if (!_hasInitialized) {
      // First time initialization
      _appState = currentAppState;
      _previousOfflineMode = currentAppState.isOfflineMode;
      _previousNetworkAvailable = currentAppState.networkAvailable;
      _hasInitialized = true;
      _loadTracks();
      _extractColors();
    } else {
      // Check if connectivity state changed
      _appState = currentAppState;
      final currentOfflineMode = currentAppState.isOfflineMode;
      final currentNetworkAvailable = currentAppState.networkAvailable;

      if (_previousOfflineMode != currentOfflineMode ||
          _previousNetworkAvailable != currentNetworkAvailable) {
        debugPrint('🔄 AlbumDetail: Connectivity changed (offline: $_previousOfflineMode -> $currentOfflineMode, network: $_previousNetworkAvailable -> $currentNetworkAvailable)');
        _previousOfflineMode = currentOfflineMode;
        _previousNetworkAvailable = currentNetworkAvailable;

        // Reload tracks when connectivity changes
        _loadTracks();
      }
    }
  }

  Future<void> _extractColors() async {
    final tag = widget.album.primaryImageTag;
    if (tag == null || tag.isEmpty) return;
    if (_appState == null) return;

    // Check cache first - avoids expensive color extraction
    final cacheKey = '${widget.album.id}-$tag';
    final cached = _paletteCache[cacheKey];
    if (cached != null) {
      if (mounted) {
        setState(() {
          _paletteColors = cached;
        });
      }
      return;
    }

    try {
      final imageUrl = _appState!.jellyfinService.buildImageUrl(
        itemId: widget.album.id,
        tag: tag,
        maxWidth: 100,
      );

      final imageProvider = NetworkImage(
        imageUrl,
        headers: _appState!.jellyfinService.imageHeaders(),
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

      // Process colors in isolate to avoid UI jank
      final colorInts = await compute(_extractColorsFromBytes, pixels);

      // Convert int colors back to Color objects
      final colors = colorInts.map((c) => Color(c)).toList();

      // Cache the extracted colors
      if (colors.isNotEmpty) {
        if (_paletteCache.length >= _maxCacheSize) {
          final oldestKey = _paletteCache.keys.first;
          _paletteCache.remove(oldestKey);
        }
        _paletteCache[cacheKey] = colors;
      }

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
    if (_appState == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      List<JellyfinTrack> tracks;

      if (_appState!.isDemoMode) {
        tracks = await _appState!.getAlbumTracks(widget.album.id);
        if (tracks.isEmpty) {
          throw Exception('Demo content unavailable for this album');
        }
      } else if (_appState!.isOfflineMode ||
          !_appState!.networkAvailable) {
        // Get all downloaded tracks for this album
        final downloads = _appState!.downloadService.completedDownloads;
        tracks = downloads
            .where((d) => d.track.albumId == widget.album.id)
            .map((d) => d.track)
            .toList();
        
        if (tracks.isEmpty) {
          throw Exception('No downloaded tracks found for this album');
        }
      } else {
        // Online mode - fetch from Jellyfin
        tracks = await _appState!.jellyfinService.loadAlbumTracks(
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
      artwork = JellyfinImage(
        itemId: album.id,
        imageTag: tag,
        maxWidth: 800,
        boxFit: BoxFit.cover,
        errorBuilder: (context, url, error) => const _TritonArtwork(),
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
              // Instant Mix button
              IconButton(
                icon: const Icon(Icons.auto_awesome),
                tooltip: 'Instant Mix',
                onPressed: () async {
                  try {
                    // Show loading indicator
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Creating instant mix...'),
                        duration: Duration(seconds: 1),
                      ),
                    );

                    // Get instant mix from Jellyfin
                    final mixTracks = await _appState!.jellyfinService.getInstantMix(
                      itemId: widget.album.id,
                      limit: 50,
                    );

                    if (mixTracks.isEmpty) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No similar tracks found'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }

                    // Start playing the mix
                    await _appState!.audioPlayerService.playTrack(
                      mixTracks.first,
                      queueContext: mixTracks,
                    );

                    if (!context.mounted) return;
                    
                    // Simple notification without persistent action button
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Failed to create mix: $e'),
                        backgroundColor: Theme.of(context).colorScheme.error,
                      ),
                    );
                  }
                },
              ),
              // Shuffle button
              IconButton(
                icon: const Icon(Icons.shuffle),
                tooltip: 'Shuffle',
                onPressed: () {
                  if (_tracks != null && _tracks!.isNotEmpty) {
                    _appState!.audioService.playShuffled(_tracks!);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add),
                tooltip: 'Add to Playlist',
                onPressed: () async {
                  await showAddToPlaylistDialog(
                    context: context,
                    appState: _appState!,
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
                              await _appState!.audioPlayerService.playAlbum(
                                _tracks!,
                                albumId: album.id,
                                albumName: album.name,
                              );
                            } catch (error) {
                              if (!context.mounted) return;
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
                          listenable: _appState!.downloadService,
                          builder: (context, _) {
                            final allDownloaded = _tracks!.every(
                              (track) => _appState!.downloadService
                                  .isDownloaded(track.id),
                            );
                            final anyDownloading = _tracks!.any(
                              (track) {
                                final download = _appState!.downloadService
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
                                  if (!context.mounted) return;
                                  if (confirm == true) {
                                    for (final track in _tracks!) {
                                      await _appState!.downloadService
                                          .deleteDownloadReference(track.id, album.id); // Use new method
                                    }
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Album downloads deleted'),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
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
                                      await _appState!.downloadService
                                          .downloadAlbum(album);
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Downloading ${_tracks!.length} tracks from ${album.name}'),
                                          duration: const Duration(seconds: 2),
                                        ),
                                      );
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
                          appState: _appState!,
                          onTap: () async {
                            try {
                              await _appState!.audioPlayerService
                                  .playTrack(
                                track,
                                queueContext: currentTracks,
                                albumId: widget.album.id,
                                albumName: widget.album.name,
                              );
                            } catch (error) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Could not start playback: $error'),
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                        ),
                        if (index < currentTracks.length - 1)
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            indent: 72,
                            endIndent: 16,
                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                          ),
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
      bottomNavigationBar: _appState != null
          ? NowPlayingBar(
              audioService: _appState!.audioPlayerService,
              appState: _appState!,
            )
          : null,
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

    return StreamBuilder<JellyfinTrack?>(
      stream: appState.audioPlayerService.currentTrackStream,
      builder: (context, snapshot) {
        final isPlayingTrack = snapshot.data?.id == track.id;
        
        return Material(
          color: isPlayingTrack 
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2) 
              : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: isPlayingTrack
                        ? Icon(
                            Icons.equalizer,
                            color: theme.colorScheme.primary,
                            size: 20,
                          )
                        : Text(
                            displayTrackNumber,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.tertiary.withValues(alpha: 0.7),
                              fontFeatures: const [ui.FontFeature.tabularFigures()],
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
                            color: isPlayingTrack 
                                ? theme.colorScheme.primary 
                                : theme.colorScheme.tertiary,
                            fontWeight: isPlayingTrack ? FontWeight.bold : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (showArtist) ...[
                          const SizedBox(height: 2),
                          Text(
                            track.displayArtist,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: isPlayingTrack
                                  ? theme.colorScheme.primary.withValues(alpha: 0.8)
                                  : theme.colorScheme.tertiary.withValues(alpha: 0.6),
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
                      color: isPlayingTrack
                          ? theme.colorScheme.primary.withValues(alpha: 0.8)
                          : theme.colorScheme.tertiary.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(
                      Icons.more_vert, 
                      size: 20,
                      color: isPlayingTrack ? theme.colorScheme.primary : null,
                    ),
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

                                    // Simple notification without persistent action button
                                    ScaffoldMessenger.of(parentContext).showSnackBar(
                                      SnackBar(
                                        content: Text('Playing instant mix (${mixTracks.length} tracks)'),
                                        duration: const Duration(seconds: 2),
                                        behavior: SnackBarBehavior.floating,
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
                                      // User cancelled - no feedback needed
                                      break;
                                    case ShareResult.notDownloaded:
                                      // Offer to download first
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
      },
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
