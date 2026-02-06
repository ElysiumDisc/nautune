import 'package:flutter/material.dart';

import '../models/helm_session.dart';
import '../services/helm_service.dart';

/// Bottom sheet for discovering and selecting a remote Nautune session
/// to control via Helm Mode.
class HelmModeSelector extends StatefulWidget {
  const HelmModeSelector({
    super.key,
    required this.helmService,
  });

  final HelmService helmService;

  /// Show as a modal bottom sheet.
  static Future<void> show(BuildContext context, HelmService helmService) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => HelmModeSelector(helmService: helmService),
      isScrollControlled: true,
      useSafeArea: true,
    );
  }

  @override
  State<HelmModeSelector> createState() => _HelmModeSelectorState();
}

class _HelmModeSelectorState extends State<HelmModeSelector> {
  @override
  void initState() {
    super.initState();
    widget.helmService.addListener(_onUpdate);
    widget.helmService.discoverTargets();
  }

  @override
  void dispose() {
    widget.helmService.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = widget.helmService;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.sailing, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  service.isActive ? 'Helm Mode Active' : 'Helm Mode',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (service.isActive)
                TextButton(
                  onPressed: () {
                    service.deactivateHelm();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Disconnect'),
                ),
              if (!service.isActive)
                IconButton(
                  onPressed: service.isDiscovering ? null : () => service.discoverTargets(),
                  icon: service.isDiscovering
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Active target info
          if (service.isActive && service.activeTarget != null) ...[
            _buildActiveTarget(context, theme, service.activeTarget!),
            const SizedBox(height: 16),
          ],

          // Discovered targets
          if (!service.isActive) ...[
            Text(
              'Remote Nautune devices on your server:',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),

            if (service.isDiscovering)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (service.discoveredTargets.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(
                        Icons.devices_other,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No other Nautune devices found',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Open Nautune on another device connected to the same server',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              ...service.discoveredTargets.map((target) =>
                _buildTargetTile(context, theme, target),
              ),
          ],

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildTargetTile(BuildContext context, ThemeData theme, HelmSession target) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.devices),
        title: Text(target.deviceName),
        subtitle: Text(
          target.hasNowPlaying
              ? '${target.nowPlayingItemName}${target.nowPlayingArtist != null ? ' - ${target.nowPlayingArtist}' : ''}'
              : '${target.userName} - ${target.clientName}',
        ),
        trailing: const Icon(Icons.sailing),
        onTap: () {
          widget.helmService.activateHelm(target);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget _buildActiveTarget(BuildContext context, ThemeData theme, HelmSession target) {
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sailing, color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Controlling: ${target.deviceName}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (target.hasNowPlaying) ...[
              const SizedBox(height: 8),
              Text(
                target.nowPlayingItemName ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              if (target.nowPlayingArtist != null)
                Text(
                  target.nowPlayingArtist!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
