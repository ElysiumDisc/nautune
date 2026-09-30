part of '../library_screen.dart';

class _PlaylistsTab extends StatefulWidget {
  const _PlaylistsTab({
    required this.playlists,
    required this.isLoading,
    required this.error,
    required this.scrollController,
    required this.onRefresh,
    required this.appState,
  });

  final List<JellyfinPlaylist>? playlists;
  final bool isLoading;
  final Object? error;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final NautuneAppState appState;

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  Mood? _loadingMood;

  // Sorted list, recomputed only when the list or the sort changes (not on
  // every library rebuild).
  List<JellyfinPlaylist>? _sortedSource;
  PlaylistSort? _sortedBy;
  List<JellyfinPlaylist> _sorted = const [];

  List<JellyfinPlaylist> _sortedFor(
      List<JellyfinPlaylist> source, PlaylistSort sort) {
    if (!identical(source, _sortedSource) || sort != _sortedBy) {
      _sortedSource = source;
      _sortedBy = sort;
      _sorted = sortPlaylists(source, sort);
    }
    return _sorted;
  }

  // Convenience getters
  List<JellyfinPlaylist>? get playlists => widget.playlists;
  bool get isLoading => widget.isLoading;
  Object? get error => widget.error;
  ScrollController get scrollController => widget.scrollController;
  Future<void> Function() get onRefresh => widget.onRefresh;
  NautuneAppState get appState => widget.appState;

