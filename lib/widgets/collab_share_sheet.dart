import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/syncplay_provider.dart';

/// A bottom sheet for sharing a collaborative playlist session.
///
/// Features:
/// - QR code for easy scanning
/// - Share link button (copies to clipboard / native share)
/// - Session code display
/// - Instructions for joining
class CollabShareSheet extends StatelessWidget {
  const CollabShareSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const CollabShareSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);

    return Consumer<SyncPlayProvider>(
      builder: (context, provider, _) {
        final shareLink = provider.shareLink;
        final shareUrl = provider.shareUrl;
        final groupId = provider.groupId;
        final groupName = provider.groupName ?? 'Collaborative Playlist';

        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: mediaQuery.padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 24),

              // Title
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.share,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Share Session',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          groupName,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // QR Code
              if (shareLink != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: shareLink,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                    errorStateBuilder: (ctx, err) => const Center(
                      child: Text('Error generating QR code'),
                    ),
                  ),
                ),
              const SizedBox(height: 24),

              // Instructions
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Friends must have Nautune installed and be logged into the same Jellyfin server.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Session code
              if (groupId != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Session ID:',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _formatSessionId(groupId),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _copyToClipboard(context, groupId),
                        icon: const Icon(Icons.copy, size: 20),
                        tooltip: 'Copy session ID',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),

              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: shareUrl != null
                          ? () => _copyToClipboard(context, shareUrl)
                          : null,
                      icon: const Icon(Icons.link),
                      label: const Text('Copy Link'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: shareUrl != null
                          ? () => _shareLink(context, shareUrl, groupName)
                          : null,
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatSessionId(String id) {
    // Show first and last 4 characters with ... in between
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}...${id.substring(id.length - 6)}';
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareLink(BuildContext context, String url, String name) async {
    // Use platform share if available
    // For now, just copy to clipboard
    final text = 'Join my collaborative playlist "$name" on Nautune!\n$url';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Share link copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

/// A button to open the share sheet
class CollabShareButton extends StatelessWidget {
  const CollabShareButton({
    super.key,
    this.iconOnly = false,
  });

  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      return IconButton(
        onPressed: () => CollabShareSheet.show(context),
        icon: const Icon(Icons.share),
        tooltip: 'Share session',
      );
    }

    return FilledButton.icon(
      onPressed: () => CollabShareSheet.show(context),
      icon: const Icon(Icons.share),
      label: const Text('Share'),
    );
  }
}
