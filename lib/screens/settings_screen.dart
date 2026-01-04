import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../providers/session_provider.dart';
import '../providers/ui_state_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<String> _packageVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      return '${packageInfo.version}+${packageInfo.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionProvider = Provider.of<SessionProvider>(context);
    final uiStateProvider = Provider.of<UIStateProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Server',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            title: const Text('Server URL'),
            subtitle: Text(sessionProvider.session?.serverUrl ?? 'Not connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Allow changing server
            },
          ),
          ListTile(
            title: const Text('Username'),
            subtitle: Text(sessionProvider.session?.username ?? 'Not logged in'),
          ),
          ListTile(
            title: const Text('Library'),
            subtitle: Text(sessionProvider.session?.selectedLibraryName ?? 'None selected'),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Audio Options',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.tune, color: theme.colorScheme.primary),
            title: const Text('Crossfade'),
            subtitle: Text(
              uiStateProvider.crossfadeEnabled
                ? 'Enabled (${uiStateProvider.crossfadeDurationSeconds}s)'
                : 'Smooth transitions between tracks'
            ),
            trailing: Switch(
              value: uiStateProvider.crossfadeEnabled,
              onChanged: (value) {
                uiStateProvider.toggleCrossfade(value);
              },
            ),
          ),
          if (uiStateProvider.crossfadeEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Duration: ${uiStateProvider.crossfadeDurationSeconds} seconds',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Slider(
                    value: uiStateProvider.crossfadeDurationSeconds.toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: '${uiStateProvider.crossfadeDurationSeconds}s',
                    onChanged: (value) {
                      uiStateProvider.setCrossfadeDuration(value.round());
                    },
                  ),
                  Text(
                    'Automatically skips crossfade within same album',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ListTile(
            leading: Icon(Icons.all_inclusive, color: theme.colorScheme.primary),
            title: const Text('Infinite Radio'),
            subtitle: Text(
              uiStateProvider.infiniteRadioEnabled
                ? 'Auto-generates similar tracks when queue is low'
                : 'Endless playback based on current track'
            ),
            trailing: Switch(
              value: uiStateProvider.infiniteRadioEnabled,
              onChanged: (value) {
                uiStateProvider.toggleInfiniteRadio(value);
              },
            ),
          ),
          if (uiStateProvider.infiniteRadioEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Uses Jellyfin\'s Instant Mix to find similar tracks. Requires internet connection.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'About',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          FutureBuilder<String>(
            future: _packageVersion(),
            builder: (context, snapshot) {
              final version = snapshot.data ?? '…';
              return ListTile(
                title: const Text('Nautune'),
                subtitle: Text('Version $version'),
              );
            },
          ),
          ListTile(
            title: const Text('Open Source Licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              showLicensePage(context: context);
            },
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Made with 💜 by ElysiumDisc',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
