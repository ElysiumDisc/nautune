import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../services/download_service.dart';
import '../theme/nautune_spacing.dart';
import '../utils/download_library.dart';
import '../utils/download_status.dart';
import '../widgets/download_indicators.dart';
import '../widgets/jellyfin_image.dart';
import 'album_detail_screen.dart';
import 'settings_screen.dart';

/// Everything downloaded, browsable without a connection (Library tab), plus
/// the download queue and quick-download shortcuts (Manage tab).
class OfflineLibraryScreen extends StatefulWidget {
  const OfflineLibraryScreen({super.key, this.initialTab = 0});

  /// 0 = Library, 1 = Manage.
  final int initialTab;

  @override
  State<OfflineLibraryScreen> createState() => _OfflineLibraryScreenState();
}

class _OfflineLibraryScreenState extends State<OfflineLibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    final service = appState.downloadService;

    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab.clamp(0, 1),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Downloads'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Download settings',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Library'),
              Tab(
                child: ListenableBuilder(
                  listenable: service,
                  builder: (context, _) {
                    final active = service.activeCount;
                    final failed = service.failedCount;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Manage'),
                        if (active + failed > 0) ...[
                          const SizedBox(width: NautuneSpacing.sm),
                          Badge(
                            label: Text('${active + failed}'),
                            backgroundColor: failed > 0
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            OfflineLibraryView(appState: appState),
            _ManageDownloadsTab(appState: appState),
          ],
        ),
      ),
    );
  }
}

enum _LibraryView { albums, artists }

/// Browsable offline library: totals, Shuffle all, search, albums/artists
/// with sort, per-album play/shuffle/remove. Used as the Library tab of
/// [OfflineLibraryScreen] and as the Downloads tab of the home screen when
/// offline.
class OfflineLibraryView extends StatefulWidget {
  const OfflineLibraryView({super.key, required this.appState, this.onManage});

  final NautuneAppState appState;

  /// Opens the download manager (from the empty state). Defaults to
  /// switching the enclosing [DefaultTabController] to its second tab.
  final VoidCallback? onManage;

  @override
  State<OfflineLibraryView> createState() => _OfflineLibraryViewState();
}

