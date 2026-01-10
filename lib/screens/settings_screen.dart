import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../providers/session_provider.dart';
import '../providers/ui_state_provider.dart';
import '../services/audio_cache_service.dart';

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
  String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes minutes';
    if (minutes < 1440) {
      final hours = minutes ~/ 60;
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    }
    if (minutes < 10080) {
      final days = minutes ~/ 1440;
      return '$days ${days == 1 ? 'day' : 'days'}';
    }
    return '1 week';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionProvider = Provider.of<SessionProvider>(context);
    final uiStateProvider = Provider.of<UIStateProvider>(context);
    final appState = Provider.of<NautuneAppState>(context);

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
              appState.crossfadeEnabled
                ? 'Enabled (${appState.crossfadeDurationSeconds}s)'
                : 'Smooth transitions between tracks'
            ),
            trailing: Switch(
              value: appState.crossfadeEnabled,
              onChanged: (value) {
                appState.toggleCrossfade(value);
              },
            ),
          ),
          if (appState.crossfadeEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Duration: ${appState.crossfadeDurationSeconds} seconds',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Slider(
                    value: appState.crossfadeDurationSeconds.toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: '${appState.crossfadeDurationSeconds}s',
                    onChanged: (value) {
                      appState.setCrossfadeDuration(value.round());
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
            leading: Icon(Icons.music_note, color: theme.colorScheme.primary),
            title: const Text('Gapless Playback'),
            subtitle: Text(
              appState.gaplessPlaybackEnabled
                ? 'Seamless transitions enabled'
                : 'Standard playback'
            ),
            trailing: Switch(
              value: appState.gaplessPlaybackEnabled,
              onChanged: (value) {
                appState.toggleGaplessPlayback(value);
              },
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
              'Performance',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.cached, color: theme.colorScheme.primary),
            title: const Text('Cache Duration'),
            subtitle: Text(_formatDuration(uiStateProvider.cacheTtlMinutes)),
            trailing: SizedBox(
              width: 150,
              child: _CacheTtlSlider(
                currentMinutes: uiStateProvider.cacheTtlMinutes,
                onChanged: (minutes) {
                  uiStateProvider.setCacheTtl(minutes);
                  appState.setCacheTtl(minutes);
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'How long to keep album/artist data before refreshing from server. Lower = fresher data, higher = faster browsing.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.cleaning_services, color: theme.colorScheme.primary),
            title: const Text('Clear Audio Cache'),
            subtitle: const Text('Clear pre-cached streaming audio'),
            trailing: FilledButton.tonal(
              onPressed: () async {
                await AudioCacheService.instance.clearCache();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Audio cache cleared')),
                  );
                }
              },
              child: const Text('Clear'),
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

class _CacheTtlSlider extends StatelessWidget {
  final int currentMinutes;
  final ValueChanged<int> onChanged;

  const _CacheTtlSlider({
    required this.currentMinutes,
    required this.onChanged,
  });

  static const List<int> _presets = [5, 30, 60, 360, 1440, 10080];

  int _getClosestIndex(int minutes) {
    int closestIndex = 0;
    int minDiff = (minutes - _presets[0]).abs();
    for (int i = 1; i < _presets.length; i++) {
      int diff = (minutes - _presets[i]).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  @override
  Widget build(BuildContext context) {
    final index = _getClosestIndex(currentMinutes);
    return Slider(
      value: index.toDouble(),
      min: 0,
      max: (_presets.length - 1).toDouble(),
      divisions: _presets.length - 1,
      onChanged: (value) {
        onChanged(_presets[value.round()]);
      },
    );
  }
}