import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.appState});

  final NautuneAppState appState;

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
            subtitle: Text(widget.appState.session?.serverUrl ?? 'Not connected'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              // TODO: Allow changing server
            },
          ),
          ListTile(
            title: const Text('Username'),
            subtitle: Text(widget.appState.session?.username ?? 'Not logged in'),
          ),
          ListTile(
            title: const Text('Library'),
            subtitle: Text(widget.appState.selectedLibrary?.name ?? 'None selected'),
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
              widget.appState.crossfadeEnabled 
                ? 'Enabled (${widget.appState.crossfadeDurationSeconds}s)'
                : 'Smooth transitions between tracks'
            ),
            trailing: Switch(
              value: widget.appState.crossfadeEnabled,
              onChanged: (value) {
                widget.appState.toggleCrossfade(value);
                setState(() {});
              },
            ),
          ),
          if (widget.appState.crossfadeEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Duration: ${widget.appState.crossfadeDurationSeconds} seconds',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Slider(
                    value: widget.appState.crossfadeDurationSeconds.toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: '${widget.appState.crossfadeDurationSeconds}s',
                    onChanged: (value) {
                      widget.appState.setCrossfadeDuration(value.round());
                      setState(() {});
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
