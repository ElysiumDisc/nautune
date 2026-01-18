import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/session_provider.dart';
import '../providers/syncplay_provider.dart';
import '../services/deep_link_service.dart';
import '../widgets/collab_queue_item.dart';
import '../widgets/collab_share_sheet.dart';
import '../widgets/syncplay_user_avatar.dart';
import 'library_screen.dart';

/// Main screen for the collaborative playlist session.
///
/// Features:
/// - Shows queue with user avatars
/// - Participant list
/// - Now playing section
/// - Playback controls (Captain) / progress view (Sailor)
/// - QR code + share link buttons
/// - Add tracks button
class CollabPlaylistScreen extends StatefulWidget {
  const CollabPlaylistScreen({super.key});

  @override
  State<CollabPlaylistScreen> createState() => _CollabPlaylistScreenState();
}

class _CollabPlaylistScreenState extends State<CollabPlaylistScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Collaborative Playlist'),
            ),
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.group_off,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No active session',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => _showCreateDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Create Collaborative Playlist'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => _showJoinDialog(context),
                    icon: const Icon(Icons.link),
                    label: const Text('Join via Link'),
                  ),
                ],
              ),
            ),
          );
        }

        final serverUrl = context.read<SessionProvider>().session?.serverUrl;

        return Scaffold(
          appBar: AppBar(
            title: Text(provider.groupName ?? 'Collaborative Playlist'),
            actions: [
              const CollabShareButton(iconOnly: true),
              PopupMenuButton<String>(
                onSelected: (value) => _handleMenuAction(context, value),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'leave',
                    child: Row(
                      children: [
                        Icon(Icons.exit_to_app),
                        SizedBox(width: 12),
                        Text('Leave Session'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              // Participants section
              _buildParticipantsSection(context, provider, serverUrl),

              // Now playing section
              if (provider.currentTrack != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: CollabNowPlayingItem(
                    track: provider.currentTrack!,
                    serverUrl: serverUrl,
                    isPlaying: provider.isPlaying,
                    onPlayPause: provider.togglePlayPause,
                  ),
                ),

              // Playback controls (all participants can control playback)
              _buildPlaybackControls(context, provider),

              const Divider(),

              // Queue header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      'Up Next',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${provider.queue.length} tracks',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _navigateToAddTracks(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Tracks'),
                    ),
                  ],
                ),
              ),

              // Queue list
              Expanded(
                child: provider.queue.isEmpty
                    ? _buildEmptyQueue(context)
                    : _buildQueueList(context, provider, serverUrl),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _navigateToAddTracks(context),
            icon: const Icon(Icons.add),
            label: const Text('Add Tracks'),
          ),
        );
      },
    );
  }

  Widget _buildParticipantsSection(
    BuildContext context,
    SyncPlayProvider provider,
    String? serverUrl,
  ) {
    final theme = Theme.of(context);
    final participants = provider.participants;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Text(
            'Participants:',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 36,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: participants.length,
                itemBuilder: (context, index) {
                  final participant = participants[index];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: '${participant.username}${participant.isGroupLeader ? ' (Captain)' : ''}',
                      child: SyncPlayUserAvatar.fromParticipant(
                        participant,
                        serverUrl: serverUrl,
                        size: 32,
                        showRoleBadge: true,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Text(
            '${participants.length} listening',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackControls(BuildContext context, SyncPlayProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: provider.previousTrack,
            icon: const Icon(Icons.skip_previous),
            iconSize: 32,
          ),
          const SizedBox(width: 16),
          FilledButton(
            onPressed: provider.togglePlayPause,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(16),
            ),
            child: Icon(
              provider.isPlaying ? Icons.pause : Icons.play_arrow,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          IconButton(
            onPressed: provider.nextTrack,
            icon: const Icon(Icons.skip_next),
            iconSize: 32,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyQueue(BuildContext context) {
    final theme = Theme.of(context);

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
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add some tracks to get started!',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueList(
    BuildContext context,
    SyncPlayProvider provider,
    String? serverUrl,
  ) {
    return ReorderableListView.builder(
      itemCount: provider.queue.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        provider.reorderQueue(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final track = provider.queue[index];
        final isCurrentTrack = index == provider.currentTrackIndex;

        return CollabQueueItem(
          key: ValueKey(track.playlistItemId),
          track: track,
          index: index,
          serverUrl: serverUrl,
          isCurrentTrack: isCurrentTrack,
          onTap: () => provider.playTrackAtIndex(index),
          onRemove: () => provider.removeFromQueue(track.playlistItemId),
        );
      },
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const CreateCollabDialog(),
    );
  }

  void _showJoinDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const JoinCollabDialog(),
    );
  }

  void _handleMenuAction(BuildContext context, String action) async {
    final provider = context.read<SyncPlayProvider>();

    switch (action) {
      case 'leave':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Leave Session?'),
            content: const Text(
              'You will be removed from this collaborative playlist session.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Leave'),
              ),
            ],
          ),
        );

        if (confirm == true && context.mounted) {
          await provider.leaveCollabPlaylist();
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }
        break;
    }
  }

  void _navigateToAddTracks(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const LibraryScreen(
          collabBrowseMode: true,
        ),
      ),
    );
  }
}

