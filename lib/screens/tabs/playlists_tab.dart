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
  final VoidCallback onRefresh;
  final NautuneAppState appState;

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  Mood? _loadingMood;

  @override
  void initState() {
    super.initState();
    // Refresh available SyncPlay groups when entering the tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<SyncPlayProvider>().refreshGroups();
      }
    });
  }

  // Convenience getters
  List<JellyfinPlaylist>? get playlists => widget.playlists;
  bool get isLoading => widget.isLoading;
  Object? get error => widget.error;
  ScrollController get scrollController => widget.scrollController;
  VoidCallback get onRefresh => widget.onRefresh;
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
        // Play the mood mix
        appState.audioService.playTrack(
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

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
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
        onRefresh: () async => onRefresh(),
        child: CustomScrollView(
          slivers: [
            // Active Collab Session Card (if in session and online)
            SliverToBoxAdapter(
              child: Consumer<SyncPlayProvider>(
                builder: (context, syncPlay, _) {
                  if (!syncPlay.isInSession || appState.isOfflineMode) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      color: theme.colorScheme.primaryContainer,
                      child: InkWell(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const CollabPlaylistScreen(),
                            ),
                          );
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.group,
                                  color: theme.colorScheme.onPrimary,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Active Collab Session',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      syncPlay.groupName ?? 'Fleet Mode',
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${syncPlay.participants.length} listeners • ${syncPlay.queue.length} tracks',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Available Collab Sessions (Empty State)
            SliverToBoxAdapter(
              child: Consumer<SyncPlayProvider>(
                builder: (context, syncPlay, _) {
                  if (syncPlay.isInSession || syncPlay.availableGroups.isEmpty || appState.isOfflineMode) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Join a Session',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...syncPlay.availableGroups.map((group) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.group_add,
                                color: theme.colorScheme.onSecondaryContainer,
                                size: 20,
                              ),
                            ),
                            title: Text(group.groupName),
                            subtitle: Text('${group.participantCount} active listeners'),
                            trailing: FilledButton.tonal(
                              onPressed: () async {
                                try {
                                  await syncPlay.joinCollabPlaylist(group.groupId);
                                  if (context.mounted) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => const CollabPlaylistScreen(),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to join: $e')),
                                    );
                                  }
                                }
                              },
                              child: const Text('Join'),
                            ),
                          ),
                        )),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Empty state content
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.playlist_play, size: 64, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    const Text('No playlists found'),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () async {
                        await _showCreatePlaylistDialog(context);
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Create Playlist'),
                    ),
                    const SizedBox(height: 12),
                    if (!appState.isOfflineMode)
                      OutlinedButton.icon(
                        onPressed: () {
                          _showCreateCollabPlaylistDialog(context);
                        },
                        icon: const Icon(Icons.group_add),
                        label: const Text('Create Fleet'),
                      ),
                    if (!appState.isOfflineMode)
                      const SizedBox(height: 12),
                    if (!appState.isOfflineMode)
                      OutlinedButton.icon(
                        onPressed: () {
                          _showJoinCollabPlaylistDialog(context);
                        },
                        icon: const Icon(Icons.link),
                        label: const Text('Join via Link'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        controller: scrollController,
        cacheExtent: 500, // Pre-render items above/below viewport for smoother scrolling
        padding: const EdgeInsets.all(16),
        itemCount: playlists!.length + (isLoading ? 1 : 0) + 1, // +1 for header button
        itemBuilder: (context, index) {
          // Add header buttons as first items
          if (index == 0) {
            final theme = Theme.of(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Active Collab Session Card (hidden in offline mode)
                Consumer<SyncPlayProvider>(
                  builder: (context, syncPlay, _) {
                    if (!syncPlay.isInSession || appState.isOfflineMode) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Card(
                        color: theme.colorScheme.primaryContainer,
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const CollabPlaylistScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.group,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Active Collab Session',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        syncPlay.groupName ?? 'Fleet Mode',
                                        style: theme.textTheme.titleMedium?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: theme.colorScheme.onPrimaryContainer,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${syncPlay.participants.length} listeners • ${syncPlay.queue.length} tracks',
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // Available Collab Sessions
                Consumer<SyncPlayProvider>(
                  builder: (context, syncPlay, _) {
                    if (syncPlay.isInSession || syncPlay.availableGroups.isEmpty || appState.isOfflineMode) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Join a Session',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        ...syncPlay.availableGroups.map((group) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.group_add,
                                color: theme.colorScheme.onSecondaryContainer,
                                size: 20,
                              ),
                            ),
                            title: Text(group.groupName),
                            subtitle: Text('${group.participantCount} active listeners'),
                            trailing: FilledButton.tonal(
                              onPressed: () async {
                                try {
                                  await syncPlay.joinCollabPlaylist(group.groupId);
                                  if (context.mounted) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) => const CollabPlaylistScreen(),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Failed to join: $e')),
                                    );
                                  }
                                }
                              },
                              child: const Text('Join'),
                            ),
                          ),
                        )),
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                ),

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
                if (!appState.isOfflineMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showCreateCollabPlaylistDialog(context);
                      },
                      icon: const Icon(Icons.group_add),
                      label: const Text('Create Fleet'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        side: BorderSide(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                if (!appState.isOfflineMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        _showJoinCollabPlaylistDialog(context);
                      },
                      icon: const Icon(Icons.link),
                      label: const Text('Join via Link'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        side: BorderSide(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                // Smart Mix Section
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
                const SizedBox(height: 16),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Text(
                    'Your Playlists',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            );
          }

          final listIndex = index - 1;
          if (listIndex >= playlists!.length) {
            return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator()));
          }
          final playlist = playlists![listIndex];
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

  Future<void> _showCreatePlaylistDialog(BuildContext context) async {
    final nameController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Playlist'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Playlist Name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty && context.mounted) {
      try {
        await appState.createPlaylist(name: nameController.text);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Created playlist "${nameController.text}"'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to create playlist: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  void _showCreateCollabPlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const CreateCollabDialog(),
    );
  }

  void _showJoinCollabPlaylistDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const JoinCollabDialog(),
    );
  }

  void _showEditPlaylistDialog(BuildContext context, JellyfinPlaylist playlist) async {
    final nameController = TextEditingController(text: playlist.name);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Playlist'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'Playlist Name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty && context.mounted) {
      try {
        await appState.updatePlaylist(
          playlistId: playlist.id,
          newName: nameController.text,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Renamed to "${nameController.text}"'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to rename: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }

  void _showDeletePlaylistDialog(BuildContext context, JellyfinPlaylist playlist) async {

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist?'),
        content: Text('Are you sure you want to delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true && context.mounted) {
      try {
        await appState.deletePlaylist(playlist.id);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "${playlist.name}"'),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    }
  }
}
