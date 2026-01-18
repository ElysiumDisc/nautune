import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/playback_state.dart' show StreamingQuality, StreamingQualityExtension;
import '../providers/session_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/ui_state_provider.dart';
import '../services/audio_cache_service.dart';
import '../services/download_service.dart';
import '../theme/nautune_theme.dart';
import '../widgets/equalizer_widget.dart';

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

  Widget _buildAppearanceSection(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final appState = Provider.of<NautuneAppState>(context);

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
              ListTile(
                leading: Icon(Icons.waves, color: theme.colorScheme.primary),
                title: const Text('Animated Visualizer'),
                subtitle: Text(
                  appState.visualizerEnabled
                      ? 'Bioluminescent waves enabled'
                      : 'Disabled for battery savings'
                ),
                trailing: Switch(
                  value: appState.visualizerEnabled,
                  onChanged: (value) {
                    appState.setVisualizerEnabled(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
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
          const _SectionHeader(icon: Icons.info_outline, title: 'About'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Column(
              children: [
                FutureBuilder<String>(
                  future: _packageVersion(),
                  builder: (context, snapshot) {
                    final version = snapshot.data ?? '…';
                    return ListTile(
                      leading: Icon(Icons.anchor, color: theme.colorScheme.primary),
                      title: const Text('Nautune'),
                      subtitle: Text('Version $version'),
                    );
                  },
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

enum _StorageView { downloads, cache }

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
                                icon: Icons.album,
                                label: 'Albums',
                                value: '${stats.byAlbum.length}',
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

                  // Main view toggle: Downloads vs Cache
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<_StorageView>(
                      segments: const [
                        ButtonSegment(value: _StorageView.downloads, label: Text('Downloads'), icon: Icon(Icons.download)),
                        ButtonSegment(value: _StorageView.cache, label: Text('Cache'), icon: Icon(Icons.cached)),
                      ],
                      selected: {_currentView},
                      onSelectionChanged: (selection) {
                        setState(() => _currentView = selection.first);
                      },
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
                  ] else ...[
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
                                    title: const Text('Clear Cache?'),
                                    content: const Text('This will remove all pre-cached tracks. Downloads will not be affected.'),
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
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Cache cleared')),
                                    );
                                    setState(() {});
                                  }
                                }
                              },
                              icon: const Icon(Icons.delete_sweep),
                              label: const Text('Clear Cache'),
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
                        'Cache auto-expires after 7 days. These are temporary files pre-loaded for smooth playback.',
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
            Icon(Icons.cached, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'No cached tracks',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
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