/// Dialog for creating a new collaborative playlist
class CreateCollabDialog extends StatefulWidget {
  const CreateCollabDialog({super.key});

  @override
  State<CreateCollabDialog> createState() => _CreateCollabDialogState();
}

class _CreateCollabDialogState extends State<CreateCollabDialog> {
  final _nameController = TextEditingController(text: 'My Collab Playlist');
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Collaborative Playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Playlist Name',
              hintText: 'Enter a name for your playlist',
            ),
            autofocus: true,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 16),
          Text(
            'Friends can join by scanning a QR code or using a share link.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isCreating ? null : _createPlaylist,
          child: _isCreating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _createPlaylist() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _isCreating = true);

    try {
      final provider = context.read<SyncPlayProvider>();
      await provider.createCollabPlaylist(name);

      if (mounted) {
        Navigator.of(context).pop();
        // Navigate to the collab playlist screen
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const CollabPlaylistScreen(),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create playlist: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        setState(() => _isCreating = false);
      }
    }
  }
}

/// Dialog for joining a collaborative playlist
class JoinCollabDialog extends StatefulWidget {
  const JoinCollabDialog({
    super.key,
    this.groupId,
  });

  final String? groupId;

  @override
  State<JoinCollabDialog> createState() => _JoinCollabDialogState();
}

class _JoinCollabDialogState extends State<JoinCollabDialog> {
  late final TextEditingController _groupIdController;
  bool _isJoining = false;

  @override
  void initState() {
    super.initState();
    _groupIdController = TextEditingController(text: widget.groupId ?? '');
  }

  @override
  void dispose() {
    _groupIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join Collaborative Playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _groupIdController,
            decoration: const InputDecoration(
              labelText: 'Link or Session ID',
              hintText: 'Paste link or enter session ID',
            ),
            autofocus: widget.groupId == null,
          ),
          const SizedBox(height: 16),
          Text(
            'Paste a share link or enter the session ID directly.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isJoining ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isJoining ? null : _joinPlaylist,
          child: _isJoining
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Join'),
        ),
      ],
    );
  }

  Future<void> _joinPlaylist() async {
    final input = _groupIdController.text.trim();
    if (input.isEmpty) return;

    // Try to parse as a link first, fall back to raw group ID
    final groupId = DeepLinkService.parseJoinLink(input) ?? input;

    setState(() => _isJoining = true);

    try {
      final provider = context.read<SyncPlayProvider>();
      await provider.joinCollabPlaylist(groupId);

      if (mounted) {
        Navigator.of(context).pop();
        // Navigate to the collab playlist screen
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => const CollabPlaylistScreen(),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to join playlist: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        setState(() => _isJoining = false);
      }
    }
  }
}
