import 'package:flutter/material.dart';

import '../models/syncplay_models.dart';
import '../widgets/jellyfin_image.dart';
import 'syncplay_user_avatar.dart';

/// A queue item widget for the collaborative playlist.
///
/// Features:
/// - Track info with album art
/// - User avatar overlay showing who added the track
/// - "Added by [username]" subtitle
/// - Drag handle for reordering
/// - Delete button
class CollabQueueItem extends StatelessWidget {
  const CollabQueueItem({
    super.key,
    required this.track,
    required this.index,
    this.serverUrl,
    this.isCurrentTrack = false,
    this.onTap,
    this.onRemove,
    this.showDragHandle = true,
    this.showRemoveButton = true,
  });

  final SyncPlayTrack track;
  final int index;
  final String? serverUrl;
  final bool isCurrentTrack;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool showDragHandle;
  final bool showRemoveButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: isCurrentTrack
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Playing indicator or drag handle
              if (isCurrentTrack)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Icon(
                    Icons.equalizer,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                )
              else if (showDragHandle)
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(
                      Icons.drag_handle,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

              // Album art with user avatar badge
              _buildArtworkWithBadge(theme),

              const SizedBox(width: 12),

              // Track info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.track.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            isCurrentTrack ? FontWeight.bold : FontWeight.normal,
                        color: isCurrentTrack
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.track.displayArtist,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Added by @${track.addedByUsername}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Duration
              Text(
                _formatDuration(track.track.duration),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              // Remove button
              if (showRemoveButton)
                IconButton(
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.close,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: 'Remove from queue',
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArtworkWithBadge(ThemeData theme) {
    const artworkSize = 48.0;

    // Determine item ID and image tag for JellyfinImage
    final artworkItemId = track.track.albumId ?? track.track.id;
    final artworkImageTag = track.track.albumPrimaryImageTag ?? track.track.primaryImageTag;

    return SizedBox(
      width: artworkSize + 8, // Extra space for badge overflow
      height: artworkSize + 8,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Album artwork
          Positioned(
            left: 0,
            top: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: artworkSize,
                height: artworkSize,
                child: artworkImageTag != null
                    ? JellyfinImage(
                        itemId: artworkItemId,
                        imageTag: artworkImageTag,
                        width: artworkSize,
                        height: artworkSize,
                        boxFit: BoxFit.cover,
                      )
                    : Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
          ),

          // User avatar badge (bottom-right corner)
          Positioned(
            right: 0,
            bottom: 0,
            child: SyncPlayAvatarBadge(
              userId: track.addedByUserId,
              username: track.addedByUsername,
              imageTag: track.addedByImageTag,
              serverUrl: serverUrl,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--:--';

    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

/// A simplified version for the "Now Playing" section
class CollabNowPlayingItem extends StatelessWidget {
  const CollabNowPlayingItem({
    super.key,
    required this.track,
    this.serverUrl,
    this.isPlaying = false,
    this.onPlayPause,
  });

  final SyncPlayTrack track;
  final String? serverUrl;
  final bool isPlaying;
  final VoidCallback? onPlayPause;

  /// Get track duration from the track itself
  Duration? get duration => track.track.duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Currently Playing',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Album art with user badge
              _buildArtwork(theme),
              const SizedBox(width: 16),

              // Track info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.track.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.track.displayArtist,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        SyncPlayAvatarBadge(
                          userId: track.addedByUserId,
                          username: track.addedByUsername,
                          imageTag: track.addedByImageTag,
                          serverUrl: serverUrl,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Added by @${track.addedByUsername}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Show track duration only (not live position)
          if (duration != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _formatDuration(duration!),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildArtwork(ThemeData theme) {
    const size = 80.0;

    // Determine item ID and image tag for JellyfinImage
    final artworkItemId = track.track.albumId ?? track.track.id;
    final artworkImageTag = track.track.albumPrimaryImageTag ?? track.track.primaryImageTag;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: size,
              height: size,
              child: artworkImageTag != null
                  ? JellyfinImage(
                      itemId: artworkItemId,
                      imageTag: artworkImageTag,
                      width: size,
                      height: size,
                      boxFit: BoxFit.cover,
                    )
                  : Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.music_note,
                        size: 40,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
          ),
          // Play/Pause overlay
          if (onPlayPause != null)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onPlayPause,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 40,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
