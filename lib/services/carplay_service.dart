import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_carplay/flutter_carplay.dart';
import 'package:flutter_carplay/controllers/carplay_controller.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

/// CarPlay UI for Nautune, built on flutter_carplay 1.3.3.
///
/// Plugin semantics this class relies on (verified against the 1.3.3 source):
/// * `FlutterCarplay.setRootTemplate` only *stores* the root natively. It is
///   shown when the CarPlay scene connects, or immediately via
///   `forceUpdateRootTemplate`. Re-setting the root while connected without
///   forcing leaves the old root on screen while Dart and native track the new
///   one, so taps on the visible rows are never delivered (dead rows).
/// * Connection events are only delivered once Dart listens. On a cold start
///   from CarPlay the scene connects before Dart runs, so the initial
///   "connected" event is usually lost. Nothing here may depend on having
///   seen it; `push` is a safe no-op (returns false) when not connected.
/// * The plugin also reports `connected` from `sceneDidBecomeActive`, i.e.
///   every time the CarPlay app returns to the foreground. Those events must
///   not rebuild the root (that would reset the selected tab / nav stack).
/// * List taps are resolved by element id against
///   `FlutterCarPlayController.templateHistory`; a template missing from it
///   has dead rows.
class CarPlayService {
  final NautuneAppState appState;
  final FlutterCarplay _carplay = FlutterCarplay();
  bool _isInitialized = false;

  /// Best-effort: true after a connected event or any CarPlay interaction,
  /// false after a disconnected event. See the class doc for why this is not
  /// used to gate navigation.
  bool _isConnected = false;

  /// Set when CarPlay disconnects; the next connect rebuilds the root.
  bool _rebuildRootOnConnect = false;

  Timer? _updateThrottleTimer;
  String? _currentPlayingTrackId;
  StreamSubscription<JellyfinTrack?>? _currentTrackSub;

  /// Track id of each track row, so the Now Playing indicator can move to
  /// the right row when the current track changes.
  final Expando<String> _trackRowIds = Expando<String>('carplayTrackRow');

  /// Root rows whose detail text reflects app state. Updated in place so the
  /// selected tab and any pushed templates are preserved.
  CPListItem? _albumsRow;
  CPListItem? _artistsRow;
  CPListItem? _playlistsRow;
  CPListItem? _albumsAzRow;
  CPListItem? _artistsAzRow;
  CPListItem? _recentRow;
  CPListItem? _favoritesRow;
  CPListItem? _downloadsRow;
  bool _rootTemplateSet = false;
  Future<void>? _rootSetupInFlight;
  DateTime _lastRootSetupAttempt = DateTime(2000);

  /// Identity of the signed-in library. When it changes (login, logout,
  /// account/library switch) pushed pages are stale and are popped.
  String? _sessionKey;
  bool _sessionKeyHadSession = false;

  _NameIndex<JellyfinAlbum>? _albumIndex;
  _NameIndex<JellyfinArtist>? _artistIndex;

  /// Upper bound per list page. The real budget also honours
  /// `CPListTemplate.maximumItemCount` (see [_pageSize]).
  static const int _maxItemsPerPage = 100;

  /// CarPlay audio apps may have at most 5 templates in a navigation
  /// hierarchy (root included). Pushing past it raises an exception in
  /// CarPlay, so pushes beyond this replace the top page instead.
  static const int _maxTemplateDepth = 5;

  /// Bound on any single network wait so a dead server shows an error page
  /// instead of leaving the driver with no feedback.
  static const Duration _fetchTimeout = Duration(seconds: 20);

  /// Longest time a tapped row keeps CarPlay's loading spinner.
  static const Duration _spinnerCap = Duration(seconds: 10);

  /// A–Z index: fetched in chunks, capped, cached briefly.
  static const int _indexChunk = 500;
  static const int _indexMaxItems = 10000;
  static const Duration _indexTtl = Duration(minutes: 10);
  static const Duration _indexTimeout = Duration(seconds: 45);

  /// Root layout. Defaults to a single root list with sections (one
  /// navigation stack). A tab bar root is supported but off: CarPlay keeps a
  /// separate stack per tab, while flutter_carplay 1.3.3 drops a tab's pushed
  /// pages from its history when you switch away (`templateDidDisappear`
  /// compares against the *selected* tab's stack), leaving their rows dead
  /// when you switch back. Only enable after verifying on a device.
  static const bool _useTabBarRoot = false;

  CarPlayService({required this.appState});

  bool get isConnected => _isConnected;

  /// Call this after the app is fully loaded
  Future<void> initialize() async {
    if (_isInitialized || !Platform.isIOS) return;
    _isInitialized = true;

    try {
      _sessionKey = _computeSessionKey();
      _sessionKeyHadSession = appState.session != null;
      _setupListeners();
      await _setupRootTemplate();
    } catch (e) {
      debugPrint('⚠️ CarPlay initialization failed (non-critical): $e');
    }
  }

  void _setupListeners() {
    _carplay.addListenerOnConnectionChange((ConnectionStatusTypes status) {
      switch (status) {
        case ConnectionStatusTypes.connected:
          _onCarPlayConnect();
          break;
        case ConnectionStatusTypes.disconnected:
          _onCarPlayDisconnect();
          break;
        case ConnectionStatusTypes.background:
          debugPrint('🚗 CarPlay in background');
          break;
        case ConnectionStatusTypes.unknown:
          debugPrint('🚗 CarPlay status unknown');
          break;
      }
    });

    appState.addListener(_onAppStateChanged);
    // Download completions don't notify NautuneAppState; listen directly so
    // the Downloads row count stays current.
    appState.downloadService.addListener(_onAppStateChanged);

    _currentTrackSub =
        appState.audioPlayerService.currentTrackStream.listen((track) {
      final previous = _currentPlayingTrackId;
      _currentPlayingTrackId = track?.id;
      if (previous != _currentPlayingTrackId) _syncPlayingIndicators();
    });
    _currentPlayingTrackId = appState.audioPlayerService.currentTrack?.id;
  }

