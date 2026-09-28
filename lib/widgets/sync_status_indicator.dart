import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/sync_status_provider.dart';

/// A compact sync status indicator for app bars
class SyncStatusIndicator extends StatelessWidget {
  const SyncStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SyncStatusProvider>(
      builder: (context, syncStatus, _) {
        return _buildIndicator(context, syncStatus);
      },
    );
  }

  Widget _buildIndicator(BuildContext context, SyncStatusProvider syncStatus) {
    final theme = Theme.of(context);

    // Don't show anything if idle and no pending actions
    if (syncStatus.status == SyncStatus.idle && !syncStatus.hasPendingActions) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: _getTooltip(syncStatus),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: _buildStatusWidget(context, syncStatus, theme),
      ),
    );
  }

  Widget _buildStatusWidget(BuildContext context, SyncStatusProvider syncStatus, ThemeData theme) {
    switch (syncStatus.status) {
      case SyncStatus.syncing:
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
          ),
        );

      case SyncStatus.pending:
        return Badge(
          label: Text(
            syncStatus.badgeText,
            style: const TextStyle(fontSize: 10),
          ),
          child: Icon(
            Icons.cloud_upload_outlined,
            size: 20,
            color: theme.colorScheme.tertiary,
          ),
        );

      case SyncStatus.error:
        return GestureDetector(
          onTap: () => _showErrorDialog(context, syncStatus),
          child: Icon(
            Icons.cloud_off,
            size: 20,
            color: theme.colorScheme.error,
          ),
        );

      case SyncStatus.offline:
        return Icon(
          Icons.cloud_off,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        );

      case SyncStatus.idle:
        // Show last sync time if available
        if (syncStatus.lastSyncTime != null) {
          return Icon(
            Icons.cloud_done,
            size: 20,
            color: theme.colorScheme.primary.withValues(alpha: 0.7),
          );
        }
        return const SizedBox.shrink();
    }
  }

  String _getTooltip(SyncStatusProvider syncStatus) {
    final timeAgo = syncStatus.timeSinceLastSync;
    final base = syncStatus.statusDescription;

    if (timeAgo != null && syncStatus.status == SyncStatus.idle) {
      return '$base\nLast sync: $timeAgo';
    }

    if (syncStatus.status == SyncStatus.error && syncStatus.lastError != null) {
      return '$base\n${syncStatus.lastError}';
    }

    return base;
  }

  void _showErrorDialog(BuildContext context, SyncStatusProvider syncStatus) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sync Error'),
        content: Text(syncStatus.lastError ?? 'An unknown error occurred during sync.'),
        actions: [
          TextButton(
            onPressed: () {
              syncStatus.clearError();
              Navigator.pop(context);
            },
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }
}
