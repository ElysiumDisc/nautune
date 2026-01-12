import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/playback_state.dart' show StreamingQuality, StreamingQualityExtension;
import '../providers/session_provider.dart';
import '../providers/ui_state_provider.dart';
import '../services/audio_cache_service.dart';
import '../services/download_service.dart';

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
          const SizedBox(height: 8),
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
              'Downloads',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListenableBuilder(
            listenable: appState.downloadService,
            builder: (context, _) {
              final downloadService = appState.downloadService;
              return Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.download, color: theme.colorScheme.primary),
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
                    leading: Icon(Icons.storage, color: theme.colorScheme.primary),
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
                        },
                      ),
                    ),
                  ),
                  ListTile(
                    leading: Icon(Icons.auto_delete, color: theme.colorScheme.primary),
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
                      },
                    ),
                  ),
                  if (downloadService.autoCleanupEnabled)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
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
                              },
                            ),
                          ),
                          const Text('90d'),
                        ],
                      ),
                    ),
                  ListTile(
                    leading: Icon(Icons.folder_open, color: theme.colorScheme.primary),
                    title: const Text('Manage Storage'),
                    subtitle: FutureBuilder<int>(
                      future: downloadService.getTotalDownloadSize(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          return Text('${downloadService.completedCount} tracks using ${_formatBytes(snapshot.data!)}');
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
              );
            },
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

class _StorageManagementScreen extends StatefulWidget {
  const _StorageManagementScreen();

  @override
  State<_StorageManagementScreen> createState() => _StorageManagementScreenState();
}

class _StorageManagementScreenState extends State<_StorageManagementScreen> {
  bool _showByAlbum = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<NautuneAppState>(context);
    final downloadService = appState.downloadService;

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
                                icon: Icons.storage,
                                label: 'Total Size',
                                value: stats.formattedTotal,
                              ),
                              _StatItem(
                                icon: Icons.music_note,
                                label: 'Tracks',
                                value: '${stats.trackCount}',
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
                              value: stats.totalBytes / (downloadService.storageLimitMB * 1024 * 1024),
                              backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${_formatBytes(stats.totalBytes)} of ${_formatBytes(downloadService.storageLimitMB * 1024 * 1024)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Quick actions
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

                  const SizedBox(height: 16),

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