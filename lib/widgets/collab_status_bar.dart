import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/syncplay_models.dart';
import '../providers/syncplay_provider.dart';
import 'syncplay_user_avatar.dart';

/// A compact status bar shown when in a collaborative playlist session.
///
/// Features:
/// - Group name
/// - Participant count and avatars
/// - Role badge (Captain/Sailor)
/// - Tap to open collab playlist screen
class CollabStatusBar extends StatelessWidget {
  const CollabStatusBar({
    super.key,
    this.onTap,
    this.serverUrl,
  });

  final VoidCallback? onTap;
  final String? serverUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        return Material(
          color: theme.colorScheme.primaryContainer,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  // Collab icon
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.group,
                      size: 16,
                      color: theme.colorScheme.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Group name and participant count
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          provider.groupName ?? 'Collaborative Playlist',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            _buildRoleBadge(context, provider.role),
                            const SizedBox(width: 8),
                            Text(
                              '${provider.participantCount} listening',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Participant avatars
                  if (provider.participants.isNotEmpty)
                    SyncPlayAvatarStack(
                      participants: provider.participants,
                      serverUrl: serverUrl,
                      maxAvatars: 3,
                      avatarSize: 28,
                      showCount: false,
                    ),

                  const SizedBox(width: 8),

                  // Arrow indicator
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRoleBadge(BuildContext context, SyncPlayRole role) {
    final theme = Theme.of(context);
    final isCaptain = role == SyncPlayRole.captain;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isCaptain
            ? Colors.amber.withValues(alpha: 0.2)
            : theme.colorScheme.primary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCaptain ? Icons.star : Icons.anchor,
            size: 12,
            color: isCaptain
                ? Colors.amber.shade700
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            isCaptain ? 'Captain' : 'Sailor',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isCaptain
                  ? Colors.amber.shade700
                  : theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// A minimal indicator for the now playing bar
class CollabIndicator extends StatelessWidget {
  const CollabIndicator({
    super.key,
    this.size = 20,
  });

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        return Container(
          padding: EdgeInsets.all(size * 0.15),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(size * 0.25),
          ),
          child: Icon(
            Icons.group,
            size: size * 0.7,
            color: theme.colorScheme.onPrimary,
          ),
        );
      },
    );
  }
}

/// A floating action button indicator when collab is active
class CollabFABIndicator extends StatelessWidget {
  const CollabFABIndicator({
    super.key,
    this.onTap,
  });

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        if (!provider.isInSession) {
          return const SizedBox.shrink();
        }

        return FloatingActionButton.small(
          onPressed: onTap,
          backgroundColor: theme.colorScheme.primaryContainer,
          foregroundColor: theme.colorScheme.onPrimaryContainer,
          child: Badge(
            label: Text('${provider.participantCount}'),
            child: const Icon(Icons.group),
          ),
        );
      },
    );
  }
}
