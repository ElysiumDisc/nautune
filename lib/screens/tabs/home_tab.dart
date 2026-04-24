part of '../library_screen.dart';

class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({
    required this.title,
    this.subtitle,
    required this.onRefresh,
    required this.isLoading,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onRefresh;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isLoading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (isLoading) const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

class _ContinueListeningShelf extends StatelessWidget {
  const _ContinueListeningShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Continue Listening',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Nothing waiting for you yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _TrackChip extends StatelessWidget {
  const _TrackChip({required this.track, required this.onTap});

  final JellyfinTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 240,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: (track.albumId != null && track.albumPrimaryImageTag != null)
                    ? JellyfinImage(
                        itemId: track.albumId!,
                        imageTag: track.albumPrimaryImageTag,
                        trackId: track.id,
                        albumId: track.albumId,
                        maxWidth: 300,
                        boxFit: BoxFit.cover,
                        errorBuilder: (context, url, error) => Image.asset(
                          'assets/no_album_art.png',
                          fit: BoxFit.cover,
                        ),
                      )
                    : Image.asset(
                        'assets/no_album_art.png',
                        fit: BoxFit.cover,
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        track.displayArtist,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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

class _RecentlyAddedShelf extends StatelessWidget {
  const _RecentlyAddedShelf({
    required this.albums,
    required this.isLoading,
    required this.appState,
    required this.onAlbumTap,
    required this.onRefresh,
  });

  final List<JellyfinAlbum>? albums;
  final bool isLoading;
  final NautuneAppState appState;
  final void Function(JellyfinAlbum) onAlbumTap;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = albums != null && albums!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Recently Added',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 240,
          child: !hasData && isLoading
              ? const SkeletonAlbumShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: albums!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final album = albums![index];
                        return _MiniAlbumCard(
                          album: album,
                          appState: appState,
                          onTap: () => onAlbumTap(album),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No new albums yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _RecentlyPlayedShelf extends StatelessWidget {
  const _RecentlyPlayedShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
    required this.appState,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ShelfHeader(
                title: 'Recently Played',
                onRefresh: onRefresh,
                isLoading: isLoading,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 16),
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecentlyPlayedScreen(appState: appState),
                    ),
                  );
                },
                child: Text(
                  'View All',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No recently played tracks.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _DiscoverShelf extends StatelessWidget {
  const _DiscoverShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'Discover',
          subtitle: 'Albums you rarely play',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No tracks to discover yet.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

class _RecommendationsShelf extends StatelessWidget {
  const _RecommendationsShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
    this.seedTrackName,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;
  final String? seedTrackName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;
    final subtitle = seedTrackName != null
        ? 'Based on "$seedTrackName"'
        : 'Based on your listening';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'For You',
          subtitle: subtitle,
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Play some music to get recommendations.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }
}

/// ListenBrainz Discovery shelf - shows personalized recommendations from ListenBrainz
class _ListenBrainzDiscoveryShelf extends StatefulWidget {
  const _ListenBrainzDiscoveryShelf({
    required this.appState,
  });

  final NautuneAppState appState;

  @override
  State<_ListenBrainzDiscoveryShelf> createState() => _ListenBrainzDiscoveryShelfState();
}

class _ListenBrainzDiscoveryShelfState extends State<_ListenBrainzDiscoveryShelf> {
  List<ListenBrainzRecommendation>? _recommendations;
  List<JellyfinTrack>? _matchedTracks;
  bool _isLoading = false;
  bool _hasChecked = false;

  @override
  void initState() {
    super.initState();
    _loadRecommendations();
  }

  Future<void> _loadRecommendations() async {
    debugPrint('🎵 ListenBrainz Discovery: Starting to load recommendations...');
    final listenBrainz = ListenBrainzService();

    // Wait for ListenBrainz to initialize if not ready yet (max 3 seconds)
    if (!listenBrainz.isInitialized) {
      debugPrint('🎵 ListenBrainz Discovery: Waiting for service to initialize...');
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (listenBrainz.isInitialized) break;
      }
    }

    // Only show if user has connected and enabled scrobbling
    if (!listenBrainz.isConfigured) {
      debugPrint('🎵 ListenBrainz Discovery: Not configured, skipping');
      if (mounted) setState(() => _hasChecked = true);
      return;
    }
    if (!listenBrainz.isScrobblingEnabled) {
      debugPrint('🎵 ListenBrainz Discovery: Scrobbling disabled, skipping');
      if (mounted) setState(() => _hasChecked = true);
      return;
    }
    debugPrint('🎵 ListenBrainz Discovery: User ${listenBrainz.username} is configured, fetching...');

    if (mounted) setState(() => _isLoading = true);

    try {
      // Use efficient batch matching - stops early when we have enough matches
      final libraryId = widget.appState.selectedLibraryId;
      if (libraryId == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasChecked = true;
          });
        }
        return;
      }

      final matched = await listenBrainz.getDiscoveryRecommendations(
        jellyfin: widget.appState.jellyfinService,
        libraryId: libraryId,
        targetMatches: 20,
        maxFetch: 50,
      );

      debugPrint('🎵 ListenBrainz Discovery: Got ${matched.length} recommendations (${matched.where((r) => r.isInLibrary).length} in library)');

      if (!mounted) return;

      if (matched.isEmpty) {
        debugPrint('🎵 ListenBrainz Discovery: No recommendations returned from API');
        setState(() {
          _recommendations = [];
          _matchedTracks = [];
          _isLoading = false;
          _hasChecked = true;
        });
        return;
      }

      // Get tracks that are in library
      final inLibraryRecs = matched.where((r) => r.isInLibrary).toList();
      final tracks = <JellyfinTrack>[];

      for (final rec in inLibraryRecs.take(20)) {
        if (rec.jellyfinTrackId != null) {
          try {
            final track = await widget.appState.jellyfinService.getTrack(rec.jellyfinTrackId!);
            if (track != null) {
              tracks.add(track);
            }
          } catch (e) {
            // Skip failed track fetches
          }
        }
      }

      if (!mounted) return;

      setState(() {
        _recommendations = matched;
        _matchedTracks = tracks;
        _isLoading = false;
        _hasChecked = true;
      });
    } catch (e) {
      debugPrint('ListenBrainz discovery error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasChecked = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listenBrainz = ListenBrainzService();

    // Don't show if not connected or scrobbling is disabled
    if ((!listenBrainz.isConfigured || !listenBrainz.isScrobblingEnabled) && _hasChecked) {
      return const SizedBox.shrink();
    }

    // Get recommendations NOT in library (for discovery section)
    // Only show LB Radio and Fresh Release items — CF recommendations are
    // excluded because unmatched CF results are usually false negatives
    // (library tracks that failed fuzzy matching), not true discoveries.
    final notInLibraryRecs = _recommendations
        ?.where((r) => !r.isInLibrary && r.artistName != null &&
            (r.trackName != null || r.albumName != null) &&
            r.source != RecommendationSource.cfRecommendation)
        .take(10)
        .toList() ?? [];

    final hasMatchedData = _matchedTracks != null && _matchedTracks!.isNotEmpty;
    final hasDiscoveryData = notInLibraryRecs.isNotEmpty;

    // Don't show if no recommendations at all
    if (_hasChecked && !hasMatchedData && !hasDiscoveryData) {
      return const SizedBox.shrink();
    }

    final inLibraryCount = _recommendations?.where((r) => r.isInLibrary).length ?? 0;
    final totalCount = _recommendations?.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ListenBrainz Mix - tracks in your library
        if (hasMatchedData || _isLoading) ...[
          _ShelfHeader(
            title: 'ListenBrainz Mix',
            subtitle: '$inLibraryCount of $totalCount in your library',
            onRefresh: _loadRecommendations,
            isLoading: _isLoading,
          ),
          SizedBox(
            height: 140,
            child: !hasMatchedData && _isLoading
                ? const SkeletonTrackShelf()
                : hasMatchedData
                    ? ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _matchedTracks!.length,
                        separatorBuilder: (context, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final track = _matchedTracks![index];
                          return _TrackChip(
                            track: track,
                            onTap: () {
                              widget.appState.audioPlayerService.playTrack(
                                track,
                                queueContext: _matchedTracks!,
                              );
                            },
                          );
                        },
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Getting recommendations from ListenBrainz...',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
          ),
          const SizedBox(height: 20),
        ],

        // Discover New Music - tracks NOT in your library
        if (hasDiscoveryData) ...[
          _ShelfHeader(
            title: 'Discover New Music',
            subtitle: 'Based on your ListenBrainz history',
            onRefresh: _loadRecommendations,
            isLoading: _isLoading,
          ),
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: notInLibraryRecs.length,
              separatorBuilder: (context, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final rec = notInLibraryRecs[index];
                return _DiscoveryChip(
                  trackName: rec.trackName,
                  artistName: rec.artistName!,
                  albumName: rec.albumName,
                  coverArtUrl: rec.coverArtUrl,
                  source: rec.source,
                );
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

/// Chip for discovery recommendations (tracks not in library)
class _DiscoveryChip extends StatelessWidget {
  const _DiscoveryChip({
    this.trackName,
    required this.artistName,
    this.albumName,
    this.coverArtUrl,
    this.source = RecommendationSource.cfRecommendation,
  });

  final String? trackName;
  final String artistName;
  final String? albumName;
  final String? coverArtUrl;
  final RecommendationSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFreshRelease = source == RecommendationSource.freshRelease;
    final badgeIcon = isFreshRelease ? Icons.new_releases : Icons.explore;
    final badgeText = isFreshRelease ? 'New Release' : 'Discover';
    final displayName = trackName ?? albumName ?? 'Unknown';

    return SizedBox(
      width: 200,
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            // Album art from Cover Art Archive
            if (coverArtUrl != null)
              SizedBox(
                width: 80,
                height: 100,
                child: CachedNetworkImage(
                  imageUrl: coverArtUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (context, url, error) => Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: Icon(
                      Icons.album,
                      size: 32,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: 80,
                height: 100,
                color: theme.colorScheme.surfaceContainerHigh,
                child: Icon(
                  Icons.album,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            // Track info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          badgeIcon,
                          size: 12,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            badgeText,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      displayName,
                      style: theme.textTheme.titleSmall?.copyWith(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      artistName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnThisDayShelf extends StatelessWidget {
  const _OnThisDayShelf({
    required this.tracks,
    required this.isLoading,
    required this.onPlay,
    required this.onRefresh,
  });

  final List<JellyfinTrack>? tracks;
  final bool isLoading;
  final void Function(JellyfinTrack) onPlay;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = tracks != null && tracks!.isNotEmpty;
    final now = DateTime.now();
    final dayOrdinal = _ordinal(now.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ShelfHeader(
          title: 'On This Day',
          subtitle: 'Tracks you played on the $dayOrdinal',
          onRefresh: onRefresh,
          isLoading: isLoading,
        ),
        SizedBox(
          height: 140,
          child: !hasData && isLoading
              ? const SkeletonTrackShelf()
              : hasData
                  ? ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: tracks!.length,
                      separatorBuilder: (context, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final track = tracks![index];
                        return _TrackChip(
                          track: track,
                          onTap: () => onPlay(track),
                        );
                      },
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'No listening history for this date.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
        ),
      ],
    );
  }

  String _ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1: return '${day}st';
      case 2: return '${day}nd';
      case 3: return '${day}rd';
      default: return '${day}th';
    }
  }
}

// Most Tab with toggles for different views
class _MostPlayedTab extends StatefulWidget {
  const _MostPlayedTab({
    required this.appState,
    required this.onAlbumTap,
  });

  final NautuneAppState appState;
  final Function(JellyfinAlbum) onAlbumTap;

  @override
  State<_MostPlayedTab> createState() => _MostPlayedTabState();
}

class _MostPlayedTabState extends State<_MostPlayedTab> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heroShelves = _buildHomeHeroShelves();

    return _buildContent(theme, heroShelves);
  }

  Widget _buildContent(ThemeData theme, Widget? heroShelves) {
    if (heroShelves == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.music_note,
                size: 64,
                color: theme.colorScheme.secondary.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No content available',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Start playing some music to see recommendations here',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return _buildScrollableState(
      [heroShelves],
      null,
      applyBodyPadding: false,
    );
  }

  Widget _buildScrollableState(
    List<Widget> header,
    Widget? body, {
    bool applyBodyPadding = true,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        ...header,
        if (body != null)
          if (applyBodyPadding)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: body,
            )
          else
            body,
        const SizedBox(height: 16),
      ],
    );
  }

  Widget? _buildHomeHeroShelves() {
    if (widget.appState.isOfflineMode) {
      return null;
    }

    final continueTracks = widget.appState.recentTracks;
    final continueLoading = widget.appState.isLoadingRecent;
    final recentlyPlayed = widget.appState.recentlyPlayedTracks;
    final recentlyPlayedLoading = widget.appState.isLoadingRecentlyPlayed;
    final recentlyAdded = widget.appState.recentlyAddedAlbums;
    final recentlyAddedLoading = widget.appState.isLoadingRecentlyAdded;
    final discoverTracks = widget.appState.discoverTracks;
    final discoverLoading = widget.appState.isLoadingDiscover;
    final onThisDayTracks = widget.appState.onThisDayTracks;
    final onThisDayLoading = widget.appState.isLoadingOnThisDay;
    final recommendationTracks = widget.appState.recommendationTracks;
    final recommendationLoading = widget.appState.isLoadingRecommendations;
    final recommendationSeedName = widget.appState.recommendationSeedTrackName;

    final showContinue = continueLoading || (continueTracks != null && continueTracks.isNotEmpty);
    final showRecentlyPlayed = recentlyPlayedLoading || (recentlyPlayed != null && recentlyPlayed.isNotEmpty);
    final showRecentlyAdded = recentlyAddedLoading || (recentlyAdded != null && recentlyAdded.isNotEmpty);
    final showDiscover = discoverLoading || (discoverTracks != null && discoverTracks.isNotEmpty);
    final showOnThisDay = onThisDayLoading || (onThisDayTracks != null && onThisDayTracks.isNotEmpty);
    final showRecommendations = recommendationLoading || (recommendationTracks != null && recommendationTracks.isNotEmpty);

    if (!showContinue && !showRecentlyPlayed && !showRecentlyAdded && !showDiscover && !showOnThisDay && !showRecommendations) {
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        if (showContinue) ...[
          _ContinueListeningShelf(
            tracks: continueTracks,
            isLoading: continueLoading,
            onPlay: (track) {
              final queue = continueTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecent(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecentlyPlayed) ...[
          _RecentlyPlayedShelf(
            tracks: recentlyPlayed,
            isLoading: recentlyPlayedLoading,
            appState: widget.appState,
            onPlay: (track) {
              final queue = recentlyPlayed ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecentlyPlayed(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecentlyAdded) ...[
          _RecentlyAddedShelf(
            albums: recentlyAdded,
            isLoading: recentlyAddedLoading,
            appState: widget.appState,
            onAlbumTap: widget.onAlbumTap,
            onRefresh: () => widget.appState.refreshRecentlyAdded(),
          ),
          const SizedBox(height: 20),
        ],
        if (showDiscover) ...[
          _DiscoverShelf(
            tracks: discoverTracks,
            isLoading: discoverLoading,
            onPlay: (track) {
              final queue = discoverTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshDiscover(),
          ),
          const SizedBox(height: 20),
        ],
        if (showOnThisDay) ...[
          _OnThisDayShelf(
            tracks: onThisDayTracks,
            isLoading: onThisDayLoading,
            onPlay: (track) {
              final queue = onThisDayTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshOnThisDay(),
          ),
          const SizedBox(height: 20),
        ],
        if (showRecommendations) ...[
          _RecommendationsShelf(
            tracks: recommendationTracks,
            isLoading: recommendationLoading,
            seedTrackName: recommendationSeedName,
            onPlay: (track) {
              final queue = recommendationTracks ?? const <JellyfinTrack>[];
              widget.appState.audioPlayerService.playTrack(
                track,
                queueContext: queue,
              );
            },
            onRefresh: () => widget.appState.refreshRecommendations(),
          ),
          const SizedBox(height: 20),
        ],
        // ListenBrainz Discovery - only show if connected
        _ListenBrainzDiscoveryShelf(
          appState: widget.appState,
        ),
      ],
    );
  }
}
