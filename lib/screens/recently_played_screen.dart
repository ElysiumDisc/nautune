import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/listening_analytics_service.dart';
import '../widgets/jellyfin_image.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/track_context_menu.dart';

class RecentlyPlayedScreen extends StatefulWidget {
  const RecentlyPlayedScreen({super.key, required this.appState});

  final NautuneAppState appState;

  @override
  State<RecentlyPlayedScreen> createState() => _RecentlyPlayedScreenState();
}

class _RecentlyPlayedScreenState extends State<RecentlyPlayedScreen> {
  late List<PlayEvent> _events;

  @override
  void initState() {
    super.initState();
    _events = ListeningAnalyticsService().getRecentEvents(limit: 200);
  }

  void _refresh() {
    setState(() {
      _events = ListeningAnalyticsService().getRecentEvents(limit: 200);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _groupByDay(_events);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently Played'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _events.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No listening history yet',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Play some tracks and they\'ll appear here',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: grouped.length,
              itemBuilder: (context, index) {
                final group = grouped[index];
                return _DayGroup(
                  label: group.label,
                  events: group.events,
                  appState: widget.appState,
                );
              },
            ),
      bottomNavigationBar: NowPlayingBar(
        audioService: widget.appState.audioPlayerService,
        appState: widget.appState,
      ),
    );
  }

  List<_DayGroupData> _groupByDay(List<PlayEvent> events) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekAgo = today.subtract(const Duration(days: 7));

    final todayEvents = <PlayEvent>[];
    final yesterdayEvents = <PlayEvent>[];
    final thisWeekEvents = <PlayEvent>[];
    final olderEvents = <PlayEvent>[];

    for (final event in events) {
      final eventDay = DateTime(event.timestamp.year, event.timestamp.month, event.timestamp.day);
      if (eventDay == today) {
        todayEvents.add(event);
      } else if (eventDay == yesterday) {
        yesterdayEvents.add(event);
      } else if (eventDay.isAfter(weekAgo)) {
        thisWeekEvents.add(event);
      } else {
        olderEvents.add(event);
      }
    }

    return [
      if (todayEvents.isNotEmpty)
        _DayGroupData(label: 'Today', events: todayEvents),
      if (yesterdayEvents.isNotEmpty)
        _DayGroupData(label: 'Yesterday', events: yesterdayEvents),
      if (thisWeekEvents.isNotEmpty)
        _DayGroupData(label: 'This Week', events: thisWeekEvents),
      if (olderEvents.isNotEmpty)
        _DayGroupData(label: 'Older', events: olderEvents),
    ];
  }
}

class _DayGroupData {
  final String label;
  final List<PlayEvent> events;

  const _DayGroupData({required this.label, required this.events});
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.label,
    required this.events,
    required this.appState,
  });

  final String label;
  final List<PlayEvent> events;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...events.map((event) => _EventTile(event: event, appState: appState)),
      ],
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.appState,
  });

  final PlayEvent event;
  final NautuneAppState appState;

  String _formatTime(DateTime timestamp) {
    final now = DateTime.now();
    final diff = now.difference(timestamp);

    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';

    return '${timestamp.month}/${timestamp.day}';
  }

  Future<void> _playTrack(BuildContext context) async {
    try {
      final track = await appState.jellyfinService.getTrack(event.trackId);
      if (track == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Track no longer available')),
        );
        return;
      }
      await appState.audioPlayerService.playTrack(track);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to play: $e')),
      );
    }
  }

  Future<void> _showContextMenu(BuildContext context) async {
    try {
      final track = await appState.jellyfinService.getTrack(event.trackId);
      if (track == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Track no longer available')),
        );
        return;
      }
      if (!context.mounted) return;
      showTrackContextMenu(
        context: context,
        track: track,
        appState: appState,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load track: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => _playTrack(context),
      onLongPress: () => _showContextMenu(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Album art
            SizedBox(
              width: 48,
              height: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: event.albumId != null
                    ? JellyfinImage(
                        itemId: event.albumId!,
                        imageTag: 'Primary',
                        maxWidth: 96,
                        boxFit: BoxFit.cover,
                        errorBuilder: (context, url, error) => Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.music_note,
                            color: theme.colorScheme.onSurfaceVariant,
                            size: 24,
                          ),
                        ),
                      )
                    : Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          color: theme.colorScheme.onSurfaceVariant,
                          size: 24,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            // Track info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.trackName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    event.artists.isNotEmpty
                        ? event.artists.join(', ')
                        : 'Unknown Artist',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Relative timestamp
            Text(
              _formatTime(event.timestamp),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
