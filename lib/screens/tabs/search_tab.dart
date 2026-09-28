part of '../library_screen.dart';

class _SearchTab extends StatefulWidget {
  const _SearchTab({required this.appState});

  final NautuneAppState appState;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final TextEditingController _controller = TextEditingController();
  final Debouncer _debouncer = Debouncer();
  List<String> _recentQueries = [];
  String _lastQuery = '';
  bool _isLoading = false;
  EasterEgg? _easterEgg;
  List<JellyfinAlbum> _albumResults = const [];
  List<JellyfinArtist> _artistResults = const [];
  List<JellyfinTrack> _trackResults = const [];
  Object? _error;

  /// Result filter; null shows every kind (with a Top result).
  SearchKind? _scope;
  static const int _previewCount = 5;
  static const int _historyLimit = 10;
  static const String _boxName = 'nautune_search_history';
  static const String _historyKey = 'global_search_history';

  @override
  void initState() {
    super.initState();
    _loadRecentQueries();
  }

  @override
  void dispose() {
    _debouncer.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<void> _loadRecentQueries() async {
    final box = await _box();
    if (!mounted) return;
    final raw = box.get(_historyKey);
    setState(() {
      if (raw is List) {
        _recentQueries = raw.cast<String>();
      } else {
        _recentQueries = [];
      }
    });
  }

  Future<void> _persistRecentQueries() async {
    final box = await _box();
    await box.put(_historyKey, _recentQueries);
  }

  Future<void> _clearRecentQueries() async {
    if (_recentQueries.isEmpty) return;
    setState(() {
      _recentQueries = [];
    });
    final box = await _box();
    await box.delete(_historyKey);
  }

  Future<void> _rememberQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final list = List<String>.from(_recentQueries);
    list.removeWhere((item) => item.toLowerCase() == trimmed.toLowerCase());
    list.insert(0, trimmed);
    while (list.length > _historyLimit) {
      list.removeLast();
    }
    setState(() {
      _recentQueries = list;
    });
    await _persistRecentQueries();
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    final lowerQuery = trimmed.toLowerCase();
    setState(() {
      _lastQuery = trimmed;
      _error = null;
    });

    if (trimmed.isEmpty) {
      setState(() {
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
        _isLoading = false;
        _easterEgg = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      // Easter eggs: show a special card when the whole query is a keyword
      _easterEgg = matchEasterEgg(trimmed);
    });
    unawaited(_rememberQuery(trimmed));

    // Demo mode: search bundled showcase data (all types)
    if (widget.appState.isDemoMode) {
      final albums = widget.appState.demoAlbums
          .where((album) =>
              album.name.toLowerCase().contains(lowerQuery) ||
              album.displayArtist.toLowerCase().contains(lowerQuery))
          .toList();
      final artists = widget.appState.demoArtists
          .where((artist) => artist.name.toLowerCase().contains(lowerQuery))
          .toList();
      final tracks = widget.appState.demoTracks
          .where((track) =>
              track.name.toLowerCase().contains(lowerQuery) ||
              (track.album?.toLowerCase().contains(lowerQuery) ?? false) ||
              track.displayArtist.toLowerCase().contains(lowerQuery))
          .toList();
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _albumResults = albums;
        _artistResults = artists;
        _trackResults = tracks;
        _isLoading = false;
      });
      return;
    }