class _OfflineLibraryViewState extends State<OfflineLibraryView>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _searchController = TextEditingController();
  _LibraryView _view = _LibraryView.albums;
  OfflineLibrarySort _sort = OfflineLibrarySort.name;
  String _query = '';

  // Grouping is recomputed only when the download set, query, sort or view
  // changes — not on every progress tick of an active download.
  Object? _groupsKey;
  List<OfflineAlbumGroup> _albums = const [];
  List<OfflineArtistGroup> _artists = const [];

  DownloadService get _service => widget.appState.downloadService;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _regroupIfNeeded(List<DownloadItem> completed) {
    final key = (_service.revision, _query, _sort, _view);
    if (key == _groupsKey) return;
    _groupsKey = key;
    if (_view == _LibraryView.albums) {
      _albums = groupOfflineAlbums(completed, query: _query, sort: _sort);
    } else {
      _artists = groupOfflineArtists(completed, query: _query, sort: _sort);
    }
  }

  void _play(List<JellyfinTrack> tracks, {bool shuffle = false}) {
    if (tracks.isEmpty) return;
    final audio = widget.appState.audioPlayerService;
    if (shuffle) {
      audio.playShuffled(tracks);
    } else {
      audio.playTrack(tracks.first, queueContext: tracks);
    }
  }

  void _openAlbum(OfflineAlbumGroup album) {
    final first = album.items.first.track;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(
          album: JellyfinAlbum(
            id: album.albumId ?? first.id,
            name: album.name,
            artists: [album.artist],
            artistIds: first.artistIds,
            productionYear: album.year,
            primaryImageTag: album.imageTag,
          ),
        ),
      ),
    );
  }

  Future<void> _removeAlbum(OfflineAlbumGroup album) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove downloads?'),
        content: Text(
          'Remove ${album.items.length} downloaded tracks '
          '(${formatDownloadBytes(album.totalBytes)}) of “${album.name}” '
          'from this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.deleteDownloads(album.items.map((d) => d.track.id).toList());
  }

  void _showAlbumActions(OfflineAlbumGroup album) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('Play'),
              onTap: () {
                Navigator.pop(sheetContext);
                _play(album.tracks);
              },
            ),
            ListTile(
              leading: const Icon(Icons.shuffle),
              title: const Text('Shuffle'),
              onTap: () {
                Navigator.pop(sheetContext);
                _play(album.tracks, shuffle: true);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                'Remove download',
                style: TextStyle(color: Theme.of(sheetContext).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _removeAlbum(album);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final completed = _service.completedDownloads;
        if (completed.isEmpty) {
          return _EmptyOfflineLibrary(
            hasActiveDownloads: _service.activeCount > 0,
            onManage: widget.onManage ??
                () => DefaultTabController.maybeOf(context)?.animateTo(1),
          );
        }
        _regroupIfNeeded(completed);
        final totalBytes = _service.completedBytes;
        final allTracks = [for (final d in completed) d.track];
        final isAlbums = _view == _LibraryView.albums;
        final count = isAlbums ? _albums.length : _artists.length;

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  NautuneSpacing.lg,
                  NautuneSpacing.md,
                  NautuneSpacing.lg,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.offline_pin_outlined,
                            size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: NautuneSpacing.sm),
                        Expanded(
                          child: Text(
                            '${completed.length} tracks • '
                            '${formatDownloadBytes(totalBytes)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Play all',
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () => _play(allTracks),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _play(allTracks, shuffle: true),
                          icon: const Icon(Icons.shuffle, size: 18),
                          label: const Text('Shuffle all'),
                        ),
                      ],
                    ),
                    const SizedBox(height: NautuneSpacing.sm),
                    TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search downloads',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        isDense: true,
                        filled: true,
                        border: const OutlineInputBorder(
                          borderRadius: NautuneRadius.allMd,
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: NautuneSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: SegmentedButton<_LibraryView>(
                            segments: const [
                              ButtonSegment(
                                value: _LibraryView.albums,
                                label: Text('Albums'),
                                icon: Icon(Icons.album, size: 18),
                              ),
                              ButtonSegment(
                                value: _LibraryView.artists,
                                label: Text('Artists'),
                                icon: Icon(Icons.person, size: 18),
                              ),
                            ],
                            selected: {_view},
                            onSelectionChanged: (s) =>
                                setState(() => _view = s.first),
                          ),
                        ),
                        PopupMenuButton<OfflineLibrarySort>(
                          tooltip: 'Sort',
                          icon: const Icon(Icons.sort),
                          initialValue: _sort,
                          onSelected: (s) => setState(() => _sort = s),
                          itemBuilder: (context) => [
                            for (final s in OfflineLibrarySort.values)
                              if (isAlbums || s != OfflineLibrarySort.artist)
                                CheckedPopupMenuItem(
                                  value: s,
                                  checked: s == _sort,
                                  child: Text(s.label),
                                ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: NautuneSpacing.xs),
                  ],
                ),
              ),
            ),
            if (count == 0)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(NautuneSpacing.xl),
                    child: Text(
                      'No downloads match “$_query”',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              )
            else if (isAlbums)
              SliverList.builder(
                itemCount: _albums.length,
                itemBuilder: (context, index) =>
                    _buildAlbumTile(theme, _albums[index]),
              )
            else
              SliverList.builder(
                itemCount: _artists.length,
                itemBuilder: (context, index) =>
                    _buildArtistTile(theme, _artists[index]),
              ),
            const SliverToBoxAdapter(
              child: SizedBox(height: NautuneSpacing.xl),
            ),
          ],
        );
      },
    );
  }

  Widget _albumArt(ThemeData theme, OfflineAlbumGroup album, double size) {
    final placeholder = Container(
      width: size,
      height: size,
      color: theme.colorScheme.primaryContainer,
      child: Icon(Icons.album, color: theme.colorScheme.onPrimaryContainer),
    );
    final albumId = album.albumId;
    if (albumId == null) return placeholder;
    return ClipRRect(
      borderRadius: NautuneRadius.allSm,
      child: SizedBox.square(
        dimension: size,
        child: JellyfinImage(
          itemId: albumId,
          imageTag: album.imageTag ?? 'offline',
          albumId: albumId,
          maxWidth: 120,
          boxFit: BoxFit.cover,
          errorBuilder: (context, url, error) => placeholder,
        ),
      ),
    );
  }

  Widget _buildAlbumTile(ThemeData theme, OfflineAlbumGroup album) {
    final meta = [
      album.artist,
      if (album.year != null) '${album.year}',
      '${album.items.length} ${album.items.length == 1 ? 'track' : 'tracks'}',
      formatDownloadBytes(album.totalBytes),
    ].join(' • ');
    return ListTile(
      leading: _albumArt(theme, album, 48),
      title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        tooltip: 'Album actions',
        onPressed: () => _showAlbumActions(album),
      ),
      onTap: () => _openAlbum(album),
      onLongPress: () => _showAlbumActions(album),
    );
  }

  Widget _buildArtistTile(ThemeData theme, OfflineArtistGroup artist) {
    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(Icons.person, color: theme.colorScheme.onPrimaryContainer),
      ),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${artist.albums.length} ${artist.albums.length == 1 ? 'album' : 'albums'}'
        ' • ${artist.trackCount} tracks',
      ),
      childrenPadding: const EdgeInsets.only(left: NautuneSpacing.lg),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NautuneSpacing.lg),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => _play(artist.tracks),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Play'),
              ),
              TextButton.icon(
                onPressed: () => _play(artist.tracks, shuffle: true),
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
              ),
            ],
          ),
        ),
        for (final album in artist.albums) _buildAlbumTile(theme, album),
      ],
    );
  }
}