  void _onCarPlayConnect() {
    _isConnected = true;
    debugPrint('🚗 CarPlay connected');
    if (!_rootTemplateSet || _rebuildRootOnConnect) {
      // First connection with no root yet, or a genuine reconnect: nothing
      // on screen to preserve, so (re)build and show the root.
      _rebuildRootOnConnect = false;
      unawaited(_setupRootTemplate());
    } else {
      // Also fired by sceneDidBecomeActive: keep tab + stack, refresh rows.
      _updateRootRowsInPlace();
    }
  }

  void _onCarPlayDisconnect() {
    _isConnected = false;
    _rebuildRootOnConnect = true;
    _updateThrottleTimer?.cancel();
    _updateThrottleTimer = null;
    // The next session starts at the root; drop pushed pages from Dart's
    // history so depth checks and item lookups don't see stale templates.
    _trimHistoryToRoot();
    debugPrint('🚗 CarPlay disconnected');
  }

  void _noteInteraction() {
    // A delivered tap proves CarPlay is connected even if the connected
    // event was lost on a cold start.
    _isConnected = true;
  }

  // ============ Root template ============

  Future<void> _setupRootTemplate() {
    return _rootSetupInFlight ??=
        _doSetupRootTemplate().whenComplete(() => _rootSetupInFlight = null);
  }

  Future<void> _doSetupRootTemplate() async {
    _lastRootSetupAttempt = DateTime.now();
    try {
      final rootTemplate = _buildRootTemplate();
      await FlutterCarplay.setRootTemplate(
        rootTemplate: rootTemplate,
        animated: false,
      );
      final history = FlutterCarPlayController.templateHistory;
      if (history.isEmpty || !identical(history.first, rootTemplate)) {
        debugPrint('⚠️ CarPlay root template was not accepted');
        return;
      }
      _trimHistoryToRoot();
      // setRootTemplate only stores the root; this puts it on screen if a
      // CarPlay scene is connected (no-op otherwise — it is shown on connect).
      await _carplay.forceUpdateRootTemplate();
      _rootTemplateSet = true;
      debugPrint('✅ CarPlay root template set');
    } catch (e) {
      debugPrint('⚠️ CarPlay root template setup failed: $e');
    }
  }

  void _trimHistoryToRoot() {
    final history = FlutterCarPlayController.templateHistory;
    if (history.length > 1) history.removeRange(1, history.length);
  }

