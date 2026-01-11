import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final audioService = appState.audioService;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Play Queue'),
        actions: [
          StreamBuilder<List<JellyfinTrack>>(
            stream: audioService.queueStream,
            builder: (context, snapshot) {
              final queue = snapshot.data ?? audioService.queue;
              return Row(
                children: [
                  // Clear queue button
                  if (queue.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.playlist_remove),
                      tooltip: 'Clear Queue',
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Clear Queue'),
                            content: Text(
                              'Remove all ${queue.length} tracks from the queue?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(dialogContext, true),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                        );

                        if (confirmed == true && context.mounted) {
                          audioService.stop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Queue cleared'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                    ),
                  // Save queue as playlist button
                  if (queue.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.playlist_add),
                      tooltip: 'Save Queue as Playlist',
                      onPressed: () async {
                        final nameController = TextEditingController(
                          text: 'Queue Playlist',
                        );
                        
                        final result = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Save Queue as Playlist'),
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
                                onPressed: () => Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(dialogContext, true),
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        );

                        if (result == true && nameController.text.isNotEmpty && context.mounted) {
                          try {
                            await appState.createPlaylist(
                              name: nameController.text,
                              itemIds: queue.map((t) => t.id).toList(),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Saved as "${nameController.text}"'),
                                  backgroundColor: Colors.green,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to save playlist: $e'),
                                  backgroundColor: theme.colorScheme.error,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        }
                      },
                    ),
                  // Track count
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '${queue.length} ${queue.length == 1 ? 'track' : 'tracks'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<List<JellyfinTrack>>(
        stream: audioService.queueStream,
        builder: (context, snapshot) {
          final queue = snapshot.data ?? audioService.queue;
          
          if (queue.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.queue_music,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Queue is empty',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Play a track to see it here',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            );
          }

          return StreamBuilder<JellyfinTrack?>(
            stream: audioService.currentTrackStream,
            builder: (context, trackSnapshot) {
              final currentIndex = audioService.currentIndex;

              return ReorderableListView.builder(
                itemCount: queue.length,
                onReorder: (oldIndex, newIndex) {
                  // Adjust newIndex if moving down
                  if (newIndex > oldIndex) {
                    newIndex -= 1;
                  }
                  audioService.reorderQueue(oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  final track = queue[index];
                  final isCurrentTrack = index == currentIndex;

                  return Dismissible(
                    key: Key('${track.id}-$index'),
                    direction: queue.length > 1 ? DismissDirection.endToStart : DismissDirection.none,
                    background: Container(
                      color: theme.colorScheme.error,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    confirmDismiss: (direction) async {
                      if (isCurrentTrack && queue.length == 1) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Cannot remove the last track')),
                        );
                        return false;
                      }
                      return true;
                    },
                    onDismissed: (direction) {
                      audioService.removeFromQueue(index);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${track.name} removed from queue'),
                          action: SnackBarAction(
                            label: 'UNDO',
                            onPressed: () {
                              // TODO: Implement undo
                            },
                          ),
                        ),
                      );
                    },
                    child: Material(
                      color: isCurrentTrack 
                          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                          : Colors.transparent,
                      child: ListTile(
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ReorderableDragStartListener(
                              index: index,
                              child: Icon(
                                Icons.drag_handle,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (isCurrentTrack)
                              Icon(
                                Icons.play_circle_filled,
                                color: theme.colorScheme.primary,
                                size: 32,
                              )
                            else
                              Container(
                                width: 32,
                                height: 32,
                                alignment: Alignment.center,
                                child: Text(
                                  '${index + 1}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        title: Text(
                          track.name,
                          style: TextStyle(
                            color: isCurrentTrack 
                                ? theme.colorScheme.primary
                                : theme.colorScheme.tertiary,  // Ocean blue for non-current
                            fontWeight: isCurrentTrack 
                                ? FontWeight.bold 
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          track.artists.join(', '),
                          style: TextStyle(
                            color: isCurrentTrack
                                ? theme.colorScheme.primary.withValues(alpha: 0.7)
                                : theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue for non-current
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (track.runTimeTicks != null)
                              Text(
                                _formatDuration(
                                  Duration(microseconds: track.runTimeTicks! ~/ 10),
                                ),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary.withValues(alpha: 0.7),  // Ocean blue
                                ),
                              ),
                            if (!isCurrentTrack) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  if (queue.length > 1) {
                                    audioService.removeFromQueue(index);
                                  }
                                },
                              ),
                            ],
                          ],
                        ),
                        onTap: isCurrentTrack ? null : () {
                          audioService.jumpToQueueIndex(index);
                        },
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