class _EmptyOfflineLibrary extends StatelessWidget {
  const _EmptyOfflineLibrary({
    required this.hasActiveDownloads,
    required this.onManage,
  });

  final bool hasActiveDownloads;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NautuneSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasActiveDownloads ? Icons.downloading : Icons.download_for_offline_outlined,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: NautuneSpacing.lg),
            Text(
              hasActiveDownloads ? 'Downloading…' : 'No downloads yet',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: NautuneSpacing.sm),
            Text(
              hasActiveDownloads
                  ? 'Your music will appear here as soon as the first '
                      'downloads finish.'
                  : 'Tap the download button on an album, playlist or artist, '
                      'or “Download” in a track’s menu. Downloaded music plays '
                      'without a connection.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: NautuneSpacing.lg),
            FilledButton.tonal(
              onPressed: onManage,
              child: Text(hasActiveDownloads ? 'See progress' : 'Quick downloads'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManageDownloadsTab extends StatelessWidget {
  const _ManageDownloadsTab({required this.appState});

  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = appState.downloadService;

    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final downloads = service.downloads;
        final active = service.activeDownloads;
        final failed = service.failedDownloads;
        final completed = service.completedDownloads;
        final pause = service.queuePause;
        // Downloading first, then queued (in queue order), failed, done.
        final activeSorted = [
          ...active.where((d) => d.isDownloading),
          ...active.where((d) => !d.isDownloading).toList().reversed,
        ];

        final sections = <_Section>[
          if (activeSorted.isNotEmpty)
            _Section(
              'In progress (${activeSorted.length})',
              activeSorted,
              action: TextButton(
                onPressed: () => _confirmCancelAll(context, service, activeSorted.length),
                child: const Text('Cancel all'),
              ),
            ),
          if (failed.isNotEmpty) _Section('Failed (${failed.length})', failed),
          if (completed.isNotEmpty)
            _Section(
              'Downloaded (${completed.length} • '
              '${formatDownloadBytes(service.completedBytes)})',
              completed,
              action: TextButton(
                onPressed: () => _confirmClearAll(context, service, completed.length),
                child: const Text('Remove all'),
              ),
            ),
        ];
        final rows = <Object>[
          for (final section in sections) ...[section, ...section.items],
        ];

        return Column(
          children: [
            const DownloadQueueBanner(),
            _QuickDownloads(appState: appState),
            Expanded(
              child: downloads.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(NautuneSpacing.xxl),
                        child: Text(
                          'Nothing downloaded yet. Use Quick downloads above, '
                          'or the download button on any album or playlist.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        if (row is _Section) {
                          return _SectionHeader(section: row);
                        }
                        final item = row as DownloadItem;
                        return DownloadItemTile(
                          key: ValueKey(item.track.id),
                          item: item,
                          queuePause: pause,
                          onPlay: () => appState.audioPlayerService.playTrack(
                            item.track,
                            queueContext: [item.track],
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

  Future<void> _confirmCancelAll(
    BuildContext context,
    DownloadService service,
    int count,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel all downloads?'),
        content: Text('Stop and remove $count queued downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep downloading'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel all'),
          ),
        ],
      ),
    );
    if (ok == true) await service.cancelAllActive();
  }

  Future<void> _confirmClearAll(
    BuildContext context,
    DownloadService service,
    int count,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove all downloads?'),
        content: Text(
          'This deletes all $count downloaded tracks from this device. '
          'You will need a connection to play them again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (ok == true) await service.clearAllDownloads();
  }
}

class _Section {
  _Section(this.title, this.items, {this.action});

  final String title;
  final List<DownloadItem> items;
  final Widget? action;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section});

  final _Section section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NautuneSpacing.lg,
        NautuneSpacing.md,
        NautuneSpacing.sm,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              section.title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ?section.action,
        ],
      ),
    );
  }
}

