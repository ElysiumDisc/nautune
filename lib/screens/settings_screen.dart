import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/listening_analytics_service.dart';
import '../services/network_download_service.dart';
import '../models/now_playing_layout.dart';
import '../models/playback_state.dart' show StreamingQuality, StreamingQualityExtension;
import '../models/visualizer_type.dart';
import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/ui_state_provider.dart';
import '../services/app_icon_service.dart';
import '../services/audio_cache_service.dart';
import '../services/download_service.dart';
import '../services/listenbrainz_service.dart';
import '../services/rewind_service.dart';
import '../services/saved_loops_service.dart';
import '../services/chart_cache_service.dart';
import '../services/waveform_service.dart';
import '../widgets/jellyfin_waveform.dart';
import '../theme/nautune_theme.dart';
import '../widgets/equalizer_widget.dart';
import '../widgets/visualizer_picker.dart';
import 'listenbrainz_settings_screen.dart';
import 'rewind_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String get _packageVersion => AppVersion.current;
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

  String _gridSizeLabel(int size) {
    switch (size) {
      case 2: return '2 per row (large)';
      case 3: return '3 per row (default)';
      case 4: return '4 per row (compact)';
      case 5: return '5 per row (dense)';
      case 6: return '6 per row (ultra-compact)';
      default: return '$size per row';
    }
  }

  Widget _buildAppearanceSection(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final appState = Provider.of<NautuneAppState>(context);
    final uiState = Provider.of<UIStateProvider>(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(icon: Icons.palette, title: 'Appearance'),
        Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.color_lens, color: theme.colorScheme.primary),
                title: const Text('Color Theme'),
                subtitle: Text(themeProvider.palette.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showThemePicker(context),
              ),
              ListenableBuilder(
                listenable: AppIconService(),
                builder: (context, _) {
                  final iconService = AppIconService();
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        iconService.iconAssetPath,
                        width: 24,
                        height: 24,
                      ),
                    ),
                    title: const Text('App Icon'),
                    subtitle: Text(iconService.iconDisplayName),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showIconPicker(context),
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  uiState.useListMode ? Icons.view_list : Icons.grid_view,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('View Mode'),
                subtitle: Text(uiState.useListMode ? 'List view' : 'Grid view'),
                trailing: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.grid_view, size: 18)),
                    ButtonSegment(value: true, icon: Icon(Icons.view_list, size: 18)),
                  ],
                  selected: {uiState.useListMode},
                  onSelectionChanged: (selected) {
                    uiState.setUseListMode(selected.first);
                  },
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              if (!uiState.useListMode) ...[
                ListTile(
                  leading: Icon(Icons.apps, color: theme.colorScheme.primary),
                  title: const Text('Grid Size'),
                  subtitle: Text(_gridSizeLabel(uiState.gridSize)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      const Text('2'),
                      Expanded(
                        child: Slider(
                          value: uiState.gridSize.toDouble(),
                          min: 2,
                          max: 6,
                          divisions: 4,
                          label: '${uiState.gridSize}',
                          onChanged: (value) {
                            uiState.setGridSize(value.round());
                          },
                        ),
                      ),
                      const Text('6'),
                    ],
                  ),
                ),
              ],
              ListTile(
                leading: Icon(Icons.waves, color: theme.colorScheme.primary),
                title: const Text('Audio Visualizer'),
                subtitle: Text(
                  appState.visualizerEnabled
                      ? appState.visualizerType.label
                      : 'Disabled for battery savings'
                ),
                trailing: Switch(
                  value: appState.visualizerEnabled,
                  onChanged: (value) {
                    appState.setVisualizerEnabled(value);
                  },
                ),
              ),
              if (appState.visualizerEnabled)
                ListTile(
                  leading: Icon(appState.visualizerType.icon, color: theme.colorScheme.primary),
                  title: const Text('Visualizer Style'),
                  subtitle: Text(appState.visualizerType.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showVisualizerPicker(context),
                ),
              if (appState.visualizerEnabled)
                ListTile(
                  leading: Icon(appState.visualizerPosition.icon, color: theme.colorScheme.primary),
                  title: const Text('Visualizer Position'),
                  subtitle: Text(appState.visualizerPosition.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showVisualizerPositionPicker(context),
                ),
              ListTile(
                leading: Icon(appState.nowPlayingLayout.icon, color: theme.colorScheme.primary),
                title: const Text('Now Playing Layout'),
                subtitle: Text(appState.nowPlayingLayout.description),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showNowPlayingLayoutPicker(context),
              ),
              ListTile(
                leading: Icon(Icons.volume_up, color: theme.colorScheme.primary),
                title: const Text('Volume Bar'),
                subtitle: Text(
                  appState.showVolumeBar
                      ? 'Shown in Now Playing'
                      : 'Hidden (use device volume)'
                ),
                trailing: Switch(
                  value: appState.showVolumeBar,
                  onChanged: (value) {
                    appState.setVolumeBarVisibility(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildYourMusicSection(BuildContext context) {
    final theme = Theme.of(context);
    final rewindService = RewindService();
    final previousYear = DateTime.now().year - 1;
    final hasPreviousYearData = rewindService.hasEnoughData(previousYear);
    final listenBrainz = ListenBrainzService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(icon: Icons.auto_awesome, title: 'Your Music'),
        Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              // Rewind entry - always shows previous year (like Spotify Wrapped)
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.replay, color: Colors.white, size: 20),
                ),
                title: Text('Your $previousYear Rewind'),
                subtitle: Text(
                  hasPreviousYearData
                      ? 'View your $previousYear listening stats'
                      : 'Not enough listening data from $previousYear',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => RewindScreen(
                        initialYear: previousYear,
                      ),
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              // ListenBrainz entry
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.music_note,
                    color: theme.colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                title: const Text('ListenBrainz'),
                subtitle: Text(
                  listenBrainz.isConfigured
                      ? 'Connected as ${listenBrainz.username}'
                      : 'Connect to scrobble & discover music',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (listenBrainz.isConfigured)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: listenBrainz.isScrobblingEnabled
                              ? Colors.green
                              : Colors.orange,
                          shape: BoxShape.circle,
                        ),
                      ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ListenBrainzSettingsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportStats(BuildContext context) async {
    final theme = Theme.of(context);
    final analytics = ListeningAnalyticsService();
    final networkService = NetworkDownloadService();

    // Ensure services are fully initialized
    await analytics.initialize();
    await networkService.initialize();

    // Combine both services' data
    final analyticsJson = analytics.exportAllStatsAsJson();
    final networkJson = networkService.exportStatsAsJson();

    // Parse and combine
    final analyticsData = Map<String, dynamic>.from(
      (await _parseJsonSafe(analyticsJson)) ?? {},
    );
    final networkData = Map<String, dynamic>.from(
      (await _parseJsonSafe(networkJson)) ?? {},
    );

    final combinedBackup = {
      ...analyticsData,
      'network_channel_stats': networkData['network_stats'],
    };

    final backupJson = _encodeJson(combinedBackup);

    // Save to file
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final backupDir = Platform.isLinux || Platform.isMacOS || Platform.isWindows
          ? Directory('${docsDir.path}/nautune/backups')
          : Directory('${docsDir.path}/backups');

      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final backupFile = File('${backupDir.path}/nautune_backup_$timestamp.json');
      await backupFile.writeAsString(backupJson);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup saved to ${backupFile.path}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Copy Path',
              textColor: Colors.white,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: backupFile.path));
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _importStats(BuildContext context) async {
    final theme = Theme.of(context);
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Stats'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste your backup JSON below, or enter the path to a backup file:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Paste backup JSON or file path...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              // Try to paste from clipboard
              final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
              if (clipboardData?.text != null) {
                controller.text = clipboardData!.text!;
              }
            },
            child: const Text('Paste'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;

    String jsonContent = result.trim();

    // Check if it's a file path
    if (!jsonContent.startsWith('{')) {
      try {
        final file = File(jsonContent);
        if (await file.exists()) {
          jsonContent = await file.readAsString();
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('File not found'),
                backgroundColor: theme.colorScheme.error,
              ),
            );
          }
          return;
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error reading file: $e'),
              backgroundColor: theme.colorScheme.error,
            ),
          );
        }
        return;
      }
    }

    try {
      final analytics = ListeningAnalyticsService();
      final networkService = NetworkDownloadService();

      // Ensure services are fully initialized
      await analytics.initialize();
      await networkService.initialize();

      // Import main analytics
      final importedEvents = await analytics.importAllStatsFromJson(jsonContent);

      // Import network stats if present
      final jsonData = await _parseJsonSafe(jsonContent);
      int networkImported = 0;
      if (jsonData != null && jsonData['network_channel_stats'] != null) {
        final networkStatsJson = _encodeJson({
          'network_stats': jsonData['network_channel_stats'],
        });
        networkImported = await networkService.importStatsFromJson(networkStatsJson);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imported $importedEvents events, $networkImported channel stats'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _parseJsonSafe(String json) async {
    try {
      final decoded = json.trim();
      if (!decoded.startsWith('{')) return null;
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _encodeJson(Map<String, dynamic> data) {
    return jsonEncode(data);
  }

  void _showVisualizerPicker(BuildContext context) async {
    final appState = Provider.of<NautuneAppState>(context, listen: false);

    final selected = await VisualizerPicker.show(
      context,
      currentType: appState.visualizerType,
    );

    if (selected != null) {
      appState.setVisualizerType(selected);
    }
  }

  void _showVisualizerPositionPicker(BuildContext context) {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Visualizer Position',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ...VisualizerPosition.values.map((position) {
              final isSelected = position == appState.visualizerPosition;
              return ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    position.icon,
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                title: Text(
                  position.label,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(position.description),
                trailing: isSelected
                    ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    : null,
                onTap: () {
                  appState.setVisualizerPosition(position);
                  Navigator.pop(context);
                },
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showNowPlayingLayoutPicker(BuildContext context) {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Now Playing Layout',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...NowPlayingLayout.values.map((layout) {
                final isSelected = layout == appState.nowPlayingLayout;
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primary.withValues(alpha: 0.2)
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      layout.icon,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  title: Text(
                    layout.label,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(layout.description),
                  trailing: isSelected
                      ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                      : null,
                  onTap: () {
                    appState.setNowPlayingLayout(layout);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemePicker(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ThemePickerSheet(
        currentPalette: themeProvider.palette,
        customPrimaryColor: themeProvider.customPrimaryColor,
        customSecondaryColor: themeProvider.customSecondaryColor,
        customAccentColor: themeProvider.customAccentColor,
        customIsLight: themeProvider.customIsLight,
        onSelectPreset: (palette) {
          themeProvider.setPalette(palette);
          Navigator.pop(context);
        },
        onSelectCustom: (primary, secondary, accent, isLight) {
          themeProvider.setCustomColors(
            primary: primary,
            secondary: secondary,
            accent: accent,
            isLight: isLight,
          );
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showIconPicker(BuildContext context) {
    final theme = Theme.of(context);
    final iconService = AppIconService();

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'App Icon',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose your preferred app icon style',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _IconOption(
                    assetPath: 'assets/icon.png',
                    label: 'Classic',
                    isSelected: iconService.currentIcon == 'default',
                    onTap: () async {
                      final appState = Platform.isLinux || Platform.isMacOS
                          ? Provider.of<NautuneAppState>(context, listen: false)
                          : null;
                      await iconService.setIcon('default');
                      appState?.trayService?.updateTrayIcon();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                  _IconOption(
                    assetPath: 'assets/iconorange.png',
                    label: 'Sunset',
                    isSelected: iconService.currentIcon == 'orange',
                    onTap: () async {
                      final appState = Platform.isLinux || Platform.isMacOS
                          ? Provider.of<NautuneAppState>(context, listen: false)
                          : null;
                      await iconService.setIcon('orange');
                      appState?.trayService?.updateTrayIcon();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _IconOption(
                    assetPath: 'assets/iconred.png',
                    label: 'Crimson',
                    isSelected: iconService.currentIcon == 'red',
                    onTap: () async {
                      final appState = Platform.isLinux || Platform.isMacOS
                          ? Provider.of<NautuneAppState>(context, listen: false)
                          : null;
                      await iconService.setIcon('red');
                      appState?.trayService?.updateTrayIcon();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                  _IconOption(
                    assetPath: 'assets/icongreen.png',
                    label: 'Emerald',
                    isSelected: iconService.currentIcon == 'green',
                    onTap: () async {
                      final appState = Platform.isLinux || Platform.isMacOS
                          ? Provider.of<NautuneAppState>(context, listen: false)
                          : null;
                      await iconService.setIcon('green');
                      appState?.trayService?.updateTrayIcon();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (Platform.isIOS)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'iOS home screen icon will update after closing this sheet.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          // Your Music section with Rewind and ListenBrainz
          _buildYourMusicSection(context),

          const _SectionHeader(icon: Icons.dns, title: 'Server'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.cloud, color: theme.colorScheme.primary),
                  title: const Text('Server URL'),
                  subtitle: Text(sessionProvider.session?.serverUrl ?? 'Not connected'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    // TODO: Allow changing server
                  },
                ),
                ListTile(
                  leading: Icon(Icons.person, color: theme.colorScheme.primary),
                  title: const Text('Username'),
                  subtitle: Text(sessionProvider.session?.username ?? 'Not logged in'),
                ),
                ListTile(
                  leading: Icon(Icons.library_music, color: theme.colorScheme.primary),
                  title: const Text('Library'),
                  subtitle: Text(sessionProvider.session?.selectedLibraryName ?? 'None selected'),
                ),
              ],
            ),
          ),
          _buildAppearanceSection(context),
          const _SectionHeader(icon: Icons.audiotrack, title: 'Audio Options'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.high_quality, color: theme.colorScheme.primary),
                  title: const Text('Streaming Quality'),
                  subtitle: Text(
                    appState.streamingQuality == StreamingQuality.original
                        ? 'Streams original quality (FLAC, lossless)'
                        : appState.streamingQuality == StreamingQuality.auto
                            ? 'Original on WiFi, Normal on cellular'
                            : 'Transcodes to MP3 at selected bitrate',
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: PopupMenuButton<StreamingQuality>(
                    initialValue: appState.streamingQuality,
                    onSelected: (StreamingQuality? value) {
                      if (value != null) {
                        appState.setStreamingQuality(value);
                      }
                    },
                    itemBuilder: (context) => StreamingQuality.values.map((quality) {
                      return PopupMenuItem<StreamingQuality>(
                        value: quality,
                        child: Text(quality.label),
                      );
                    }).toList(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            appState.streamingQuality.label,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down, color: theme.colorScheme.primary),
                        ],
                      ),
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      'Uses Jellyfin\'s Instant Mix to find similar tracks. Requires internet connection.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: EqualizerWidget(),
                ),
              ],
            ),
          ),
          const _SectionHeader(icon: Icons.speed, title: 'Performance'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'How long to keep album/artist data before refreshing from server. Lower = fresher data, higher = faster browsing.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.queue_music, color: theme.colorScheme.primary),
                  title: const Text('Smart Pre-Cache'),
                  subtitle: Text(
                    uiStateProvider.preCacheTrackCount == 0
                        ? 'Disabled'
                        : 'Pre-cache ${uiStateProvider.preCacheTrackCount} upcoming tracks'
                  ),
                  trailing: PopupMenuButton<int>(
                    initialValue: uiStateProvider.preCacheTrackCount,
                    onSelected: (int? value) {
                      if (value != null) {
                        uiStateProvider.setPreCacheTrackCount(value);
                        appState.setPreCacheTrackCount(value);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<int>(value: 0, child: Text('Off')),
                      const PopupMenuItem<int>(value: 3, child: Text('3 tracks')),
                      const PopupMenuItem<int>(value: 5, child: Text('5 tracks')),
                      const PopupMenuItem<int>(value: 10, child: Text('10 tracks')),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            uiStateProvider.preCacheTrackCount == 0
                                ? 'Off'
                                : '${uiStateProvider.preCacheTrackCount}',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down, color: theme.colorScheme.primary),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Pre-download upcoming tracks in queue for smoother playback. Works with albums, playlists, and favorites.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.wifi, color: theme.colorScheme.primary),
                  title: const Text('WiFi-Only Pre-Cache'),
                  subtitle: const Text('Only pre-cache when connected to WiFi'),
                  trailing: Switch(
                    value: uiStateProvider.wifiOnlyCaching,
                    onChanged: (value) {
                      uiStateProvider.setWifiOnlyCaching(value);
                      appState.setWifiOnlyCaching(value);
                    },
                  ),
                ),
              ],
            ),
          ),
          const _SectionHeader(icon: Icons.download, title: 'Downloads'),
          ListenableBuilder(
            listenable: appState.downloadService,
            builder: (context, _) {
              final downloadService = appState.downloadService;
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.sync, color: theme.colorScheme.primary),
                      title: const Text('Concurrent Downloads'),
                      subtitle: Text('${downloadService.maxConcurrentDownloads} simultaneous downloads'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Text('1'),
                          Expanded(
                            child: Slider(
                              value: downloadService.maxConcurrentDownloads.toDouble(),
                              min: 1,
                              max: 10,
                              divisions: 9,
                              label: '${downloadService.maxConcurrentDownloads}',
                              onChanged: (value) {
                                final newValue = value.round();
                                downloadService.setMaxConcurrentDownloads(newValue);
                                uiStateProvider.setMaxConcurrentDownloads(newValue);
                              },
                            ),
                          ),
                          const Text('10'),
                        ],
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.wifi, color: theme.colorScheme.primary),
                      title: const Text('WiFi-Only Downloads'),
                      subtitle: const Text('Only download when connected to WiFi'),
                      trailing: Switch(
                        value: downloadService.wifiOnlyDownloads,
                        onChanged: (value) {
                          downloadService.setWifiOnlyDownloads(value);
                          uiStateProvider.setWifiOnlyDownloads(value);
                        },
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.folder_open, color: theme.colorScheme.primary),
                      title: const Text('Manage Storage'),
                      subtitle: FutureBuilder<StorageStats>(
                        future: downloadService.getStorageStats(),
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                            final stats = snapshot.data!;
                            final totalItems = stats.trackCount + stats.cacheFileCount;
                            return Text('$totalItems items using ${stats.formattedCombined}');
                          }
                          return const Text('Calculating...');
                        },
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const _StorageManagementScreen(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
          const _SectionHeader(icon: Icons.backup, title: 'Data & Backup'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.upload_file, color: theme.colorScheme.primary),
                  title: const Text('Export Stats'),
                  subtitle: const Text('Backup all listening data to file'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportStats(context),
                ),
                ListTile(
                  leading: Icon(Icons.download, color: theme.colorScheme.primary),
                  title: const Text('Import Stats'),
                  subtitle: const Text('Restore from backup file'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _importStats(context),
                ),
              ],
            ),
          ),
          const _SectionHeader(icon: Icons.info_outline, title: 'About'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.anchor, color: theme.colorScheme.primary),
                  title: const Text('Nautune'),
                  subtitle: Text('Version $_packageVersion'),
                ),
                ListTile(
                  leading: Icon(Icons.gavel, color: theme.colorScheme.primary),
                  title: const Text('Open Source Licenses'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    showLicensePage(context: context);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Made with 💜 by ElysiumDisc',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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

class _StorageLimitSlider extends StatelessWidget {
  final int currentMB;
  final ValueChanged<int> onChanged;

  const _StorageLimitSlider({
    required this.currentMB,
    required this.onChanged,
  });

  // Presets: 0 (unlimited), 500MB, 1GB, 2GB, 5GB, 10GB
  static const List<int> _presets = [0, 512, 1024, 2048, 5120, 10240];

  int _getClosestIndex(int mb) {
    int closestIndex = 0;
    int minDiff = (mb - _presets[0]).abs();
    for (int i = 1; i < _presets.length; i++) {
      int diff = (mb - _presets[i]).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  @override
  Widget build(BuildContext context) {
    final index = _getClosestIndex(currentMB);
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

enum _StorageView { downloads, cache, loops, waveforms, charts }

class _StorageManagementScreen extends StatefulWidget {
  const _StorageManagementScreen();

  @override
  State<_StorageManagementScreen> createState() => _StorageManagementScreenState();
}

class _StorageManagementScreenState extends State<_StorageManagementScreen> {
  _StorageView _currentView = _StorageView.downloads;
  bool _showByAlbum = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<NautuneAppState>(context);
    final downloadService = appState.downloadService;
    final uiStateProvider = Provider.of<UIStateProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear All Downloads',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear All Downloads?'),
                  content: const Text('This will permanently delete all downloaded tracks. This action cannot be undone.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Delete All'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await downloadService.clearAllDownloads();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('All downloads cleared')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: downloadService,
        builder: (context, _) {
          return FutureBuilder(
            future: downloadService.getStorageStats(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final stats = snapshot.data!;

              return Column(
                children: [
                  // Storage summary card
                  Card(
                    margin: const EdgeInsets.all(16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _StatItem(
                                icon: Icons.download,
                                label: 'Downloads',
                                value: stats.formattedTotal,
                              ),
                              _StatItem(
                                icon: Icons.cached,
                                label: 'Cache',
                                value: stats.formattedCache,
                              ),
                              _StatItem(
                                icon: Icons.storage,
                                label: 'Total',
                                value: stats.formattedCombined,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _StatItem(
                                icon: Icons.music_note,
                                label: 'Downloaded',
                                value: '${stats.trackCount} tracks',
                              ),
                              _StatItem(
                                icon: Icons.queue_music,
                                label: 'Cached',
                                value: '${stats.cacheFileCount} tracks',
                              ),
                              _StatItem(
                                icon: Icons.waves,
                                label: 'Waveforms',
                                value: stats.formattedWaveforms,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _StatItem(
                                icon: Icons.gamepad,
                                label: 'Charts',
                                value: '${stats.chartCount} (${stats.formattedCharts})',
                              ),
                            ],
                          ),
                          if (downloadService.storageLimitMB > 0) ...[
                            const SizedBox(height: 16),
                            LinearProgressIndicator(
                              value: (stats.totalBytes + stats.cacheBytes) / (downloadService.storageLimitMB * 1024 * 1024),
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${stats.formattedCombined} of ${_formatBytes(downloadService.storageLimitMB * 1024 * 1024)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Storage settings
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.storage),
                          title: const Text('Storage Limit'),
                          subtitle: Text(
                            downloadService.storageLimitMB == 0
                                ? 'Unlimited'
                                : downloadService.storageLimitMB >= 1024
                                    ? '${(downloadService.storageLimitMB / 1024).toStringAsFixed(1)} GB'
                                    : '${downloadService.storageLimitMB} MB'
                          ),
                          trailing: SizedBox(
                            width: 150,
                            child: _StorageLimitSlider(
                              currentMB: downloadService.storageLimitMB,
                              onChanged: (mb) {
                                downloadService.setStorageLimitMB(mb);
                                uiStateProvider.setStorageLimitMB(mb);
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.auto_delete),
                          title: const Text('Auto-Cleanup'),
                          subtitle: Text(
                            downloadService.autoCleanupEnabled
                                ? 'Remove downloads older than ${downloadService.autoCleanupDays} days'
                                : 'Keep all downloads'
                          ),
                          trailing: Switch(
                            value: downloadService.autoCleanupEnabled,
                            onChanged: (value) {
                              downloadService.setAutoCleanup(enabled: value);
                              uiStateProvider.setAutoCleanup(enabled: value);
                              setState(() {});
                            },
                          ),
                        ),
                        if (downloadService.autoCleanupEnabled)
                          Padding(
                            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                            child: Row(
                              children: [
                                const Text('7d'),
                                Expanded(
                                  child: Slider(
                                    value: downloadService.autoCleanupDays.toDouble(),
                                    min: 7,
                                    max: 90,
                                    divisions: 11,
                                    label: '${downloadService.autoCleanupDays} days',
                                    onChanged: (value) {
                                      final days = value.round();
                                      downloadService.setAutoCleanup(days: days);
                                      uiStateProvider.setAutoCleanup(days: days);
                                      setState(() {});
                                    },
                                  ),
                                ),
                                const Text('90d'),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Main view toggle
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final view in _StorageView.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              selected: _currentView == view,
                              label: Text(_storageViewLabel(view)),
                              avatar: Icon(_storageViewIcon(view), size: 18),
                              onSelected: (_) => setState(() => _currentView = view),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // View-specific content
                  if (_currentView == _StorageView.downloads) ...[
                    // Quick actions for downloads
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                final deleted = await downloadService.cleanupByAge(const Duration(days: 30));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Removed $deleted old downloads')),
                                  );
                                  setState(() {});
                                }
                              },
                              icon: const Icon(Icons.history),
                              label: const Text('Clean Old'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                final deleted = await downloadService.cleanupToFreeSpace(500);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Removed $deleted downloads to free 500MB')),
                                  );
                                  setState(() {});
                                }
                              },
                              icon: const Icon(Icons.cleaning_services),
                              label: const Text('Free 500MB'),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Toggle between album/artist view
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('By Album'), icon: Icon(Icons.album)),
                          ButtonSegment(value: false, label: Text('By Artist'), icon: Icon(Icons.person)),
                        ],
                        selected: {_showByAlbum},
                        onSelectionChanged: (selection) {
                          setState(() => _showByAlbum = selection.first);
                        },
                      ),
                    ),

                    const SizedBox(height: 8),

                    // List of albums/artists with storage usage
                    Expanded(
                      child: _showByAlbum
                          ? _buildAlbumList(stats, downloadService, theme)
                          : _buildArtistList(stats, downloadService, theme),
                    ),
                  ] else if (_currentView == _StorageView.cache) ...[
                    // Cache view
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Clear All Cache?'),
                                    content: const Text('This will remove all pre-cached tracks and waveforms. Downloads will not be affected.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: const Text('Clear'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  await AudioCacheService.instance.clearCache();
                                  await WaveformService.instance.clearAllWaveforms();
                                  TrackWaveform.clearCache();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('All cache cleared')),
                                    );
                                    setState(() {});
                                  }
                                }
                              },
                              icon: const Icon(Icons.delete_sweep),
                              label: const Text('Clear All Cache'),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Cache info note
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Audio cache auto-expires after 7 days. Waveforms are stored until cleared.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // List of cached tracks
                    Expanded(
                      child: _buildCacheList(stats, theme),
                    ),
                  ] else if (_currentView == _StorageView.loops) ...[
                    // Loops view
                    Expanded(
                      child: _buildLoopsView(theme),
                    ),
                  ] else if (_currentView == _StorageView.waveforms) ...[
                    // Waveforms view
                    Expanded(
                      child: _buildWaveformsView(theme),
                    ),
                  ] else if (_currentView == _StorageView.charts) ...[
                    // Charts view
                    Expanded(
                      child: _buildChartsView(theme),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAlbumList(StorageStats stats, DownloadService downloadService, ThemeData theme) {
    final sortedAlbums = stats.byAlbum.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (sortedAlbums.isEmpty) {
      return const Center(child: Text('No downloads'));
    }

    return ListView.builder(
      itemCount: sortedAlbums.length,
      itemBuilder: (context, index) {
        final entry = sortedAlbums[index];
        final albumId = entry.key;
        final bytes = entry.value;
        final albumName = stats.albumNames[albumId] ?? 'Unknown Album';
        final trackCount = downloadService.trackIdsForAlbum(albumId).length;

        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.album)),
          title: Text(albumName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$trackCount tracks'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatBytes(bytes), style: theme.textTheme.bodySmall),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete Album?'),
                      content: Text('Remove all $trackCount downloaded tracks from "$albumName"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await downloadService.cleanupAlbum(albumId);
                    if (context.mounted) {
                      setState(() {});
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildArtistList(StorageStats stats, DownloadService downloadService, ThemeData theme) {
    final sortedArtists = stats.byArtist.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (sortedArtists.isEmpty) {
      return const Center(child: Text('No downloads'));
    }

    return ListView.builder(
      itemCount: sortedArtists.length,
      itemBuilder: (context, index) {
        final entry = sortedArtists[index];
        final artistName = entry.key;
        final bytes = entry.value;
        final trackCount = downloadService.trackIdsForArtist(artistName).length;

        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('$trackCount tracks'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_formatBytes(bytes), style: theme.textTheme.bodySmall),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Delete Artist?'),
                      content: Text('Remove all $trackCount downloaded tracks from "$artistName"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await downloadService.cleanupArtist(artistName);
                    if (context.mounted) {
                      setState(() {});
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCacheList(StorageStats stats, ThemeData theme) {
    final cachedTrackIds = stats.cachedTrackIds;

    if (cachedTrackIds.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cached, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              'No cached tracks',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Play music to start pre-caching upcoming tracks',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: cachedTrackIds.length,
      itemBuilder: (context, index) {
        final trackId = cachedTrackIds[index];

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(Icons.music_note, color: theme.colorScheme.onSecondaryContainer),
          ),
          title: Text(
            'Track ID: ${trackId.length > 20 ? '${trackId.substring(0, 20)}...' : trackId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('Pre-cached for smooth playback'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await AudioCacheService.instance.removeFromCache(trackId);
              if (context.mounted) {
                setState(() {});
              }
            },
          ),
        );
      },
    );
  }

  Widget _buildLoopsView(ThemeData theme) {
    final savedLoopsService = SavedLoopsService();

    return FutureBuilder(
      future: savedLoopsService.initialize().then((_) => savedLoopsService.getAllLoops()),
      builder: (context, snapshot) {
        final loops = snapshot.data ?? [];

        return Column(
          children: [
            // Clear all loops button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: loops.isEmpty
                          ? null
                          : () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Delete All Saved Loops?'),
                                  content: Text('This will remove all ${loops.length} saved loops. This cannot be undone.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Delete All'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                // Delete all loops for each track
                                final trackIds = loops.map((l) => l.trackId).toSet();
                                for (final trackId in trackIds) {
                                  await savedLoopsService.deleteAllLoopsForTrack(trackId);
                                }
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('All saved loops deleted')),
                                  );
                                  setState(() {});
                                }
                              }
                            },
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('Delete All Loops'),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Info note
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Saved loops are stored as bookmarks. Long-press a loop to delete it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 8),

            // List of saved loops
            Expanded(
              child: loops.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.repeat, size: 48, color: theme.colorScheme.outline),
                          const SizedBox(height: 8),
                          Text(
                            'No saved loops',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Create A-B loops in the player and tap "Save Loop"',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: loops.length,
                      itemBuilder: (context, index) {
                        final loop = loops[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Icon(Icons.repeat_one, color: theme.colorScheme.onPrimaryContainer),
                          ),
                          title: Text(
                            loop.trackName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('${loop.formattedStart} - ${loop.formattedEnd}'),
                          trailing: Text(
                            _formatLoopDate(loop.createdAt),
                            style: theme.textTheme.bodySmall,
                          ),
                          onLongPress: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete Loop?'),
                                content: Text('Delete "${loop.displayName}"?'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await savedLoopsService.deleteLoop(loop.trackId, loop.id);
                              if (context.mounted) {
                                setState(() {});
                              }
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  String _formatLoopDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}';
  }

  String _storageViewLabel(_StorageView view) {
    switch (view) {
      case _StorageView.downloads: return 'Downloads';
      case _StorageView.cache: return 'Cache';
      case _StorageView.loops: return 'Loops';
      case _StorageView.waveforms: return 'Waveforms';
      case _StorageView.charts: return 'Charts';
    }
  }

  IconData _storageViewIcon(_StorageView view) {
    switch (view) {
      case _StorageView.downloads: return Icons.download;
      case _StorageView.cache: return Icons.cached;
      case _StorageView.loops: return Icons.repeat;
      case _StorageView.waveforms: return Icons.waves;
      case _StorageView.charts: return Icons.gamepad;
    }
  }

  Widget _buildWaveformsView(ThemeData theme) {
    return FutureBuilder<Map<String, dynamic>>(
      future: WaveformService.instance.getStorageStats(),
      builder: (context, snapshot) {
        final waveformStats = snapshot.data;
        final fileCount = waveformStats?['fileCount'] as int? ?? 0;
        final totalBytes = waveformStats?['totalBytes'] as int? ?? 0;

        return Column(
          children: [
            // Clear all waveforms button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: fileCount == 0
                          ? null
                          : () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Clear All Waveforms?'),
                                  content: Text('This will remove all $fileCount cached waveforms. They will be re-generated when needed.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Clear'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await WaveformService.instance.clearAllWaveforms();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('All waveforms cleared')),
                                  );
                                  setState(() {});
                                }
                              }
                            },
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('Clear All Waveforms'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Waveforms are generated from audio data and cached locally for instant display. They can be safely cleared and will regenerate on next play.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: fileCount == 0
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.waves, size: 48, color: theme.colorScheme.outline),
                          const SizedBox(height: 8),
                          Text(
                            'No cached waveforms',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Play music with the waveform visualizer to generate waveform data',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : Center(
                      child: Text(
                        '$fileCount waveforms (${_formatBytes(totalBytes)})',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildChartsView(ThemeData theme) {
    final chartService = ChartCacheService.instance;

    return FutureBuilder(
      future: chartService.isInitialized
          ? Future.value(true)
          : chartService.initialize(),
      builder: (context, _) {
        final charts = chartService.getAllCharts();

        return Column(
          children: [
            // Clear all charts button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: charts.isEmpty
                          ? null
                          : () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Clear All Charts?'),
                                  content: Text('This will remove all ${charts.length} cached game charts and their scores. This cannot be undone.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: const Text('Clear'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await chartService.clearAllCharts();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('All charts cleared')),
                                  );
                                  setState(() {});
                                }
                              }
                            },
                      icon: const Icon(Icons.delete_sweep),
                      label: const Text('Clear All Charts'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Charts are generated rhythm game patterns for Frets on Fire mode. Clearing them will also reset your high scores.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: charts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.gamepad, size: 48, color: theme.colorScheme.outline),
                          const SizedBox(height: 8),
                          Text(
                            'No cached charts',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Play Frets on Fire mode to generate rhythm game charts',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: charts.length,
                      itemBuilder: (context, index) {
                        final chart = charts[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: theme.colorScheme.tertiaryContainer,
                            child: Icon(Icons.music_note, color: theme.colorScheme.onTertiaryContainer),
                          ),
                          title: Text(
                            chart.trackName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${chart.artistName} \u2022 Score: ${chart.highScore} \u2022 ${chart.notes.length} notes',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await chartService.deleteChart(chart.trackId);
                              if (context.mounted) {
                                setState(() {});
                              }
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(height: 4),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _ThemePickerSheet extends StatefulWidget {
  final NautuneColorPalette currentPalette;
  final Color? customPrimaryColor;
  final Color? customSecondaryColor;
  final Color? customAccentColor;
  final bool customIsLight;
  final ValueChanged<NautuneColorPalette> onSelectPreset;
  final void Function(Color primary, Color secondary, Color accent, bool isLight) onSelectCustom;

  const _ThemePickerSheet({
    required this.currentPalette,
    required this.customPrimaryColor,
    required this.customSecondaryColor,
    required this.customAccentColor,
    required this.customIsLight,
    required this.onSelectPreset,
    required this.onSelectCustom,
  });

  @override
  State<_ThemePickerSheet> createState() => _ThemePickerSheetState();
}

class _ThemePickerSheetState extends State<_ThemePickerSheet> {
  bool _showCustomPicker = false;
  late Color _primaryColor;
  late Color _secondaryColor;
  late Color _accentColor;
  late bool _isLightTheme;
  int _editingColor = 0;  // 0=primary, 1=secondary, 2=accent

  @override
  void initState() {
    super.initState();
    _primaryColor = widget.customPrimaryColor ?? const Color(0xFF6B21A8);
    _secondaryColor = widget.customSecondaryColor ?? const Color(0xFF9333EA);
    _accentColor = widget.customAccentColor ?? const Color(0xFF409CFF);
    _isLightTheme = widget.customIsLight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: 16,
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (_showCustomPicker)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _showCustomPicker = false),
                ),
              Expanded(
                child: Text(
                  _showCustomPicker ? 'Custom Theme' : 'Choose Theme',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _showCustomPicker
                ? 'Pick your own primary and secondary colors'
                : 'Select a preset or create your own',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          if (_showCustomPicker) ...[
            // Custom color picker UI
            _buildCustomColorPicker(theme),
          ] else ...[
            // Preset grid
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1.5,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: NautunePalettes.presets.length + 1, // +1 for custom
              itemBuilder: (context, index) {
                if (index == NautunePalettes.presets.length) {
                  // Custom theme card
                  return _CustomThemeCard(
                    isSelected: widget.currentPalette.id == 'custom',
                    primaryColor: widget.customPrimaryColor ?? const Color(0xFF6B21A8),
                    secondaryColor: widget.customSecondaryColor ?? const Color(0xFF9333EA),
                    accentColor: widget.customAccentColor ?? const Color(0xFF409CFF),
                    isLight: widget.customIsLight,
                    onTap: () => setState(() => _showCustomPicker = true),
                  );
                }
                final palette = NautunePalettes.presets[index];
                final isSelected = palette.id == widget.currentPalette.id;

                return _ThemePaletteCard(
                  palette: palette,
                  isSelected: isSelected,
                  onTap: () => widget.onSelectPreset(palette),
                );
              },
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildCustomColorPicker(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Light/Dark mode toggle
        Card(
          child: SwitchListTile(
            title: const Text('Light Theme'),
            subtitle: Text(_isLightTheme ? 'Light background' : 'Dark background'),
            value: _isLightTheme,
            onChanged: (value) => setState(() => _isLightTheme = value),
            secondary: Icon(_isLightTheme ? Icons.light_mode : Icons.dark_mode),
          ),
        ),
        const SizedBox(height: 16),

        // Color selection tabs
        Row(
          children: [
            Expanded(
              child: _ColorSelectionButton(
                label: 'Primary',
                color: _primaryColor,
                isSelected: _editingColor == 0,
                onTap: () => setState(() => _editingColor = 0),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ColorSelectionButton(
                label: 'Secondary',
                color: _secondaryColor,
                isSelected: _editingColor == 1,
                onTap: () => setState(() => _editingColor = 1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ColorSelectionButton(
                label: 'Accent',
                color: _accentColor,
                isSelected: _editingColor == 2,
                onTap: () => setState(() => _editingColor = 2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Color picker - using HueRingPicker for compact layout
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: HueRingPicker(
              pickerColor: _editingColor == 0 ? _primaryColor : (_editingColor == 1 ? _secondaryColor : _accentColor),
              onColorChanged: (color) {
                setState(() {
                  if (_editingColor == 0) {
                    _primaryColor = color;
                  } else if (_editingColor == 1) {
                    _secondaryColor = color;
                  } else {
                    _accentColor = color;
                  }
                });
              },
              enableAlpha: false,
              displayThumbColor: true,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Preview
        Text('Preview', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Container(
          height: 80,
          decoration: BoxDecoration(
            color: _isLightTheme
                ? Color.lerp(Colors.white, _primaryColor, 0.03)
                : HSLColor.fromColor(_primaryColor).withLightness(0.08).toColor(),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _primaryColor, width: 2),
          ),
          child: Row(
            children: [
              const SizedBox(width: 16),
              _ColorCircle(color: _primaryColor, size: 32),
              const SizedBox(width: 8),
              _ColorCircle(color: _secondaryColor, size: 32),
              const SizedBox(width: 8),
              _ColorCircle(color: _accentColor, size: 32),
              const Spacer(),
              Text(
                'Your Theme',
                style: TextStyle(
                  color: _isLightTheme
                      ? HSLColor.fromColor(_primaryColor).withLightness(0.25).toColor()
                      : _accentColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Apply button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () {
              widget.onSelectCustom(_primaryColor, _secondaryColor, _accentColor, _isLightTheme);
            },
            icon: const Icon(Icons.check),
            label: const Text('Apply Custom Theme'),
          ),
        ),
      ],
    );
  }
}

class _ColorSelectionButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _ColorSelectionButton({
    required this.label,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.2) : theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : theme.dividerColor,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ColorCircle(color: color, size: 24),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomThemeCard extends StatelessWidget {
  final bool isSelected;
  final Color primaryColor;
  final Color secondaryColor;
  final Color accentColor;
  final bool isLight;
  final VoidCallback onTap;

  const _CustomThemeCard({
    required this.isSelected,
    required this.primaryColor,
    required this.secondaryColor,
    required this.accentColor,
    required this.isLight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surface = isLight
        ? Color.lerp(Colors.white, primaryColor, 0.03)!
        : HSLColor.fromColor(primaryColor).withLightness(0.08).toColor();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [primaryColor.withValues(alpha: 0.3), secondaryColor.withValues(alpha: 0.3)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? primaryColor : primaryColor.withValues(alpha: 0.5),
              width: isSelected ? 3 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              // Color preview circles
              Positioned(
                top: 12,
                left: 12,
                child: Row(
                  children: [
                    _ColorCircle(color: primaryColor, size: 24),
                    const SizedBox(width: 6),
                    _ColorCircle(color: secondaryColor, size: 24),
                    const SizedBox(width: 6),
                    _ColorCircle(color: accentColor, size: 24),
                  ],
                ),
              ),
              // Theme name
              Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Text(
                  'Custom',
                  style: TextStyle(
                    color: isLight ? Colors.black87 : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Selected indicator
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: primaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: surface,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePaletteCard extends StatelessWidget {
  final NautuneColorPalette palette;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemePaletteCard({
    required this.palette,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? palette.primary : palette.primary.withValues(alpha: 0.3),
              width: isSelected ? 3 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: palette.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              // Color preview circles
              Positioned(
                top: 12,
                left: 12,
                child: Row(
                  children: [
                    _ColorCircle(color: palette.primary, size: 24),
                    const SizedBox(width: 6),
                    _ColorCircle(color: palette.secondary, size: 24),
                    const SizedBox(width: 6),
                    _ColorCircle(color: palette.textPrimary, size: 24),
                  ],
                ),
              ),
              // Theme name
              Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Text(
                  palette.name,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Selected indicator
              if (isSelected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: palette.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: palette.surface,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorCircle extends StatelessWidget {
  final Color color;
  final double size;

  const _ColorCircle({
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
    );
  }
}


class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;

  const _SectionHeader({
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Icon option for the app icon picker
class _IconOption extends StatelessWidget {
  final String assetPath;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _IconOption({
    required this.assetPath,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline.withValues(alpha: 0.3),
                width: isSelected ? 3 : 1,
              ),
              color: isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.1)
                  : Colors.transparent,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                assetPath,
                width: 80,
                height: 80,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected)
                Icon(
                  Icons.check_circle,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              if (isSelected) const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}