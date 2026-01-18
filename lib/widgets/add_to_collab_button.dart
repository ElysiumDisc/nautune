import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../jellyfin/jellyfin_track.dart';
import '../providers/syncplay_provider.dart';

/// A button shown on tracks/albums when a collab session is active.
///
/// Features:
/// - "Add to Collab" with session icon
/// - Appears only when in collab session
/// - Shows loading state when adding
/// - Can be used as button or list tile
class AddToCollabButton extends StatefulWidget {
  const AddToCollabButton({
    super.key,
    required this.tracks,
    this.label = 'Add to Collab',
    this.compact = false,
    this.onAdded,
  });

  final List<JellyfinTrack> tracks;
  final String label;
  final bool compact;
  final VoidCallback? onAdded;

  /// Create for a single track
  factory AddToCollabButton.forTrack(
    JellyfinTrack track, {
    bool compact = false,
    VoidCallback? onAdded,
  }) {
    return AddToCollabButton(
      tracks: [track],
      compact: compact,
      onAdded: onAdded,
    );
  }

  @override
  State<AddToCollabButton> createState() => _AddToCollabButtonState();
}

class _AddToCollabButtonState extends State<AddToCollabButton> {
  bool _isAdding = false;

  Future<void> _addToCollab(SyncPlayProvider provider) async {
    if (_isAdding) return;

    setState(() => _isAdding = true);

    try {
      await provider.addToQueue(widget.tracks);
      widget.onAdded?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.tracks.length == 1
                  ? 'Added to collaborative playlist'
                  : 'Added ${widget.tracks.length} tracks to collaborative playlist',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isAdding = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        if (widget.compact) {
          return _buildCompactButton(context, provider);
        }

        return _buildFullButton(context, provider);
      },
    );
  }

  Widget _buildCompactButton(BuildContext context, SyncPlayProvider provider) {
    final theme = Theme.of(context);

    return IconButton(
      onPressed: _isAdding ? null : () => _addToCollab(provider),
      icon: _isAdding
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            )
          : Icon(
              Icons.playlist_add,
              color: theme.colorScheme.primary,
            ),
      tooltip: widget.label,
    );
  }

  Widget _buildFullButton(BuildContext context, SyncPlayProvider provider) {
    final theme = Theme.of(context);

    return FilledButton.tonalIcon(
      onPressed: _isAdding ? null : () => _addToCollab(provider),
      icon: _isAdding
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            )
          : const Icon(Icons.playlist_add),
      label: Text(widget.label),
    );
  }
}

/// Menu item version for track context menus
class AddToCollabMenuItem extends StatelessWidget {
  const AddToCollabMenuItem({
    super.key,
    required this.track,
    this.onAdded,
  });

  final JellyfinTrack track;
  final VoidCallback? onAdded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        return ListTile(
          leading: Icon(
            Icons.playlist_add,
            color: theme.colorScheme.primary,
          ),
          title: const Text('Add to Collab Playlist'),
          subtitle: Text(
            provider.groupName ?? 'Collaborative Playlist',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          onTap: () async {
            Navigator.of(context).pop(); // Close menu
            try {
              await provider.addTrackToQueue(track);
              onAdded?.call();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Added to collaborative playlist'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to add: $e'),
                    backgroundColor: theme.colorScheme.error,
                  ),
                );
              }
            }
          },
        );
      },
    );
  }
}

/// Indicator shown in library browse when collab is active
class CollabActiveIndicator extends StatelessWidget {
  const CollabActiveIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.group,
                size: 14,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                'Collab Active',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