    // Offline mode: search downloaded content only (global search)
    if (widget.appState.isOfflineMode) {
      try {
        final downloads = widget.appState.downloadService.completedDownloads;

        // Build album groups for album search - group by albumId, not name
        final Map<String, List<DownloadItem>> albumGroups = {};
        for (final download in downloads) {
          final key = download.track.albumId ?? download.track.album ?? 'Unknown Album';
          if (!albumGroups.containsKey(key)) {
            albumGroups[key] = [];
          }
          albumGroups[key]!.add(download);
        }

        // Filter albums by query (check album name from first track, since key is now an ID)
        final matchingAlbums = albumGroups.entries
            .where((entry) {
              final albumName = entry.value.first.track.album?.toLowerCase() ?? 'unknown album';
              return albumName.contains(lowerQuery);
            })
            .take(50)
            .map((entry) {
          final firstTrack = entry.value.first.track;
          return JellyfinAlbum(
            id: firstTrack.albumId ?? firstTrack.id,
            name: firstTrack.album ?? 'Unknown Album',
            artists: [firstTrack.displayArtist],
            artistIds: const [],
            productionYear: firstTrack.productionYear,
          );
        }).toList();

        // Build artist groups for artist search
        final Map<String, List<DownloadItem>> artistGroups = {};
        for (final download in downloads) {
          final artistName = download.track.displayArtist;
          if (!artistGroups.containsKey(artistName)) {
            artistGroups[artistName] = [];
          }
          artistGroups[artistName]!.add(download);
        }

        // Filter artists by query
        final matchingArtists = artistGroups.keys
            .where((name) => name.toLowerCase().contains(lowerQuery))
            .take(50)
            .map((name) => JellyfinArtist(
              id: 'offline_$name',
              name: name,
            ))
            .toList();

        // Filter tracks by query
        final matchingTracks = downloads
            .map((download) => download.track)
            .where((track) {
              final albumName = track.album?.toLowerCase() ?? '';
              return track.name.toLowerCase().contains(lowerQuery) ||
                  track.displayArtist.toLowerCase().contains(lowerQuery) ||
                  albumName.contains(lowerQuery);
            })
            .take(100)
            .toList();

        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _albumResults = matchingAlbums;
          _artistResults = matchingArtists;
          _trackResults = matchingTracks;
          _isLoading = false;
        });
      } catch (e) {
        if (!mounted || _lastQuery != trimmed) return;
        setState(() {
          _error = e;
          _albumResults = const [];
          _artistResults = const [];
          _trackResults = const [];
          _isLoading = false;
        });
      }
      return;
    }

    // Online mode: search Jellyfin server
    final libraryId = widget.appState.session?.selectedLibraryId;
    if (libraryId == null) {
      setState(() {
        _error = 'Select a music library to search.';
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
        _isLoading = false;
      });
      return;
    }

    try {
      // Global search - search all content types in parallel
      final results = await widget.appState.jellyfinService.searchAllBatch(
        libraryId: libraryId,
        query: trimmed,
      );
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _albumResults = results.albums;
        _artistResults = results.artists;
        _trackResults = results.tracks;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || _lastQuery != trimmed) return;
      setState(() {
        _error = error;
        _isLoading = false;
        _albumResults = const [];
        _artistResults = const [];
        _trackResults = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final libraryId = widget.appState.session?.selectedLibraryId;

    // Allow search in demo mode and offline mode even without a library
    if (libraryId == null && !widget.appState.isDemoMode && !widget.appState.isOfflineMode) {
      return Center(
        child: Text(
          'Choose a library to enable search.',
          style: theme.textTheme.titleMedium,
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: CupertinoSearchTextField(
            controller: _controller,
            placeholder: widget.appState.isOfflineMode
                ? 'Search your downloads'
                : 'Artists, albums, songs',
            style: theme.textTheme.body,
            itemColor: theme.colorScheme.onSurfaceVariant,
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            onChanged: (value) {
              setState(() {}); // recent searches show only while empty
              _debouncer.run(() => _performSearch(value));
            },
            onSubmitted: (value) {
              _debouncer.cancel();
              _performSearch(value);
            },
            onSuffixTap: () {
              _controller.clear();
              _debouncer.cancel();
              _performSearch('');
            },
          ),
        ),
        if (_lastQuery.isNotEmpty) _buildScopeBar(theme),
        if (_controller.text.trim().isEmpty && _recentQueries.isNotEmpty)
          _buildRecentQueriesSection(theme),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error.toString(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _buildResults(theme),
        ),
      ],
    );
  }

  Widget _buildRecentQueriesSection(ThemeData theme) {
    if (_recentQueries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Recent searches',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Clear recent searches',
                icon: const Icon(Icons.close),
                onPressed: () => unawaited(_clearRecentQueries()),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in _recentQueries)
                ActionChip(
                  label: Text(query),
                  onPressed: () {
                    _controller.text = query;
                    _performSearch(query);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResults(ThemeData theme) {
    if (_lastQuery.isEmpty) {
      return Center(
        child: Text(
          'Search across albums, artists, and tracks.',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    final hasResults = _albumResults.isNotEmpty ||
                      _artistResults.isNotEmpty ||
                      _trackResults.isNotEmpty ||
                      _easterEgg != null;

    if (!hasResults) {
      return Center(
        child: Text(
          'No results found for "$_lastQuery"',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    final scope = _scope;
    final top = scope == null
        ? topSearchResult<Object>(_lastQuery, [
            for (final a in _artistResults) SearchCandidate(SearchKind.artist, a.name, a),
            for (final a in _albumResults) SearchCandidate(SearchKind.album, a.name, a),
            for (final t in _trackResults) SearchCandidate(SearchKind.track, t.name, t),
          ])
        : null;
    List<T> limit<T>(List<T> items) =>
        scope == null ? items.take(_previewCount).toList() : items;
    bool show(SearchKind kind) => scope == null || scope == kind;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (_easterEgg != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildEasterEggCard(theme, _easterEgg!),
          ),
        if (top != null) _buildTopResult(theme, top),
        if (show(SearchKind.artist) && _artistResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Artists', SearchKind.artist, _artistResults.length),
          for (final artist in limit(_artistResults)) _buildArtistTile(theme, artist),
        ],
        if (show(SearchKind.album) && _albumResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Albums', SearchKind.album, _albumResults.length),
          for (final album in limit(_albumResults)) _buildAlbumTile(theme, album),
        ],
        if (show(SearchKind.track) && _trackResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Songs', SearchKind.track, _trackResults.length),
          for (final track in limit(_trackResults)) _buildTrackTile(theme, track),
        ],
      ],
    );
  }

  Widget _buildScopeBar(ThemeData theme) {
    final scopes = <(SearchKind?, String, int)>[
      (null, 'All', _artistResults.length + _albumResults.length + _trackResults.length),
      (SearchKind.artist, 'Artists', _artistResults.length),
      (SearchKind.album, 'Albums', _albumResults.length),
      (SearchKind.track, 'Songs', _trackResults.length),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final (kind, label, count) in scopes)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(kind == null || count == 0 ? label : '$label $count'),
                selected: _scope == kind,
                showCheckmark: false,
                labelStyle: theme.textTheme.subhead.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _scope == kind
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                ),
                onSelected: (_) {
                  HapticService.selectionClick();
                  setState(() => _scope = kind);
                },
              ),
            ),
        ],
      ),
    );
  }

  /// Big card for the best name match, as in Apple Music's search.
  Widget _buildTopResult(ThemeData theme, SearchCandidate<Object> top) {
    final style = NautuneStyle.of(context);
    final item = top.item;
    final (Widget art, String title, String subtitle, VoidCallback onTap) = switch (item) {
      JellyfinArtist a => (
          _artistArtwork(a, maxWidth: 200),
          a.name,
          'Artist',
          () => _openArtist(context, a),
        ),
      JellyfinAlbum a => (
          _albumArtwork(a, maxWidth: 200),
          a.name,
          'Album · ${a.displayArtist}',
          () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: a)),
              ),
        ),
      JellyfinTrack t => (
          _trackArtwork(t),
          t.name,
          'Song · ${t.displayArtist}',
          () => widget.appState.audioPlayerService.playTrack(t, queueContext: _trackResults),
        ),
      _ => (const SizedBox(), '', '', () {}),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Top Result', style: theme.textTheme.title3),
          const SizedBox(height: 8),
          Material(
            color: style.groupedCell,
            shape: style.shape(NautuneRadius.lg),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 88,
                      child: ClipPath(
                        clipper: ShapeBorderClipper(
                          shape: top.kind == SearchKind.artist
                              ? const CircleBorder()
                              : style.shape(NautuneRadius.md),
                        ),
                        child: art,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.title3, maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text(subtitle, style: theme.textTheme.footnote, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    if (top.kind == SearchKind.track)
                      Icon(Icons.play_circle_fill_rounded, size: 40, color: theme.colorScheme.primary),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEasterEggCard(ThemeData theme, EasterEgg egg) {
    switch (egg) {
      case EasterEgg.relaxMode:
        return _buildRelaxModeCard(theme);
      case EasterEgg.network:
        return _buildNetworkModeCard(theme);
      case EasterEgg.essentialMix:
        return _buildEssentialMixCard(theme);
      case EasterEgg.fretsOnFire:
        return _buildFretsOnFireCard(theme);
      case EasterEgg.piano:
        return _buildPianoCard(theme);
      case EasterEgg.healingFrequencies:
        return _buildHealingFrequenciesCard(theme);
    }
  }

  Widget _buildRelaxModeCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        leading: Icon(Icons.spa, color: theme.colorScheme.primary),
        title: const Text('Relax Mode'),
        subtitle: const Text('Ambient sound mixer'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const RelaxModeScreen()),
        ),
      ),
    );
  }

  Widget _buildNetworkModeCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: Colors.black,
      child: ListTile(
        leading: const Icon(Icons.radio, color: Colors.white),
        title: const Text(
          'The Network',
          style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
        ),
        subtitle: const Text(
          'Other People Radio 0-333',
          style: TextStyle(color: Colors.white70, fontFamily: 'monospace'),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const NetworkScreen()),
        ),
      ),
    );
  }

  Widget _buildEssentialMixCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xFF1A1A2E),
      child: ListTile(
        leading: const Icon(Icons.album, color: Colors.deepPurple),
        title: const Text(
          'Essential Mix',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Soulwax / 2ManyDJs • BBC Radio 1',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const EssentialMixScreen()),
        ),
      ),
    );
  }

  Widget _buildFretsOnFireCard(ThemeData theme) {
    return Card(
      color: Colors.deepOrange.shade900,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.local_fire_department, color: Colors.orange),
        title: const Text(
          'Frets on Fire',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Guitar Hero-style rhythm game',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const FretsOnFireScreen()),
        ),
      ),
    );
  }

  Widget _buildPianoCard(ThemeData theme) {
    return Card(
      color: const Color(0xFF1A1A2E),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.piano, color: Colors.white),
        title: const Text(
          'Piano',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Playable synth keyboard',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const PianoScreen()),
        ),
      ),
    );
  }

  Widget _buildHealingFrequenciesCard(ThemeData theme) {
    return Card(
      color: const Color(0xFF142B2E),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.graphic_eq, color: Color(0xFF80DEEA)),
        title: const Text(
          'Healing Frequencies',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: const Text(
          'Solfeggio, Chakras, Schumann & more — offline-ready',
          style: TextStyle(color: Colors.white70),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white54),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const HealingFrequenciesScreen()),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildSectionHeader(ThemeData theme, String title, SearchKind kind, int count) {
    final more = _scope == null && count > _previewCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.title3)),
          if (more)
            TextButton(
              onPressed: () => setState(() => _scope = kind),
              child: Text('See All $count'),
            ),
        ],
      ),
    );
  }

  Widget _trackArtwork(JellyfinTrack track) {
    final albumId = track.albumId;
    final tag = track.albumPrimaryImageTag ?? track.primaryImageTag;
    if (tag == null || tag.isEmpty) {
      return Image.asset('assets/no_album_art.png', fit: BoxFit.cover);
    }
    return JellyfinImage(
      itemId: track.albumPrimaryImageTag != null ? (albumId ?? track.id) : track.id,
      imageTag: tag,
      trackId: track.id,
      maxWidth: 100,
      boxFit: BoxFit.cover,
      errorBuilder: (context, url, error) =>
          Image.asset('assets/no_album_art.png', fit: BoxFit.cover),
    );
  }

  Widget _buildArtistTile(ThemeData theme, JellyfinArtist artist) {
    return SizedBox(
      height: LibraryTileMetrics.of(context).listRowExtent,
      child: LibraryListRow(
        artwork: _artistArtwork(artist, maxWidth: 100),
        circular: true,
        title: artist.name,
        subtitle: artist.songCount != null ? '${artist.songCount} songs' : 'Artist',
        onTap: () => _openArtist(context, artist),
      ),
    );
  }

  Widget _buildAlbumTile(ThemeData theme, JellyfinAlbum album) {
    return SizedBox(
      height: LibraryTileMetrics.of(context).listRowExtent,
      child: LibraryListRow(
        artwork: _albumArtwork(album, maxWidth: 100),
        title: album.name,
        subtitle: [
          album.displayArtist,
          if (album.productionYear != null) '${album.productionYear}',
        ].join(' · '),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)),
          );
        },
        onLongPress: () => _showAlbumActions(context, widget.appState, album),
      ),
    );
  }

  Widget _buildTrackTile(ThemeData theme, JellyfinTrack track) {
    return TrackSwipeActions(
      track: track,
      appState: widget.appState,
      child: _buildTrackRow(theme, track),
    );
  }

  Widget _buildTrackRow(ThemeData theme, JellyfinTrack track) {
    return SizedBox(
      height: LibraryTileMetrics.of(context).listRowExtent,
      child: LibraryListRow(
        artwork: _trackArtwork(track),
        title: track.name,
        subtitle: '${track.displayArtist}${track.album != null ? ' · ${track.album}' : ''}',
        trailing: track.duration != null
            ? Text(_formatDuration(track.duration!), style: theme.textTheme.footnote)
            : null,
        onTap: () {
          widget.appState.audioPlayerService.playTrack(
            track,
            queueContext: _trackResults,
          );
        },
        onLongPress: () => showTrackContextMenu(
          context: context,
          track: track,
          appState: widget.appState,
        ),
      ),
    );
  }
}
