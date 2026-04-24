part of '../library_screen.dart';

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
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
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
          void showTrackMenu() {
            HapticService.mediumTap();
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
                                SnackBar(content: Text('Failed: $e'), backgroundColor: Theme.of(parentContext).colorScheme.error),
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
          }
          return RepaintBoundary(
            child: Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onLongPress: showTrackMenu,
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
                          albumId: track.albumId,
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
                    onPressed: showTrackMenu,
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
