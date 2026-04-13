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
  bool _showRelaxEasterEgg = false;
  bool _showNetworkEasterEgg = false;
  bool _showEssentialEasterEgg = false;
  bool _showFireEasterEgg = false;
  bool _showPianoEasterEgg = false;
  bool _showHealingEasterEgg = false;
  List<JellyfinAlbum> _albumResults = const [];
  List<JellyfinArtist> _artistResults = const [];
  List<JellyfinTrack> _trackResults = const [];
  Object? _error;
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
        _showRelaxEasterEgg = false;
        _showNetworkEasterEgg = false;
        _showEssentialEasterEgg = false;
        _showFireEasterEgg = false;
        _showPianoEasterEgg = false;
        _showHealingEasterEgg = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      // Easter eggs: show special cards when searching certain keywords
      _showRelaxEasterEgg = lowerQuery.contains('relax');
      _showNetworkEasterEgg = lowerQuery.contains('network');
      _showEssentialEasterEgg = lowerQuery.contains('essential');
      _showFireEasterEgg = lowerQuery.contains('fire') || lowerQuery.contains('frets');
      _showPianoEasterEgg = lowerQuery.contains('piano');
      _showHealingEasterEgg = lowerQuery.contains('solfeggio') ||
          lowerQuery.contains('healing') ||
          lowerQuery.contains('frequency') ||
          lowerQuery.contains('frequencies') ||
          lowerQuery.contains('hz');
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _controller,
            onChanged: (value) {
              _debouncer.run(() => _performSearch(value));
            },
            onSubmitted: (value) {
              _debouncer.cancel();
              _performSearch(value);
            },
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search albums, artists, tracks...',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => _performSearch(_controller.text),
              ),
            ),
          ),
        ),
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
                      _showRelaxEasterEgg ||
                      _showNetworkEasterEgg ||
                      _showEssentialEasterEgg ||
                      _showFireEasterEgg ||
                      _showPianoEasterEgg ||
                      _showHealingEasterEgg;

    if (!hasResults) {
      return Center(
        child: Text(
          'No results found for "$_lastQuery"',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        // Easter egg: Relax Mode card
        if (_showRelaxEasterEgg)
          _buildRelaxModeCard(theme),
        // Easter egg: Network radio card
        if (_showNetworkEasterEgg)
          _buildNetworkModeCard(theme),
        // Easter egg: Essential Mix card
        if (_showEssentialEasterEgg)
          _buildEssentialMixCard(theme),
        // Easter egg: Frets on Fire card
        if (_showFireEasterEgg)
          _buildFretsOnFireCard(theme),
        // Easter egg: Piano card
        if (_showPianoEasterEgg)
          _buildPianoCard(theme),
        // Easter egg: Healing Frequencies card
        if (_showHealingEasterEgg)
          _buildHealingFrequenciesCard(theme),
        // Artists section
        if (_artistResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Artists', Icons.person, _artistResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _artistResults.length,
            (index) => _buildArtistTile(theme, _artistResults[index]),
          ),
          const SizedBox(height: 16),
        ],
        // Albums section
        if (_albumResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Albums', Icons.album, _albumResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _albumResults.length,
            (index) => _buildAlbumTile(theme, _albumResults[index]),
          ),
          const SizedBox(height: 16),
        ],
        // Tracks section
        if (_trackResults.isNotEmpty) ...[
          _buildSectionHeader(theme, 'Tracks', Icons.music_note, _trackResults.length),
          const SizedBox(height: 8),
          ...List.generate(
            _trackResults.length,
            (index) => _buildTrackTile(theme, _trackResults[index]),
          ),
        ],
      ],
    );
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

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon, int count) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '$count',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistTile(ThemeData theme, JellyfinArtist artist) {
    return Card(
      child: ListTile(
        leading: artist.primaryImageTag != null
            ? ClipOval(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: JellyfinImage(
                    itemId: artist.id,
                    imageTag: artist.primaryImageTag!,
                    artistId: artist.id, // Enable offline artist image support
                    maxWidth: 100,
                    boxFit: BoxFit.cover,
                    errorBuilder: (context, url, error) =>
                        const CircleAvatar(child: Icon(Icons.person_outline)),
                  ),
                ),
              )
            : const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(
          artist.name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: const Color(0xFF8CB1D9),
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: artist.songCount != null
            ? Text('${artist.songCount} songs')
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtistDetailScreen(artist: artist),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAlbumTile(ThemeData theme, JellyfinAlbum album) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.album_outlined),
        title: Text(album.name),
        subtitle: Text(album.displayArtist),
        trailing: album.productionYear != null
            ? Text('${album.productionYear}')
            : null,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AlbumDetailScreen(album: album),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrackTile(ThemeData theme, JellyfinTrack track) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.music_note,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          track.name,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.tertiary,
          ),
        ),
        subtitle: Text(
          '${track.displayArtist}${track.album != null ? ' • ${track.album}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: track.duration != null
            ? Text(
                _formatDuration(track.duration!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        onTap: () {
          widget.appState.audioPlayerService.playTrack(
            track,
            queueContext: _trackResults,
          );
        },
      ),
    );
  }
}