  CPTemplate _buildRootTemplate() {
    final libraryRows = <CPListTemplateItem>[
      _albumsRow = CPListItem(
        text: 'Albums',
        detailText: _albumsDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showAlbums(origin: origin)),
      ),
      _artistsRow = CPListItem(
        text: 'Artists',
        detailText: _artistsDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showArtists(origin: origin)),
      ),
      _playlistsRow = CPListItem(
        text: 'Playlists',
        detailText: _playlistsDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showPlaylists(origin: origin)),
      ),
      // Stand-in for CPSearchTemplate (not exposed by flutter_carplay).
      // Two root rows rather than an intermediate menu keeps the deepest
      // path (letter → bucket → artist → album → Now Playing) within the
      // CarPlay template depth limit.
      _albumsAzRow = CPListItem(
        text: 'Albums A–Z',
        detailText: _azDetail('Albums'),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap(
            (origin) => _showAlphabeticalLetters(forArtists: false, origin: origin)),
      ),
      _artistsAzRow = CPListItem(
        text: 'Artists A–Z',
        detailText: _azDetail('Artists'),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap(
            (origin) => _showAlphabeticalLetters(forArtists: true, origin: origin)),
      ),
    ];

    final recentRows = <CPListTemplateItem>[
      _recentRow = CPListItem(
        text: 'Recently Played',
        detailText: _recentDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showRecentlyPlayed(origin: origin)),
      ),
      _favoritesRow = CPListItem(
        text: 'Favorite Tracks',
        detailText: _favoritesDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showFavorites(origin: origin)),
      ),
    ];

    final downloadRows = <CPListTemplateItem>[
      _downloadsRow = CPListItem(
        text: 'Downloaded Music',
        detailText: _downloadsDetail(),
        accessoryType: CPListItemAccessoryType.disclosureIndicator,
        onPress: _tap((origin) => _showDownloads(origin: origin)),
      ),
    ];

    if (!_useTabBarRoot) {
      return CPListTemplate(
        title: 'Nautune',
        sections: [
          CPListSection(header: 'Library', items: libraryRows),
          CPListSection(header: 'Listening', items: recentRows),
          CPListSection(header: 'Offline', items: downloadRows),
        ],
        systemIcon: 'music.note.house',
      );
    }

    return CPTabBarTemplate(
      templates: [
        CPListTemplate(
          title: 'Library',
          tabTitle: 'Library',
          sections: [CPListSection(items: libraryRows)],
          systemIcon: 'music.note.house',
        ),
        CPListTemplate(
          title: 'Recent',
          tabTitle: 'Recent',
          sections: [CPListSection(items: recentRows)],
          systemIcon: 'clock.fill',
        ),
        CPListTemplate(
          title: 'Downloads',
          tabTitle: 'Downloads',
          sections: [CPListSection(items: downloadRows)],
          systemIcon: 'arrow.down.circle.fill',
        ),
      ],
    );
  }

  void _onAppStateChanged() {
    if (!_isInitialized) return;
    // Throttle (not debounce): download progress and playback notify many
    // times a second, and a resetting debounce would never fire.
    _updateThrottleTimer ??= Timer(const Duration(milliseconds: 500), () {
      _updateThrottleTimer = null;
      _handleSessionChange();
      if (_rootTemplateSet) {
        _updateRootRowsInPlace();
      } else if (DateTime.now().difference(_lastRootSetupAttempt) >
          const Duration(seconds: 5)) {
        // Initial setup failed earlier; retry (rate-limited) now that state
        // has moved.
        unawaited(_setupRootTemplate());
      }
    });
  }

  String _computeSessionKey() {
    final s = appState.session;
    return [
      s?.serverUrl,
      s?.credentials.userId,
      s?.selectedLibraryId,
      appState.isDemoMode,
    ].join('|');
  }

  void _handleSessionChange() {
    final key = _computeSessionKey();
    if (key == _sessionKey) return;
    final hadSession = _sessionKeyHadSession;
    _sessionKey = key;
    _sessionKeyHadSession = appState.session != null;
    _albumIndex = null;
    _artistIndex = null;
    // Pages built for the previous account/library are stale after logout or
    // an account/library switch. A session merely *arriving* (sign-in, or the
    // keychain unlocking after a locked cold start) leaves the stack alone so
    // e.g. Downloads/Now Playing opened meanwhile aren't yanked away.
    if (hadSession && FlutterCarPlayController.templateHistory.length > 1) {
      unawaited(FlutterCarplay.popToRoot(animated: false).catchError((Object e) {
        debugPrint('⚠️ CarPlay popToRoot failed: $e');
        return false;
      }));
    }
  }

  /// Push fresh detail texts into the existing root rows (no-op for rows
  /// whose text is unchanged, to avoid needless platform-channel traffic).
  void _updateRootRowsInPlace() {
    void update(CPListItem? row, String detail) {
      if (row == null || row.detailText == detail) return;
      try {
        row.setDetailText(detail);
      } catch (e) {
        debugPrint('⚠️ CarPlay row update failed: $e');
      }
    }

    update(_albumsRow, _albumsDetail());
    update(_artistsRow, _artistsDetail());
    update(_playlistsRow, _playlistsDetail());
    update(_albumsAzRow, _azDetail('Albums'));
    update(_artistsAzRow, _azDetail('Artists'));
    update(_recentRow, _recentDetail());
    update(_favoritesRow, _favoritesDetail());
    update(_downloadsRow, _downloadsDetail());
  }

  // ============ Row detail texts ============

  /// Non-null when the online library can't be browsed right now: no session
  /// yet (still starting, keychain locked on a cold start from CarPlay, or
  /// signed out). Offline mode and demo mode browse local data.
  String? _libraryUnavailableReason() {
    if (appState.isDemoMode || appState.isOfflineMode) return null;
    if (appState.session != null && appState.selectedLibraryId != null) {
      return null;
    }
    if (!appState.isInitialized) return 'Loading…';
    if (appState.session != null) return 'Choose a library on your iPhone';
    return 'Unlock your iPhone or sign in to Nautune';
  }

  String _albumsDetail() {
    final reason = _libraryUnavailableReason();
    if (reason != null) return reason;
    if (appState.isLoadingAlbums) return 'Loading…';
    return 'Browse all albums';
  }

  String _artistsDetail() {
    final reason = _libraryUnavailableReason();
    if (reason != null) return reason;
    if (appState.isLoadingArtists) return 'Loading…';
    return 'Browse all artists';
  }

  String _azDetail(String what) =>
      _libraryUnavailableReason() ?? '$what by first letter';

  String _playlistsDetail() {
    final reason = _libraryUnavailableReason();
    if (reason != null) return reason;
    if (appState.isLoadingPlaylists) return 'Loading…';
    final count = appState.playlists?.length ?? 0;
    return count > 0 ? '$count playlists' : 'Your playlists';
  }

  String _recentDetail() {
    if (appState.isOfflineMode) return 'Not available offline';
    return _libraryUnavailableReason() ?? 'Your listening history';
  }

  String _favoritesDetail() {
    final reason = _libraryUnavailableReason();
    if (reason != null) return reason;
    if (appState.isLoadingFavorites) return 'Loading…';
    final count = appState.favoriteTracks?.length ?? 0;
    return count > 0 ? '$count songs' : 'Your hearted songs';
  }

  String _downloadsDetail() {
    final count = appState.downloadService.completedDownloads.length;
    return count > 0 ? '$count songs available offline' : 'Available offline';
  }

  // ============ Navigation helpers ============

  /// Wraps a row action. The spinner stays on the tapped row until the
  /// action finishes (content loaded and pushed) or [_spinnerCap] elapses.
  /// [origin] is the page the tap came from; actions only push if it is
  /// still on top afterwards (the driver didn't go back or tap elsewhere).
  Function(Function() complete, CPListItem self) _tap(
    Future<void> Function(CPTemplate? origin) action, {
    bool completeImmediately = false,
  }) {
    return (complete, self) async {
      _noteInteraction();
      final origin = _topTemplate();
      var completed = false;
      void finish() {
        if (completed) return;
        completed = true;
        try {
          final result = complete();
          if (result is Future) {
            unawaited(result.then<void>((_) {}, onError: (Object _) {}));
          }
        } catch (_) {}
      }

      if (completeImmediately) finish();
      final cap = Timer(_spinnerCap, finish);
      try {
        await action(origin);
      } catch (e) {
        debugPrint('⚠️ CarPlay action failed: $e');
      } finally {
        cap.cancel();
        finish();
      }
    };
  }

  CPTemplate? _topTemplate() {
    final history = FlutterCarPlayController.templateHistory;
    return history.isEmpty ? null : history.last;
  }

  bool _stillAt(CPTemplate? origin) {
    if (origin == null) return true;
    return identical(_topTemplate(), origin);
  }

  /// Push [template], keeping the stack within [_maxTemplateDepth].
  /// With [replaceTop] (Load More) the current page is swapped out.
  Future<bool> _push(CPListTemplate template, {bool replaceTop = false}) async {
    final depth = FlutterCarPlayController.templateHistory.length;
    if ((replaceTop && depth > 1) || depth >= _maxTemplateDepth) {
      await FlutterCarplay.pop(animated: false);
    }
    return FlutterCarplay.push(template: template, animated: !replaceTop);
  }

  Future<void> _showNowPlaying() async {
    // Now Playing is itself a pushed template; skip it at the depth limit
    // (CarPlay's own "Now Playing" button still reaches it).
    if (FlutterCarPlayController.templateHistory.length >= _maxTemplateDepth) {
      return;
    }
    try {
      await FlutterCarplay.showSharedNowPlaying(animated: true);
    } catch (e) {
      debugPrint('⚠️ CarPlay showSharedNowPlaying failed: $e');
    }
  }

  /// Items per page, leaving [reserved] slots (Load More / Shuffle) within
  /// the vehicle's `CPListTemplate.maximumItemCount`, so those rows are
  /// never truncated away.
  Future<int> _pageSize({int reserved = 1}) async {
    int? max;
    try {
      max = await CPListTemplate.getMaximumItemCount();
    } catch (_) {}
    if (max == null || max <= reserved) return _maxItemsPerPage;
    return math.max(1, math.min(_maxItemsPerPage, max - reserved));
  }

  /// Shows a titled page with CarPlay's native empty-state text.
  Future<void> _showMessage(
    String title,
    String message, {
    String? detail,
    CPTemplate? origin,
    bool replaceTop = false,
  }) async {
    if (!_stillAt(origin)) return;
    try {
      await _push(
        CPListTemplate(
          title: title,
          sections: <CPListSection>[],
          emptyViewTitleVariants: [message],
          emptyViewSubtitleVariants: [detail ?? _defaultMessageDetail()],
          systemIcon: 'exclamationmark.circle',
        ),
        replaceTop: replaceTop,
      );
    } catch (e) {
      debugPrint('⚠️ CarPlay push message failed: $e');
    }
  }

  String _defaultMessageDetail() => appState.isOfflineMode
      ? 'You are offline. Downloaded music is available.'
      : 'Check your connection and try again.';

  Future<void> _showLoadError(String title, Object error, CPTemplate? origin) {
    debugPrint('⚠️ CarPlay load "$title" failed: $error');
    return _showMessage(
      title,
      'Couldn’t load $title',
      detail: appState.isOfflineMode
          ? 'You are offline. Downloaded music is available.'
          : 'Couldn’t reach your Jellyfin server.',
      origin: origin,
    );
  }

  Future<void> _showPlaybackError(
      JellyfinTrack? track, Object error, CPTemplate? origin) {
    debugPrint('⚠️ CarPlay playback failed: $error');
    return _showMessage(
      'Playback',
      track == null ? 'Couldn’t start playback' : 'Couldn’t play “${track.name}”',
      detail: appState.isOfflineMode
          ? 'You are offline and this song isn’t downloaded.'
          : 'Check your connection and try again.',
      origin: origin,
    );
  }

  /// Returns true (after showing a message) when the online library can't
  /// be browsed right now.
  Future<bool> _blockedByNoLibrary(String title, CPTemplate? origin) async {
    final reason = _libraryUnavailableReason();
    if (reason == null) return false;
    await _showMessage(
      title,
      reason == 'Loading…' ? 'Nautune is starting…' : reason,
      detail: 'Your library appears here once Nautune is signed in.',
      origin: origin,
    );
    return true;
  }

  Future<bool> _waitFor(bool Function() condition,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (!condition() && DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return condition();
  }

  // ============ Data sources ============

  Future<List<JellyfinAlbum>> _fetchAlbumPage(int start, int limit) async {
    if (appState.isDemoMode) {
      return (appState.albums ?? const <JellyfinAlbum>[])
          .skip(start)
          .take(limit)
          .toList();
    }
    final libraryId = appState.isOfflineMode
        ? 'offline_downloads'
        : appState.selectedLibraryId;
    if (libraryId == null) return const [];
    return appState.repository
        .getAlbums(libraryId: libraryId, startIndex: start, limit: limit)
        .timeout(_fetchTimeout);
  }

  Future<List<JellyfinArtist>> _fetchArtistPage(int start, int limit) async {
    if (appState.isDemoMode) {
      return (appState.artists ?? const <JellyfinArtist>[])
          .skip(start)
          .take(limit)
          .toList();
    }
    final libraryId = appState.isOfflineMode
        ? 'offline_downloads'
        : appState.selectedLibraryId;
    if (libraryId == null) return const [];
    return appState.repository
        .getArtists(libraryId: libraryId, startIndex: start, limit: limit)
        .timeout(_fetchTimeout);
  }

  Future<List<T>> _fetchAll<T>(
      Future<List<T>> Function(int start, int limit) fetchPage) async {
    final all = <T>[];
    while (all.length < _indexMaxItems) {
      final page = await fetchPage(all.length, _indexChunk);
      all.addAll(page);
      if (page.length < _indexChunk) break;
    }
    return all;
  }

  String get _indexKey => '$_sessionKey|${appState.isOfflineMode}';

  Future<List<JellyfinAlbum>> _albumNameIndex() async {
    final cached = _albumIndex;
    if (cached != null && cached.isValidFor(_indexKey, _indexTtl)) {
      return cached.items;
    }
    final key = _indexKey;
    final items = await _fetchAll(_fetchAlbumPage).timeout(_indexTimeout);
    _albumIndex = _NameIndex(key, items);
    return items;
  }

  Future<List<JellyfinArtist>> _artistNameIndex() async {
    final cached = _artistIndex;
    if (cached != null && cached.isValidFor(_indexKey, _indexTtl)) {
      return cached.items;
    }
    final key = _indexKey;
    final items = await _fetchAll(_fetchArtistPage).timeout(_indexTimeout);
    _artistIndex = _NameIndex(key, items);
    return items;
  }

  String? _albumImage(JellyfinAlbum album) {
    if (appState.isOfflineMode) return null; // local art resolved separately
    return appState.jellyfinService.buildSelfContainedImageUrl(
      itemId: album.id,
      tag: album.primaryImageTag,
      maxWidth: 200,
    );
  }

  String? _artistImage(JellyfinArtist artist) {
    if (appState.isOfflineMode) return null;
    return appState.jellyfinService.buildSelfContainedImageUrl(
      itemId: artist.id,
      tag: artist.primaryImageTag,
      maxWidth: 200,
    );
  }

  /// `file://` artwork for downloaded tracks, keyed by track id. The plugin
  /// strips `file://` and loads the raw path (spaces are fine).
  Future<Map<String, String>> _localTrackArt(Iterable<JellyfinTrack> tracks) async {
    final result = <String, String>{};
    for (final track in tracks) {
      try {
        final path =
            await appState.downloadService.getArtworkPathForTrack(track.id);
        if (path != null && File(path).existsSync()) {
          result[track.id] = 'file://$path';
        }
      } catch (_) {
        // best-effort; fall back to network URL
      }
    }
    return result;
  }

  /// `file://` artwork for downloaded albums (offline mode), keyed by album id.
  Future<Map<String, String>> _localAlbumArt(Iterable<JellyfinAlbum> albums) async {
    final trackForAlbum = <String, JellyfinTrack>{};
    for (final d in appState.downloadService.completedDownloads) {
      final albumId = d.track.albumId;
      if (albumId != null) trackForAlbum.putIfAbsent(albumId, () => d.track);
    }
    final tracks = <JellyfinTrack>[];
    final albumOfTrack = <String, String>{};
    for (final album in albums) {
      final track = trackForAlbum[album.id];
      if (track == null) continue;
      tracks.add(track);
      albumOfTrack[track.id] = album.id;
    }
    final byTrack = await _localTrackArt(tracks);
    return {
      for (final e in byTrack.entries)
        if (albumOfTrack[e.key] != null) albumOfTrack[e.key]!: e.value,
    };
  }

  // ============ Row builders ============

  CPListItem _albumRow(JellyfinAlbum album, {String? imageOverride}) {
    return CPListItem(
      text: album.name,
      detailText: album.artists.join(', '),
      image: imageOverride ?? _albumImage(album),
      accessoryType: CPListItemAccessoryType.disclosureIndicator,
      onPress: _tap((origin) => _showAlbumTracks(album.id, album.name, origin: origin)),
    );
  }

  CPListItem _artistRow(JellyfinArtist artist) {
    return CPListItem(
      text: artist.name,
      image: _artistImage(artist),
      accessoryType: CPListItemAccessoryType.disclosureIndicator,
      onPress: _tap(
          (origin) => _showArtistAlbums(artist.id, artist.name, origin: origin)),
    );
  }

  CPListItem _loadMoreRow(String detail, Future<void> Function(CPTemplate? origin) next) {
    return CPListItem(
      text: 'Load More…',
      detailText: detail,
      // Complete first: this page is replaced by the next one.
      onPress: _tap(next, completeImmediately: true),
    );
  }

  /// A track row. [queueIndex] is the row's position in [queue], passed to
  /// playTrack so duplicate tracks (same id twice in a playlist) start at
  /// the tapped slot.
  CPListItem _trackRow(
    JellyfinTrack track,
    List<JellyfinTrack> queue,
    int queueIndex,
    String detailText, {
    String? imageOverride,
  }) {
    final isCurrent = track.id == _currentPlayingTrackId;
    final item = CPListItem(
      text: track.name,
      detailText: detailText,
      // Offline, only local artwork: a network URL would just fail (and
      // carries the access token).
      image: imageOverride ??
          (appState.isOfflineMode ? null : track.artworkUrl(maxWidth: 200)),
      isPlaying: isCurrent ? true : null,
      playingIndicatorLocation:
          isCurrent ? CPListItemPlayingIndicatorLocation.trailing : null,
      onPress: _tap((origin) async {
        try {
          await appState.audioPlayerService.playTrack(
            track,
            queueContext: queue,
            queueIndex: queueIndex,
            reorderQueue: false,
          );
        } catch (e) {
          await _showPlaybackError(track, e, origin);
          return;
        }
        if (_stillAt(origin)) await _showNowPlaying();
      }),
    );
    _trackRowIds[item] = track.id;
    return item;
  }

  /// Move the Now Playing indicator to the current track's rows on the
  /// pages still in the navigation history.
  void _syncPlayingIndicators() {
    final current = _currentPlayingTrackId;
    for (final template in List.of(FlutterCarPlayController.templateHistory)) {
      if (template is! CPListTemplate) continue;
      for (final section in template.sections) {
        for (final item in List.of(section.items)) {
          if (item is! CPListItem) continue;
          final id = _trackRowIds[item];
          if (id == null) continue;
          final playing = id == current;
          if ((item.isPlaying ?? false) == playing) continue;
          try {
            item.update(
              isPlaying: playing,
              playingIndicatorLocation:
                  playing ? CPListItemPlayingIndicatorLocation.trailing : null,
            );
          } catch (e) {
            debugPrint('⚠️ CarPlay playing indicator update failed: $e');
          }
        }
      }
    }
  }

  CPListItem _shuffleRow(List<JellyfinTrack> tracks) {
    return CPListItem(
      text: 'Shuffle',
      detailText: '${tracks.length} songs',
      onPress: _tap((origin) async {
        try {
          await appState.audioPlayerService.playShuffled(tracks);
        } catch (e) {
          await _showPlaybackError(null, e, origin);
          return;
        }
        if (_stillAt(origin)) await _showNowPlaying();
      }),
    );
  }

  /// Paginated track list. Tapping any row queues the whole [tracks] list.
  Future<void> _pushTrackList({
    required String title,
    required List<JellyfinTrack> tracks,
    required String systemIcon,
    required String Function(JellyfinTrack) detail,
    required CPTemplate? origin,
    int offset = 0,
    bool replaceTop = false,
    bool localArtwork = false,
  }) async {
    final showShuffle = offset == 0 && tracks.length > 1;
    final pageSize = await _pageSize(reserved: showShuffle ? 2 : 1);
    final page = tracks.skip(offset).take(pageSize).toList();
    final hasMore = offset + page.length < tracks.length;
    final art = (localArtwork || appState.isOfflineMode)
        ? await _localTrackArt(page)
        : const <String, String>{};

    final items = <CPListTemplateItem>[
      if (showShuffle) _shuffleRow(tracks),
      for (var i = 0; i < page.length; i++)
        _trackRow(page[i], tracks, offset + i, detail(page[i]),
            imageOverride: art[page[i].id]),
    ];
    if (hasMore) {
      final nextOffset = offset + page.length;
      items.add(_loadMoreRow(
        '${tracks.length - nextOffset} more songs',
        (o) => _pushTrackList(
          title: title,
          tracks: tracks,
          systemIcon: systemIcon,
          detail: detail,
          origin: o,
          offset: nextOffset,
          replaceTop: true,
          localArtwork: localArtwork,
        ),
      ));
    }

    if (!_stillAt(origin)) return;
    await _push(
      CPListTemplate(
        title: offset > 0
            ? '$title (${offset + 1}–${offset + page.length})'
            : title,
        sections: [CPListSection(items: items)],
        systemIcon: systemIcon,
      ),
      replaceTop: replaceTop,
    );
  }

  static String _artistsAndAlbum(JellyfinTrack t) {
    final artists = t.artists.join(', ');
    final album = t.album;
    return album == null || album.isEmpty ? artists : '$artists • $album';
  }

  // ============ Pages ============

  Future<void> _showAlbums({int offset = 0, CPTemplate? origin, bool replaceTop = false}) async {
    if (await _blockedByNoLibrary('Albums', origin)) return;
    List<JellyfinAlbum> albums;
    int pageSize;
    try {
      pageSize = await _pageSize();
      // One extra to learn whether another page exists.
      albums = await _fetchAlbumPage(offset, pageSize + 1);
    } catch (e) {
      await _showLoadError('Albums', e, origin);
      return;
    }
    if (albums.isEmpty) {
      await _showMessage(
          'Albums', offset == 0 ? 'No albums available' : 'No more albums',
          origin: origin);
      return;
    }
    final hasMore = albums.length > pageSize;
    final page = albums.take(pageSize).toList();
    final art = appState.isOfflineMode
        ? await _localAlbumArt(page)
        : const <String, String>{};

    final items = <CPListTemplateItem>[
      for (final album in page) _albumRow(album, imageOverride: art[album.id]),
      if (hasMore)
        _loadMoreRow(
          'More albums',
          (o) => _showAlbums(
              offset: offset + page.length, origin: o, replaceTop: true),
        ),
    ];

    if (!_stillAt(origin)) return;
    await _push(
      CPListTemplate(
        title: offset > 0
            ? 'Albums (${offset + 1}–${offset + page.length})'
            : 'Albums',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note.list',
      ),
      replaceTop: replaceTop,
    );
  }

  Future<void> _showArtists({int offset = 0, CPTemplate? origin, bool replaceTop = false}) async {
    if (await _blockedByNoLibrary('Artists', origin)) return;
    List<JellyfinArtist> artists;
    int pageSize;
    try {
      pageSize = await _pageSize();
      artists = await _fetchArtistPage(offset, pageSize + 1);
    } catch (e) {
      await _showLoadError('Artists', e, origin);
      return;
    }
    if (artists.isEmpty) {
      await _showMessage(
          'Artists', offset == 0 ? 'No artists available' : 'No more artists',
          origin: origin);
      return;
    }
    final hasMore = artists.length > pageSize;
    final page = artists.take(pageSize).toList();

    final items = <CPListTemplateItem>[
      for (final artist in page) _artistRow(artist),
      if (hasMore)
        _loadMoreRow(
          'More artists',
          (o) => _showArtists(
              offset: offset + page.length, origin: o, replaceTop: true),
        ),
    ];

    if (!_stillAt(origin)) return;
    await _push(
      CPListTemplate(
        title: offset > 0
            ? 'Artists (${offset + 1}–${offset + page.length})'
            : 'Artists',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.mic',
      ),
      replaceTop: replaceTop,
    );
  }

  Future<void> _showPlaylists({int offset = 0, CPTemplate? origin, bool replaceTop = false}) async {
    if (await _blockedByNoLibrary('Playlists', origin)) return;
    List<JellyfinPlaylist> all;
    try {
      if (!appState.isOfflineMode) {
        if (appState.playlists == null && !appState.isLoadingPlaylists) {
          await appState.refreshPlaylists().timeout(_fetchTimeout);
        } else if (appState.isLoadingPlaylists) {
          await _waitFor(() => !appState.isLoadingPlaylists);
        }
      }
      // Offline: previously loaded playlists still work; their tracks come
      // from downloads (NautuneAppState.getPlaylistTracks).
      all = appState.playlists ?? const [];
    } catch (e) {
      await _showLoadError('Playlists', e, origin);
      return;
    }
    if (all.isEmpty && !appState.isOfflineMode && appState.playlistsError != null) {
      await _showLoadError('Playlists', appState.playlistsError!, origin);
      return;
    }
    if (all.isEmpty) {
      await _showMessage(
        'Playlists',
        appState.isOfflineMode
            ? 'Playlists aren’t available offline'
            : 'No playlists available',
        origin: origin,
      );
      return;
    }

    final pageSize = await _pageSize();
    final page = all.skip(offset).take(pageSize).toList();
    final hasMore = offset + page.length < all.length;
    final items = <CPListTemplateItem>[
      for (final playlist in page)
        CPListItem(
          text: playlist.name,
          detailText: '${playlist.trackCount} tracks',
          image: appState.isOfflineMode
              ? null
              : appState.jellyfinService.buildSelfContainedImageUrl(
                  itemId: playlist.id,
                  tag: playlist.primaryImageTag,
                  maxWidth: 200,
                ),
          accessoryType: CPListItemAccessoryType.disclosureIndicator,
          onPress: _tap((o) =>
              _showPlaylistTracks(playlist.id, playlist.name, origin: o)),
        ),
      if (hasMore)
        _loadMoreRow(
          '${all.length - offset - page.length} more playlists',
          (o) => _showPlaylists(
              offset: offset + page.length, origin: o, replaceTop: true),
        ),
    ];

    if (!_stillAt(origin)) return;
    await _push(
      CPListTemplate(
        title: offset > 0
            ? 'Playlists (${offset + 1}–${offset + page.length} of ${all.length})'
            : 'Playlists (${all.length})',
        sections: [CPListSection(items: items)],
        systemIcon: 'music.note.list',
      ),
      replaceTop: replaceTop,
    );
  }

  Future<void> _showAlbumTracks(String albumId, String albumName,
      {CPTemplate? origin}) async {
    List<JellyfinTrack> tracks;
    try {
      tracks = await appState.getAlbumTracks(albumId).timeout(_fetchTimeout);
    } catch (e) {
      await _showLoadError(albumName, e, origin);
      return;
    }
    if (tracks.isEmpty) {
      await _showMessage(albumName, 'No tracks in this album', origin: origin);
      return;
    }
    await _pushTrackList(
      title: albumName,
      tracks: tracks,
      systemIcon: 'music.note',
      detail: (t) => t.artists.join(', '),
      origin: origin,
    );
  }

  Future<void> _showArtistAlbums(String artistId, String artistName,
      {CPTemplate? origin}) async {
    List<JellyfinAlbum> albums;
    try {
      if (appState.isDemoMode) {
        albums = (appState.albums ?? const <JellyfinAlbum>[])
            .where((a) => a.artists.contains(artistName))
            .toList();
      } else if (appState.isOfflineMode) {
        albums = await appState.repository.getArtistAlbums(artistId);
        if (albums.isEmpty) {
          final all = await appState.repository
              .getAlbums(libraryId: 'offline_downloads', limit: 100000);
          albums = all.where((a) => a.artists.contains(artistName)).toList();
        }
      } else {
        albums = await appState.jellyfinService
            .loadAlbumsByArtist(artistId: artistId)
            .timeout(_fetchTimeout);
      }
    } catch (e) {
      await _showLoadError(artistName, e, origin);
      return;
    }
    if (albums.isEmpty) {
      await _showMessage(artistName, 'No albums from this artist', origin: origin);
      return;
    }

    final pageSize = await _pageSize(reserved: 0);
    final page = albums.take(pageSize).toList();
    final art = appState.isOfflineMode
        ? await _localAlbumArt(page)
        : const <String, String>{};
    if (!_stillAt(origin)) return;
    await _push(CPListTemplate(
      title: artistName,
      sections: [
        CPListSection(items: [
          for (final album in page) _albumRow(album, imageOverride: art[album.id]),
        ]),
      ],
      systemIcon: 'music.note.list',
    ));
  }

  Future<void> _showPlaylistTracks(String playlistId, String playlistName,
      {CPTemplate? origin}) async {
    List<JellyfinTrack> tracks;
    try {
      tracks =
          await appState.getPlaylistTracks(playlistId).timeout(_fetchTimeout);
    } catch (e) {
      await _showLoadError(playlistName, e, origin);
      return;
    }
    if (tracks.isEmpty) {
      await _showMessage(
        playlistName,
        appState.isOfflineMode
            ? 'No downloaded tracks in this playlist'
            : 'No tracks in this playlist',
        origin: origin,
      );
      return;
    }
    await _pushTrackList(
      title: playlistName,
      tracks: tracks,
      systemIcon: 'music.note',
      detail: (t) => t.artists.join(', '),
      origin: origin,
    );
  }

  Future<void> _showFavorites({CPTemplate? origin}) async {
    if (await _blockedByNoLibrary('Favorites', origin)) return;
    List<JellyfinTrack> favorites;
    try {
      if (appState.isOfflineMode) {
        favorites = await appState.repository.getFavoriteTracks();
      } else {
        if (appState.favoriteTracks == null && !appState.isLoadingFavorites) {
          await appState.refreshFavorites().timeout(_fetchTimeout);
        } else if (appState.isLoadingFavorites) {
          await _waitFor(() => !appState.isLoadingFavorites);
        }
        favorites = appState.favoriteTracks ?? const [];
      }
    } catch (e) {
      await _showLoadError('Favorites', e, origin);
      return;
    }
    if (favorites.isEmpty &&
        !appState.isOfflineMode &&
        appState.favoritesError != null) {
      await _showLoadError('Favorites', appState.favoritesError!, origin);
      return;
    }
    if (favorites.isEmpty) {
      await _showMessage('Favorites', 'No favorite tracks yet', origin: origin);
      return;
    }
    await _pushTrackList(
      title: 'Favorites',
      tracks: List.of(favorites),
      systemIcon: 'heart.fill',
      detail: _artistsAndAlbum,
      origin: origin,
    );
  }

  Future<void> _showRecentlyPlayed({CPTemplate? origin}) async {
    if (appState.isOfflineMode) {
      await _showMessage('Recently Played', 'Not available offline', origin: origin);
      return;
    }
    if (await _blockedByNoLibrary('Recently Played', origin)) return;
    List<JellyfinTrack> recent;
    try {
      if (appState.recentlyPlayedTracks == null &&
          !appState.isLoadingRecentlyPlayed) {
        // refreshRecentlyPlayed() fills recentlyPlayedTracks; refreshRecent()
        // loads a different list (recent tracks) and would leave this null.
        await appState.refreshRecentlyPlayed().timeout(_fetchTimeout);
      } else if (appState.isLoadingRecentlyPlayed) {
        await _waitFor(() => !appState.isLoadingRecentlyPlayed);
      }
      recent = appState.recentlyPlayedTracks ?? const [];
    } catch (e) {
      await _showLoadError('Recently Played', e, origin);
      return;
    }
    if (recent.isEmpty) {
      await _showMessage('Recently Played', 'No listening history yet', origin: origin);
      return;
    }
    await _pushTrackList(
      title: 'Recently Played',
      tracks: List.of(recent),
      systemIcon: 'clock.fill',
      detail: _artistsAndAlbum,
      origin: origin,
    );
  }

  Future<void> _showDownloads({CPTemplate? origin}) async {
    final downloads = appState.downloadService.completedDownloads;
    if (downloads.isEmpty) {
      await _showMessage(
        'Downloads',
        'No downloaded music',
        detail: 'Download music on your iPhone to play it without a connection.',
        origin: origin,
      );
      return;
    }
    await _pushTrackList(
      title: 'Downloads',
      tracks: downloads.map((d) => d.track).toList(),
      systemIcon: 'arrow.down.circle',
      detail: _artistsAndAlbum,
      origin: origin,
      localArtwork: true,
    );
  }

  // ============ Browse A–Z (search alternative) ============

  static String _letterOf(String name) {
    if (name.isEmpty) return '#';
    final c = name[0].toUpperCase();
    final code = c.codeUnitAt(0);
    return (code >= 65 && code <= 90) ? c : '#';
  }

  Future<void> _showAlphabeticalLetters(
      {required bool forArtists, CPTemplate? origin}) async {
    final title = forArtists ? 'Artists A–Z' : 'Albums A–Z';
    if (await _blockedByNoLibrary(title, origin)) return;
    List<String> names;
    try {
      names = forArtists
          ? (await _artistNameIndex()).map((a) => a.groupingName).toList()
          : (await _albumNameIndex()).map((a) => a.groupingName).toList();
    } catch (e) {
      await _showLoadError(title, e, origin);
      return;
    }
    if (names.isEmpty) {
      await _showMessage(title, 'Nothing to browse yet', origin: origin);
      return;
    }

    final buckets = <String, int>{};
    for (final n in names) {
      buckets.update(_letterOf(n), (v) => v + 1, ifAbsent: () => 1);
    }
    final letters = buckets.keys.toList()
      ..sort((a, b) {
        if (a == '#') return -1;
        if (b == '#') return 1;
        return a.compareTo(b);
      });

    if (!_stillAt(origin)) return;
    await _push(CPListTemplate(
      title: title,
      sections: [
        CPListSection(items: [
          for (final letter in letters)
            CPListItem(
              text: letter,
              detailText: '${buckets[letter]} ${forArtists ? 'artists' : 'albums'}',
              accessoryType: CPListItemAccessoryType.disclosureIndicator,
              onPress: _tap((o) =>
                  _showLetterBucket(letter, forArtists: forArtists, origin: o)),
            ),
        ]),
      ],
      systemIcon: 'character.book.closed',
    ));
  }

  Future<void> _showLetterBucket(String letter,
      {required bool forArtists,
      int offset = 0,
      CPTemplate? origin,
      bool replaceTop = false}) async {
    final title = forArtists ? 'Artists · $letter' : 'Albums · $letter';
    List<Object> matching;
    try {
      matching = forArtists
          ? (await _artistNameIndex())
              .where((a) => _letterOf(a.groupingName) == letter)
              .toList()
          : (await _albumNameIndex())
              .where((a) => _letterOf(a.groupingName) == letter)
              .toList();
    } catch (e) {
      await _showLoadError(title, e, origin);
      return;
    }
    if (matching.isEmpty) {
      await _showMessage(title, 'Nothing under $letter', origin: origin);
      return;
    }

    final pageSize = await _pageSize();
    final page = matching.skip(offset).take(pageSize).toList();
    final hasMore = offset + page.length < matching.length;
    final albumArt = (!forArtists && appState.isOfflineMode)
        ? await _localAlbumArt(page.whereType<JellyfinAlbum>())
        : const <String, String>{};

    final items = <CPListTemplateItem>[
      for (final entry in page)
        if (entry is JellyfinArtist)
          _artistRow(entry)
        else if (entry is JellyfinAlbum)
          _albumRow(entry, imageOverride: albumArt[entry.id]),
      if (hasMore)
        _loadMoreRow(
          '${matching.length - offset - page.length} more',
          (o) => _showLetterBucket(letter,
              forArtists: forArtists,
              offset: offset + page.length,
              origin: o,
              replaceTop: true),
        ),
    ];

    if (!_stillAt(origin)) return;
    await _push(
      CPListTemplate(
        title: offset > 0 ? '$title (${offset + 1}–${offset + page.length})' : title,
        sections: [CPListSection(items: items)],
        systemIcon: forArtists ? 'music.mic' : 'music.note.list',
      ),
      replaceTop: replaceTop,
    );
  }

  void dispose() {
    _updateThrottleTimer?.cancel();
    _currentTrackSub?.cancel();
    _carplay.removeListenerOnConnectionChange();
    _carplay.closeConnection();
    appState.removeListener(_onAppStateChanged);
    appState.downloadService.removeListener(_onAppStateChanged);
  }
}

class _NameIndex<T> {
  _NameIndex(this.key, this.items) : createdAt = DateTime.now();

  final String key;
  final List<T> items;
  final DateTime createdAt;

  bool isValidFor(String currentKey, Duration ttl) =>
      key == currentKey && DateTime.now().difference(createdAt) < ttl;
}