  Future<void> _playMoodMix(Mood mood) async {
    if (_loadingMood != null) return; // Already loading

    setState(() => _loadingMood = mood);

    try {
      final libraryId = appState.selectedLibraryId;
      if (libraryId == null) {
        throw StateError('No library selected');
      }

      final service = SmartPlaylistService(
        jellyfinService: appState.jellyfinService,
        libraryId: libraryId,
      );

      final tracks = await service.generateMoodMix(mood, limit: 50);

      if (tracks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No ${mood.displayName.toLowerCase()} tracks found'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        // Play the mood mix (a failure is reported below, not as success)
        await appState.audioService.playTrack(
          tracks.first,
          queueContext: tracks,
          fromShuffle: true,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Playing ${mood.displayName} Mix - ${tracks.length} tracks'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Smart Mix error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate mix: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMood = null);
      }
    }
  }

  /// Result of a playlist edit: offline edits are queued (app state throws
  /// to say so), which isn't a failure.
  void _showEditResult(
    ScaffoldMessengerState messenger,
    ThemeData theme, {
    required String done,
    required String queued,
    required String failed,
    Object? error,
  }) {
    final isQueued = error != null && error.toString().contains('queued');
    messenger.showSnackBar(
      SnackBar(
        content: Text(error == null
            ? done
            : isQueued
                ? queued
                : '$failed: $error'),
        backgroundColor: error == null
            ? theme.colorScheme.primary
            : isQueued
                ? null
                : theme.colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Playlists we already have (cached or from before) win over an error.
    if (error != null && (playlists == null || playlists!.isEmpty)) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: NautuneSpacing.lg),
            const Text('Failed to load playlists'),
            const SizedBox(height: 8),
            ElevatedButton.icon(onPressed: onRefresh, icon: const Icon(Icons.refresh), label: const Text('Retry')),
          ],
        ),
      );
    }
    if (isLoading && (playlists == null || playlists!.isEmpty)) return const Center(child: CircularProgressIndicator());
    if (playlists == null || playlists!.isEmpty) {
      final theme = Theme.of(context);
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: CustomScrollView(
          slivers: [
            // Empty state content
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.playlist_play, size: 64, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: NautuneSpacing.lg),
                    const Text('No playlists found'),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await _showCreatePlaylistDialog(context);
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Create Playlist'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    final uiState = context.watch<UIStateProvider>();
    final sortedPlaylists = _sortedFor(playlists!, uiState.playlistSort);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        controller: scrollController,
        scrollCacheExtent: ScrollCacheExtent.pixels(500), // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.all(16),
        itemCount: sortedPlaylists.length + (isLoading ? 1 : 0) + 1, // +1 for header button
        itemBuilder: (context, index) {
          // Add header buttons as first items
          if (index == 0) {
            final theme = Theme.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await _showCreatePlaylistDialog(context);
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create New Playlist'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
                // Smart Mix needs the server.
                if (!appState.isOfflineMode) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smart Mix',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Generate a playlist based on mood',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Horizontal 1x4 Mood Cards (compact layout)
                  SizedBox(
                    height: 70,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: Mood.values.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) => _buildCompactMoodCard(Mood.values[index], theme),
                    ),
                  ),
                  const SizedBox(height: NautuneSpacing.lg),
                ],
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Your Playlists',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _SortMenuButton<PlaylistSort>(
                        current: uiState.playlistSort,
                        options: PlaylistSort.values,
                        labelOf: (s) => s.label,
                        onSelected: uiState.setPlaylistSort,
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          final listIndex = index - 1;
          if (listIndex >= sortedPlaylists.length) {
            return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
          }
          final playlist = sortedPlaylists[listIndex];
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: Icon(Icons.playlist_play, color: Theme.of(context).colorScheme.secondary),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PlaylistDetailScreen(
                      playlist: playlist,
                    ),
                  ),
                );
              },
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'edit') {
                    _showEditPlaylistDialog(context, playlist);
                  } else if (value == 'delete') {
                    _showDeletePlaylistDialog(context, playlist);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit),
                        SizedBox(width: 8),
                        Text('Edit'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
                        SizedBox(width: 8),
                        Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Compact mood card for horizontal 1x4 layout
  Widget _buildCompactMoodCard(Mood mood, ThemeData theme) {
    final isLoading = _loadingMood == mood;
    final gradientColors = _getMoodGradient(mood, theme);
    // Extract first genre from subtitle (e.g., "Jazz" from "Jazz, Blues, Ambient...")
    final firstGenre = mood.subtitle.split(',').first.trim();

    return SizedBox(
      width: 100,
      child: Material(
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isLoading ? null : () => _playMoodMix(mood),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        mood.displayName,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isLoading)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  firstGenre,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Color> _getMoodGradient(Mood mood, ThemeData theme) {
    switch (mood) {
      case Mood.chill:
        return [
          const Color(0xFF1A237E), // Deep blue
          const Color(0xFF4FC3F7), // Light blue
        ];
      case Mood.energetic:
        return [
          const Color(0xFFE65100), // Deep orange
          const Color(0xFFFFD54F), // Amber
        ];
      case Mood.melancholy:
        return [
          const Color(0xFF4A148C), // Deep purple
          const Color(0xFF9575CD), // Light purple
        ];
      case Mood.upbeat:
        return [
          const Color(0xFFC2185B), // Pink
          const Color(0xFFFFAB91), // Light coral
        ];
    }
  }

  /// Asks for a playlist name; null when cancelled or left empty.
  Future<String?> _askName({
    required String title,
    required String action,
    String initial = '',
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => _PlaylistNameDialog(
          title: title,
          action: action,
          initial: initial,
        ),
      );

  // Dialogs and snackbars use this State's context: a row's context is gone
  // once the list refreshes (e.g. the deleted playlist's row).
  Future<void> _showCreatePlaylistDialog(BuildContext _) async {
    final name = await _askName(title: 'Create Playlist', action: 'Create');
    if (name == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    Object? error;
    try {
      await appState.createPlaylist(name: name);
    } catch (e) {
      error = e;
    }
    _showEditResult(messenger, theme,
        done: 'Created playlist "$name"',
        queued: 'Offline: "$name" will be created when you\'re online',
        failed: 'Failed to create playlist',
        error: error);
  }

  Future<void> _showEditPlaylistDialog(
      BuildContext _, JellyfinPlaylist playlist) async {
    final name = await _askName(
      title: 'Edit Playlist',
      action: 'Save',
      initial: playlist.name,
    );
    if (name == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    Object? error;
    try {
      await appState.updatePlaylist(playlistId: playlist.id, newName: name);
    } catch (e) {
      error = e;
    }
    _showEditResult(messenger, theme,
        done: 'Renamed to "$name"',
        queued: 'Offline: the rename will sync when you\'re online',
        failed: 'Failed to rename',
        error: error);
  }

  Future<void> _showDeletePlaylistDialog(
      BuildContext _, JellyfinPlaylist playlist) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    Object? error;
    try {
      await appState.deletePlaylist(playlist.id);
    } catch (e) {
      error = e;
    }
    _showEditResult(messenger, theme,
        done: 'Deleted "${playlist.name}"',
        queued: 'Offline: "${playlist.name}" will be deleted when you\'re online',
        failed: 'Failed to delete',
        error: error);
  }
}

/// Asks for a playlist name; pops the trimmed name, or null when cancelled
/// or left empty. Owns (and disposes) its text controller, so the field
/// never outlives it during the closing animation.
class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.action,
    this.initial = '',
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    Navigator.pop(context, name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'Playlist Name',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
