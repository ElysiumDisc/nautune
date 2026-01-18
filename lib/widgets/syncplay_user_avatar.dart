import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/syncplay_models.dart';

/// A user avatar widget for SyncPlay participants.
///
/// Features:
/// - User profile image from Jellyfin
/// - Role badge (Captain crown / Sailor anchor)
/// - Configurable size
/// - Fallback initials when no image available
class SyncPlayUserAvatar extends StatelessWidget {
  const SyncPlayUserAvatar({
    super.key,
    required this.userId,
    required this.username,
    this.imageTag,
    this.serverUrl,
    this.role,
    this.size = 40,
    this.showRoleBadge = true,
    this.borderColor,
    this.borderWidth = 2,
  });

  final String userId;
  final String username;
  final String? imageTag;
  final String? serverUrl;
  final SyncPlayRole? role;
  final double size;
  final bool showRoleBadge;
  final Color? borderColor;
  final double borderWidth;

  /// Create from a SyncPlayParticipant
  factory SyncPlayUserAvatar.fromParticipant(
    SyncPlayParticipant participant, {
    String? serverUrl,
    double size = 40,
    bool showRoleBadge = true,
  }) {
    return SyncPlayUserAvatar(
      userId: participant.userId,
      username: participant.username,
      imageTag: participant.userImageTag,
      serverUrl: serverUrl,
      role: participant.role,
      size: size,
      showRoleBadge: showRoleBadge,
    );
  }

  String? get _imageUrl {
    if (imageTag == null || serverUrl == null) return null;
    return '$serverUrl/Users/$userId/Images/Primary?tag=$imageTag';
  }

  String get _initials {
    if (username.isEmpty) return '?';
    final parts = username.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return username.substring(0, username.length.clamp(1, 2)).toUpperCase();
  }

  Color _getAvatarColor(BuildContext context) {
    // Generate a consistent color based on userId
    final hash = userId.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.6, 0.5).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avatarColor = _getAvatarColor(context);

    Widget avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
      ),
      child: ClipOval(
        child: _imageUrl != null
            ? CachedNetworkImage(
                imageUrl: _imageUrl!,
                fit: BoxFit.cover,
                placeholder: (context, url) => _buildInitialsAvatar(avatarColor),
                errorWidget: (context, url, error) =>
                    _buildInitialsAvatar(avatarColor),
              )
            : _buildInitialsAvatar(avatarColor),
      ),
    );

    if (showRoleBadge && role != null) {
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: _buildRoleBadge(theme),
          ),
        ],
      );
    }

    return avatar;
  }

  Widget _buildInitialsAvatar(Color backgroundColor) {
    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: Text(
        _initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.4,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildRoleBadge(ThemeData theme) {
    final badgeSize = size * 0.4;
    final isCaptain = role == SyncPlayRole.captain;

    return Container(
      width: badgeSize,
      height: badgeSize,
      decoration: BoxDecoration(
        color: isCaptain ? Colors.amber : theme.colorScheme.primary,
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.scaffoldBackgroundColor,
          width: 1.5,
        ),
      ),
      child: Icon(
        isCaptain ? Icons.star : Icons.anchor,
        size: badgeSize * 0.6,
        color: isCaptain ? Colors.white : Colors.white,
      ),
    );
  }
}

/// A row of overlapping user avatars for displaying participants
class SyncPlayAvatarStack extends StatelessWidget {
  const SyncPlayAvatarStack({
    super.key,
    required this.participants,
    this.serverUrl,
    this.maxAvatars = 5,
    this.avatarSize = 32,
    this.overlap = 0.3,
    this.showCount = true,
  });

  final List<SyncPlayParticipant> participants;
  final String? serverUrl;
  final int maxAvatars;
  final double avatarSize;
  final double overlap; // 0.0 to 1.0 - percentage of overlap
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayCount = participants.length.clamp(0, maxAvatars);
    final overflowCount = participants.length - maxAvatars;
    final overlapOffset = avatarSize * (1 - overlap);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: overlapOffset * displayCount + avatarSize * overlap,
          height: avatarSize,
          child: Stack(
            children: [
              for (int i = 0; i < displayCount; i++)
                Positioned(
                  left: i * overlapOffset,
                  child: SyncPlayUserAvatar.fromParticipant(
                    participants[i],
                    serverUrl: serverUrl,
                    size: avatarSize,
                    showRoleBadge: false,
                  ),
                ),
            ],
          ),
        ),
        if (showCount || overflowCount > 0) ...[
          const SizedBox(width: 8),
          Text(
            overflowCount > 0
                ? '+$overflowCount'
                : '${participants.length} listening',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// Small avatar badge overlay for track artwork
class SyncPlayAvatarBadge extends StatelessWidget {
  const SyncPlayAvatarBadge({
    super.key,
    required this.userId,
    required this.username,
    this.imageTag,
    this.serverUrl,
    this.size = 24,
  });

  final String userId;
  final String username;
  final String? imageTag;
  final String? serverUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.surface,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SyncPlayUserAvatar(
        userId: userId,
        username: username,
        imageTag: imageTag,
        serverUrl: serverUrl,
        size: size,
        showRoleBadge: false,
      ),
    );
  }
}