class _QuickDownloads extends StatelessWidget {
  const _QuickDownloads({required this.appState});

  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        NautuneSpacing.lg,
        NautuneSpacing.md,
        NautuneSpacing.lg,
        NautuneSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick downloads',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: NautuneSpacing.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ActionChip(
                  avatar: const Icon(Icons.favorite, size: 16),
                  label: const Text('Favorites'),
                  onPressed: () => _run(
                    context,
                    'favorites',
                    () => appState.jellyfinService.getFavoriteTracks(),
                    ownerId: 'favorites',
                  ),
                ),
                const SizedBox(width: NautuneSpacing.sm),
                ActionChip(
                  avatar: const Icon(Icons.trending_up, size: 16),
                  label: const Text('Top 20'),
                  onPressed: () => _run(context, 'most played tracks', () {
                    final libraryId = appState.session?.selectedLibraryId;
                    if (libraryId == null) return Future.value(const []);
                    return appState.jellyfinService.getMostPlayedTracks(
                      libraryId: libraryId,
                      limit: 20,
                    );
                  }),
                ),
                const SizedBox(width: NautuneSpacing.sm),
                ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: const Text('Recent 20'),
                  onPressed: () => _run(context, 'recent tracks', () {
                    final libraryId = appState.session?.selectedLibraryId;
                    if (libraryId == null) return Future.value(const []);
                    return appState.jellyfinService.loadRecentTracks(
                      libraryId: libraryId,
                      limit: 20,
                      forceRefresh: true,
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _run(
    BuildContext context,
    String label,
    Future<List<JellyfinTrack>> Function() load, {
    String? ownerId,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (appState.isOfflineMode) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('You are offline. Connect to the internet to download.'),
        ),
      );
      return;
    }
    try {
      final tracks = await load();
      if (tracks.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text('No $label found')));
        return;
      }
      final queued = await appState.downloadService
          .downloadTracks(tracks, ownerId: ownerId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            queued > 0
                ? 'Queued $queued $label'
                : 'All $label are already downloaded',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn’t load $label. Check your connection.')),
      );
    }
  }
}
