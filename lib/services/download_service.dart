import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_session.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import '../utils/backup_exclusion.dart';
import '../utils/download_checks.dart';
import '../utils/download_format.dart';
import '../utils/download_migration.dart';
import '../utils/download_paths.dart';
import '../utils/download_status.dart';
import '../utils/progress_throttle.dart';
import 'audio_cache_service.dart';
import 'chart_cache_service.dart';
import 'connectivity_service.dart';
import 'hive_init.dart';
import 'lyrics_service.dart';
import 'notification_service.dart';
import 'waveform_service.dart';

/// Storage statistics for downloads AND cache
class StorageStats {
  // Download stats
  final int totalBytes;
  final int trackCount;
  final Map<String, int> byAlbum; // albumId -> bytes
  final Map<String, int> byArtist; // artistName -> bytes
  final Map<String, String> albumNames; // albumId -> albumName

  // Cache stats (smart pre-cached tracks)
  final int cacheBytes;
  final int cacheFileCount;
  final List<String> cachedTrackIds;

  // Waveform stats
  final int waveformBytes;
  final int waveformFileCount;

  // Chart stats
  final int chartBytes;
  final int chartCount;

  StorageStats({
    required this.totalBytes,
    required this.trackCount,
    required this.byAlbum,
    required this.byArtist,
    required this.albumNames,
    this.cacheBytes = 0,
    this.cacheFileCount = 0,
    this.cachedTrackIds = const [],
    this.waveformBytes = 0,
    this.waveformFileCount = 0,
    this.chartBytes = 0,
    this.chartCount = 0,
  });

  String get formattedTotal => _formatBytes(totalBytes);
  String get formattedCache => _formatBytes(cacheBytes);
  String get formattedCombined => _formatBytes(totalBytes + cacheBytes);
  String get formattedWaveforms => _formatBytes(waveformBytes);
  String get formattedCharts => _formatBytes(chartBytes);

  static String _formatBytes(int bytes) => formatDownloadBytes(bytes);
}

/// Storage used outside the downloads folder (see
/// [DownloadService.getStorageStats]).
class _AuxStorageStats {
  const _AuxStorageStats({
    required this.cacheBytes,
    required this.cacheFileCount,
    required this.cachedTrackIds,
    required this.waveformBytes,
    required this.waveformFileCount,
    required this.chartBytes,
    required this.chartCount,
  });

  final int cacheBytes;
  final int cacheFileCount;
  final List<String> cachedTrackIds;
  final int waveformBytes;
  final int waveformFileCount;
  final int chartBytes;
  final int chartCount;
}

/// Response for one download attempt plus how it was obtained.
class _DownloadSource {
  const _DownloadSource(
    this.response, {
    required this.viaUniversal,
    required this.extension,
  });

  final http.StreamedResponse response;

  /// True when served by `/Audio/{id}/universal` (possibly a transcode), so
  /// the response may not be the original file.
  final bool viaUniversal;

  /// File extension for the saved file.
  final String extension;
}

class DownloadService extends ChangeNotifier with WidgetsBindingObserver {
  final JellyfinService jellyfinService;
  final NotificationService? _notificationService;
  ConnectivityService? _connectivityService;
  LyricsService? _lyricsService;
  final Map<String, DownloadItem> _downloads = {};
  final List<String> _downloadQueue = [];
  // Album/playlist batches in flight, keyed by album/playlist id. Used to
  // guard against duplicate batch downloads from rapid double-taps.
  final Set<String> _albumBatchInFlight = <String>{};
  final Set<String> _playlistBatchInFlight = <String>{};
  // Network failures per track. A track that keeps failing with network
  // errors while the network is up is eventually marked failed so it cannot
  // block the queue forever.
  final Map<String, int> _networkFailures = <String, int>{};
  static const int _maxNetworkFailures = 8;
  // Consecutive network failures across the queue; drives the retry backoff.
  int _consecutiveNetworkFailures = 0;
  Timer? _networkRetryTimer;
  // After a network pause, run a single download until data flows again so
  // a still-dead network doesn't burn retry attempts of several tracks.
  bool _networkProbe = false;
  DownloadQueuePause _queuePause = DownloadQueuePause.none;
  // Connectivity stream subscription so reconnects (and Wi-Fi <-> cellular
  // switches) pause/resume the queue without UI involvement.
  StreamSubscription<bool>? _connectivitySub;
  int _maxConcurrentDownloads = 3; // Now configurable
  int _activeDownloads = 0;
  final http.Client _httpClient; // Reused for connection pooling
  bool _demoModeEnabled = false;
  Uint8List? _demoAudioBytes;
  final Set<String> _demoDownloadIds = <String>{};

  // Completed / failed counts since the queue was last idle (for the
  // "Downloads finished" notification).
  int _batchCompleted = 0;
  int _batchFailed = 0;

  // Download settings
  bool _wifiOnlyDownloads = false;
  int _storageLimitMB = 0; // 0 = unlimited
  bool _autoCleanupEnabled = false;
  int _autoCleanupDays = 30;
  bool _settingsLoaded = false;
  bool _verified = false;
  bool _autoCleanupRan = false;

  // Secondary indexes for O(1) album/artist lookups instead of O(n) scans
  final Map<String, Set<String>> _albumIndex = {}; // albumId -> Set<trackId>
  final Map<String, Set<String>> _artistIndex = {}; // artistName -> Set<trackId>
  final Map<String, Set<String>> _artistIdIndex = {}; // artistId -> Set<trackId>

  // Notification throttling to reduce UI rebuilds during downloads (max 2Hz)
  Timer? _notifyThrottle;
  bool _pendingNotification = false;

  // Waveform extraction for finished downloads runs one at a time so a big
  // batch doesn't decode dozens of files in parallel.
  Future<void> _waveformChain = Future<void>.value();

  // Post-download work (duration probe, images, lyrics), one track at a
  // time and off the download slots.
  Future<void> _postCompletionChain = Future<void>.value();

  // Transcodes that came back shorter than the server's length, per track.
  // Retried a few times; a consistently short result is then kept (the
  // server's length is probably wrong).
  final Map<String, int> _truncatedAttempts = <String, int>{};
  static const int _maxTruncatedAttempts = 3;

  // Artwork fetches in flight per album, so tracks of one album finishing
  // together share a single request and write.
  final Map<String, Future<bool>> _artworkFetches = <String, Future<bool>>{};

  static const _boxName = 'nautune_downloads';
  // Legacy format: the whole map under one key (rewritten on every save).
  static const _downloadsKey = 'downloads';
  // Current format: one record per track under `t:<trackId>`, so a save
  // only writes the records that changed.
  static const _recordPrefix = 't:';
  static const _stallTimeout = Duration(seconds: 60);
  static const _connectTimeout = Duration(seconds: 30);
  static const _imageFetchTimeout = Duration(seconds: 15);
  static const _durationProbeTimeout = Duration(seconds: 10);
  static const _waveformTimeout = Duration(minutes: 2);
  static const _saveDebounce = Duration(milliseconds: 600);
  static const int _flushInterval = 4 * 1024 * 1024;
  static const _saveMaxDelay = Duration(seconds: 3);
  static final RegExp _unsafeNameChars = RegExp(r'[^\w\s-]');
  static const int _maxNameLength = 80;
  Box<dynamic>? _box;

  // Downloads root: <Application Support>/downloads. Resolved (and the legacy
  // Documents/downloads migrated) once; every path getter awaits it.
  Future<Directory>? _rootFuture;
  String? _rootPath;
  // Legacy Documents/downloads path, kept only while the migration has not
  // completed so records whose files were not moved yet can still be found.
  String? _legacyRootPath;

  // True once persisted records have been loaded; saves before that would
  // overwrite the stored records with a partial in-memory map.
  bool _loadCompleted = false;
  bool _saveAfterLoad = false;
  bool _disposed = false;

  // What the Hive box holds: trackId -> the item instance last written
  // (null = a record exists but must be rewritten or deleted). Saves diff
  // `_downloads` against this by identity, so only changed records are
  // serialized and written.
  Map<String, DownloadItem?> _persisted = {};
  // Legacy single-map record still present; deleted after its records have
  // been written in the per-track format.
  bool _legacyRecordPending = false;
  Timer? _saveTimer;
  DateTime? _saveDirtySince;

  // Per-download cancellation tokens for in-flight downloads. Deleting or
  // cancelling a download removes (and completes) the token: completing it
  // aborts the HTTP request, and the transfer loop exits cleanly.
  final Map<String, Completer<void>> _activeTokens = {};

  // Session whose serverUrl/token/userId were last applied to restored tracks.
  JellyfinSession? _hydratedSession;
  // Polls for a Jellyfin session so restored queued downloads can resume.
  Timer? _restoreKickTimer;

  // Bumped on every structural change (not on progress ticks).
  int _revision = 0;

  DownloadService({
    required this.jellyfinService,
    NotificationService? notificationService,
    http.Client? httpClient,
  })  : _notificationService = notificationService,
        _httpClient = httpClient ?? http.Client() {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding (pure Dart tests); lifecycle flushing is best-effort.
    }
    _ready = _initializeAndLoad();
  }

  late final Future<void> _ready;

  /// Completes once stored downloads are loaded and verified.
  Future<void> get ready => _ready;

  Future<void> _initializeAndLoad() async {
    try {
      await _downloadsRoot(); // runs the one-time Documents -> Support migration
    } catch (e) {
      debugPrint('DownloadService: failed to prepare downloads root: $e');
    }
    try {
      await _initHive();
    } catch (e) {
      debugPrint('DownloadService: failed to open downloads box: $e');
    }
    await _loadDownloads();
    _rebuildIndexes(); // Build secondary indexes after loading
    // Resume restored work first; verifying thousands of files can wait.
    _resumeRestoredQueue();
    await verifyAndCleanupDownloads();
    _verified = true;
    _maybeRunAutoCleanup();
  }

  /// Resolve (once) the downloads root, migrating the legacy
  /// Documents/downloads folder and excluding the root from backup.
  Future<Directory> _downloadsRoot() {
    return _rootFuture ??= _initDownloadsRoot().catchError(
      (Object e, StackTrace st) {
        _rootFuture = null; // allow a later retry
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  Future<Directory> _initDownloadsRoot() async {
    final supportDir = await getApplicationSupportDirectory();
    final root = Directory('${supportDir.path}/${DownloadPaths.folderName}');

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final legacy = Directory('${docsDir.path}/${DownloadPaths.folderName}');
      final migrated = await DownloadMigration.migrate(
        from: legacy,
        to: root,
        log: (m) => debugPrint('DownloadService: $m'),
      );
      _legacyRootPath = migrated ? null : legacy.path;
    } catch (e) {
      debugPrint('DownloadService: legacy downloads migration skipped: $e');
    }

    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _rootPath = root.absolute.path;
    await excludeFromBackup(_rootPath!);
    return root;
  }

  /// Relative form of an absolute download path, as persisted in Hive.
  String _toStoredPath(String absolutePath) =>
      DownloadPaths.toRelative(absolutePath, rootPath: _rootPath);

  /// If [absolutePath] is missing but the legacy migration has not finished,
  /// return the equivalent path under the legacy root when that file exists.
  Future<String?> _findInLegacyRoot(String absolutePath) async {
    final legacy = _legacyRootPath;
    if (legacy == null || absolutePath.isEmpty) return null;
    final candidate =
        DownloadPaths.toAbsolute(_toStoredPath(absolutePath), legacy);
    if (candidate.isEmpty) return null;
    return await File(candidate).exists() ? candidate : null;
  }

  // ---------------------------------------------------------------------------
  // Session hydration: records rebuilt from storage have no serverUrl / token /
  // userId, so playback reporting and streaming fallback cannot work for them.
  // ---------------------------------------------------------------------------

  JellyfinTrack _hydrateTrack(JellyfinTrack track, JellyfinSession session) {
    final serverUrl = session.serverUrl;
    final token = session.credentials.accessToken;
    final userId =
        session.credentials.userId.isEmpty ? null : session.credentials.userId;
    if (serverUrl.isEmpty) return track;
    // Another server or user's download: never hand it this session's
    // credentials (its requests would go to the wrong account).
    if (!_belongsTo(track, session)) return track;
    if (track.serverUrl == null || track.token == null) {
      return track.copyWith(
        serverUrl: track.serverUrl ?? serverUrl,
        token: token,
        userId: track.userId ?? userId,
      );
    }
    // Same account, refreshed credentials (re-login): keep the track current.
    if (track.token != token || (userId != null && track.userId == null)) {
      return track.copyWith(token: token, userId: userId);
    }
    return track;
  }

  /// Whether [track]'s download belongs to [session]'s server and user.
  /// Records from older versions (no server/user stored) always match.
  bool _belongsTo(JellyfinTrack track, JellyfinSession session) =>
      downloadBelongsToSession(
        recordServerUrl: track.serverUrl,
        recordUserId: track.userId,
        sessionServerUrl: session.serverUrl,
        sessionUserId: session.credentials.userId,
      );

  /// Stop every in-flight transfer and put it back at the head of the queue
  /// (status queued, partial data discarded). Call when the account is about
  /// to change (logout, switching server or user) so no transfer keeps
  /// running with the previous account's credentials. Queued downloads of
  /// another account stay queued until that account signs in again.
  void pauseActiveForSessionChange() {
    if (_disposed) return;
    _requeueActiveDownloads();
  }

  /// Apply the current Jellyfin session to downloaded tracks when the session
  /// changed since the last call. Cheap (identity check) when nothing changed.
  void _syncSessionFields() {
    final session = jellyfinService.session;
    if (identical(session, _hydratedSession)) return;
    _hydratedSession = session;
    if (session == null || session.isDemo) return;
    var changed = false;
    for (final entry in _downloads.entries.toList()) {
      final item = entry.value;
      if (item.isDemoAsset) continue;
      final hydrated = _hydrateTrack(item.track, session);
      if (!identical(hydrated, item.track)) {
        final updated = item.copyWith(track: hydrated);
        _downloads[entry.key] = updated;
        // The token is not persisted; the server/user are, so a record that
        // just got them (written by an older version) is saved again.
        if (identical(_persisted[entry.key], item) &&
            !_accountFieldsChanged(item.track, hydrated)) {
          _persisted[entry.key] = updated;
        }
        changed = true;
      }
    }
    if (changed) {
      // Invalidate cached lists without notifying (may run inside a getter
      // during build); the fresh values are returned on this same call.
      _invalidateCaches();
    }
  }

  /// Call after the Jellyfin session is restored, created, or refreshed.
  /// Hydrates downloaded tracks with serverUrl/token/userId and resumes
  /// downloads that were restored from storage. Also happens automatically
  /// (lazily on access and via a short poll while restored downloads wait),
  /// so calling this is optional but makes it immediate.
  void onSessionChanged() {
    _syncSessionFields();
    _requeueForeignActiveDownloads();
    if (!_disposed) notifyListeners();
    // Persist server/user newly attached to older records (no-op otherwise).
    _scheduleSave();
    _resumeRestoredQueue();
  }

  static bool _accountFieldsChanged(JellyfinTrack before, JellyfinTrack after) =>
      before.serverUrl != after.serverUrl || before.userId != after.userId;

  /// In-flight transfers that belong to another account than the current
  /// session go back to the queue (they resume when that account returns).
  void _requeueForeignActiveDownloads() {
    final session = jellyfinService.session;
    if (session == null || session.isDemo || _activeTokens.isEmpty) return;
    final foreign = [
      for (final id in _activeTokens.keys)
        if (_downloads[id] case final item?
            when !item.isCompleted && !_belongsTo(item.track, session))
          id,
    ];
    if (foreign.isNotEmpty) _requeueActiveDownloads(only: foreign);
  }

  /// Start processing queued downloads once the service is loaded and a
  /// Jellyfin session exists. The session is restored after download
  /// settings (Wi-Fi only / concurrency) are applied, so waiting for it also
  /// ensures those settings are respected.
  void _resumeRestoredQueue() {
    if (_disposed || !_loadCompleted || _downloadQueue.isEmpty) return;
    if (jellyfinService.session != null) {
      _restoreKickTimer?.cancel();
      _restoreKickTimer = null;
      _syncSessionFields();
      unawaited(_processQueue());
      return;
    }
    _restoreKickTimer ??=
        Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_disposed || _downloadQueue.isEmpty) {
        timer.cancel();
        _restoreKickTimer = null;
        return;
      }
      if (jellyfinService.session != null) {
        timer.cancel();
        _restoreKickTimer = null;
        _resumeRestoredQueue();
      }
    });
  }

  Future<void> _initHive() async {
    await ensureHiveInitialized();
    _box = await Hive.openBox<dynamic>(_boxName);
  }

  /// Rebuild all secondary indexes from current downloads
  void _rebuildIndexes() {
    _albumIndex.clear();
    _artistIndex.clear();
    _artistIdIndex.clear();
    for (final item in _downloads.values) {
      if (item.isCompleted) {
        _addToIndexes(item.track);
      }
    }
  }

  /// Add a track to the secondary indexes
  void _addToIndexes(JellyfinTrack track) {
    final albumId = track.albumId ?? 'unknown';
    _albumIndex.putIfAbsent(albumId, () => {}).add(track.id);

    final artistName = track.displayArtist;
    _artistIndex.putIfAbsent(artistName, () => {}).add(track.id);

    // Also index by artist IDs for efficient artist image cleanup
    for (final artistId in track.artistIds) {
      _artistIdIndex.putIfAbsent(artistId, () => {}).add(track.id);
    }
  }

  /// Remove a track from the secondary indexes
  void _removeFromIndexes(JellyfinTrack track) {
    final albumId = track.albumId ?? 'unknown';
    _albumIndex[albumId]?.remove(track.id);
    if (_albumIndex[albumId]?.isEmpty ?? false) {
      _albumIndex.remove(albumId);
    }

    final artistName = track.displayArtist;
    _artistIndex[artistName]?.remove(track.id);
    if (_artistIndex[artistName]?.isEmpty ?? false) {
      _artistIndex.remove(artistName);
    }

    // Remove from artist ID index
    for (final artistId in track.artistIds) {
      _artistIdIndex[artistId]?.remove(track.id);
      if (_artistIdIndex[artistId]?.isEmpty ?? false) {
        _artistIdIndex.remove(artistId);
      }
    }
  }

  // Lock to prevent race conditions between download and delete operations
  final Set<String> _operationLocks = {};

  // Cached lists — the sorted/active lists are invalidated on every notify
  // (progress ticks replace downloading items); completed/failed/incompatible
  // only on structural changes.
  List<DownloadItem>? _sortedDownloadsCache;
  List<DownloadItem>? _completedDownloadsCache;
  List<DownloadItem>? _activeDownloadsCache;
  List<DownloadItem>? _failedDownloadsCache;
  List<DownloadItem>? _incompatibleDownloadsCache;

  void _invalidateCaches() {
    _sortedDownloadsCache = null;
    _completedDownloadsCache = null;
    _activeDownloadsCache = null;
    _failedDownloadsCache = null;
    _incompatibleDownloadsCache = null;
  }

  List<DownloadItem> get downloads {
    _syncSessionFields();
    _sortedDownloadsCache ??= _downloads.values.toList()
      ..sort((a, b) => b.queuedAt.compareTo(a.queuedAt));
    return _sortedDownloadsCache!;
  }

  /// Structural change: invalidates every cache and bumps [revision].
  @override
  void notifyListeners() {
    _revision++;
    _invalidateCaches();
    super.notifyListeners();
  }

  /// Progress-only change (bytes of in-flight downloads). Keeps the
  /// completed/failed caches — and so the identity of [completedDownloads],
  /// which offline screens use to skip recomputation — intact.
  void _notifyProgress() {
    _sortedDownloadsCache = null;
    _activeDownloadsCache = null;
    super.notifyListeners();
  }

  /// Settings / queue-state change: no list or [revision] change.
  void _notifySettings() {
    if (!_disposed) super.notifyListeners();
  }

  /// Increments on every structural change (queued, started, completed,
  /// failed, deleted, settings), but not on progress ticks. Widgets that do
  /// expensive work per change (storage stats) can key off this.
  int get revision => _revision;

  // The offline repository touches this getter many times per library refresh
  // (~9 sites × N methods). Cache the filtered list and invalidate on notify.
  List<DownloadItem> get completedDownloads {
    _syncSessionFields();
    return _completedDownloadsCache ??=
        downloads.where((d) => d.isCompleted).toList(growable: false);
  }

  List<DownloadItem> get activeDownloads {
    _syncSessionFields();
    return _activeDownloadsCache ??= downloads
        .where((d) => d.isDownloading || d.isQueued)
        .toList(growable: false);
  }

  /// Failed downloads, newest first.
  List<DownloadItem> get failedDownloads {
    _syncSessionFields();
    return _failedDownloadsCache ??=
        downloads.where((d) => d.isFailed).toList(growable: false);
  }

  /// Completed downloads saved in a format AVPlayer cannot play (Opus/OGG,
  /// WMA, APE… originals downloaded by older versions). Re-download them
  /// with [redownloadIncompatible] to get a playable transcode.
  List<DownloadItem> get incompatibleDownloads {
    return _incompatibleDownloadsCache ??= completedDownloads.where((d) {
      if (d.isDemoAsset) return false;
      final ext = DownloadFormat.extensionOf(d.localPath);
      return ext.isNotEmpty && !DownloadFormat.isOfflinePlayableExtension(ext);
    }).toList(growable: false);
  }

  bool isDownloaded(String trackId) =>
      _downloads[trackId]?.isCompleted ?? false;

  DownloadItem? getDownload(String trackId) {
    _syncSessionFields();
    return _downloads[trackId];
  }

  JellyfinTrack? trackFor(String trackId) {
    _syncSessionFields();
    return _downloads[trackId]?.track;
  }

  /// Aggregate status of a collection (album, playlist, artist) by its
  /// track ids.
  CollectionDownloadSummary summaryFor(Iterable<String> trackIds) =>
      CollectionDownloadSummary.fromItems(trackIds.map((id) => _downloads[id]));

  /// Get all track IDs for an album (O(1) lookup)
  Set<String> trackIdsForAlbum(String albumId) => _albumIndex[albumId] ?? {};

  /// Get all track IDs for an artist (O(1) lookup)
  Set<String> trackIdsForArtist(String artistName) => _artistIndex[artistName] ?? {};

  /// Get all unique album IDs
  Iterable<String> get albumIds => _albumIndex.keys;

  /// Get all unique artist names
  Iterable<String> get artistNames => _artistIndex.keys;

  int get totalDownloads => _downloads.length;
  int get completedCount => completedDownloads.length;
  int get activeCount => activeDownloads.length;
  int get failedCount => failedDownloads.length;
  bool get isDemoMode => _demoModeEnabled;

  /// Why the queue is not progressing (or [DownloadQueuePause.none]).
  DownloadQueuePause get queuePause => _queuePause;

  /// Total size of completed downloads from cached sizes (no file I/O).
  int get completedBytes {
    var total = 0;
    for (final item in _downloads.values) {
      if (item.isCompleted) {
        total += item.fileSizeBytes ?? item.totalBytes ?? 0;
      }
    }
    return total;
  }

  // Settings getters
  int get maxConcurrentDownloads => _maxConcurrentDownloads;
  bool get wifiOnlyDownloads => _wifiOnlyDownloads;
  int get storageLimitMB => _storageLimitMB;
  bool get autoCleanupEnabled => _autoCleanupEnabled;
  int get autoCleanupDays => _autoCleanupDays;

  /// Update max concurrent downloads (1-10)
  void setMaxConcurrentDownloads(int value) {
    final newValue = value.clamp(1, 10);
    if (_maxConcurrentDownloads != newValue) {
      _maxConcurrentDownloads = newValue;
      _notifySettings();
      unawaited(_processQueue()); // Resume any waiting downloads
    }
  }

  /// Update WiFi-only downloads setting. Turning it on while on cellular
  /// pauses in-flight downloads; turning it off resumes a paused queue.
  void setWifiOnlyDownloads(bool value) {
    if (_wifiOnlyDownloads == value) return;
    _wifiOnlyDownloads = value;
    _notifySettings();
    if (value) {
      unawaited(_enforceWifiOnly());
    } else if (_queuePause == DownloadQueuePause.waitingForWifi) {
      _setQueuePause(DownloadQueuePause.none);
      unawaited(_processQueue());
    }
  }

  /// Update storage limit in MB (0 = unlimited)
  void setStorageLimitMB(int value) {
    if (_storageLimitMB != value) {
      _storageLimitMB = value;
      _notifySettings();
      // A raised (or removed) limit may unblock the queue.
      if (_queuePause == DownloadQueuePause.storageLimit) {
        _setQueuePause(DownloadQueuePause.none);
      }
      unawaited(_processQueue());
    }
  }

  /// Update auto-cleanup settings
  void setAutoCleanup({bool? enabled, int? days}) {
    bool changed = false;
    if (enabled != null && _autoCleanupEnabled != enabled) {
      _autoCleanupEnabled = enabled;
      changed = true;
    }
    if (days != null && _autoCleanupDays != days) {
      _autoCleanupDays = days;
      changed = true;
    }
    if (changed) _notifySettings();
  }

  /// Load settings from persisted state
  void loadSettings({
    int? maxConcurrentDownloads,
    bool? wifiOnlyDownloads,
    int? storageLimitMB,
    bool? autoCleanupEnabled,
    int? autoCleanupDays,
  }) {
    if (maxConcurrentDownloads != null) {
      _maxConcurrentDownloads = maxConcurrentDownloads.clamp(1, 10);
    }
    if (wifiOnlyDownloads != null) _wifiOnlyDownloads = wifiOnlyDownloads;
    if (storageLimitMB != null) _storageLimitMB = storageLimitMB;
    if (autoCleanupEnabled != null) _autoCleanupEnabled = autoCleanupEnabled;
    if (autoCleanupDays != null) _autoCleanupDays = autoCleanupDays;
    _settingsLoaded = true;
    _maybeRunAutoCleanup();
  }

  /// Run the age-based auto-cleanup once per launch, after downloads were
  /// loaded and verified and the user's settings applied.
  void _maybeRunAutoCleanup() {
    if (_autoCleanupRan || !_verified || !_settingsLoaded) return;
    _autoCleanupRan = true;
    if (!_autoCleanupEnabled) return;
    unawaited(runAutoCleanupIfEnabled().catchError((Object e) {
      debugPrint('DownloadService: auto-cleanup failed: $e');
      return 0;
    }));
  }

  /// Set the connectivity service for WiFi-only checks. Also subscribes to
  /// status changes so the queue pauses on a Wi-Fi -> cellular switch (with
  /// Wi-Fi-only on) and resumes by itself when the network comes back.
  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
    _connectivitySub?.cancel();
    _connectivitySub = service.onStatusChange.listen((online) {
      unawaited(_onConnectivityChanged(online));
    });
  }

  Future<void> _onConnectivityChanged(bool online) async {
    if (_disposed) return;
    if (_wifiOnlyDownloads && _activeTokens.isNotEmpty) {
      if (await _enforceWifiOnly()) return;
    }
    // Any connectivity change is a good moment to retry a network pause
    // right away instead of waiting out the backoff.
    if (_queuePause == DownloadQueuePause.waitingForNetwork) {
      _networkRetryTimer?.cancel();
      _networkRetryTimer = null;
    }
    if (_downloadQueue.isNotEmpty) _resumeRestoredQueue();
  }

  /// With Wi-Fi-only on and the device off Wi-Fi, stop in-flight transfers
  /// and put them back at the head of the queue. Returns true if paused.
  Future<bool> _enforceWifiOnly() async {
    final connectivity = _connectivityService;
    if (!_wifiOnlyDownloads || connectivity == null) return false;
    if (_activeTokens.isEmpty && _downloadQueue.isEmpty) return false;
    if (await connectivity.isOnWifi()) return false;
    if (!_wifiOnlyDownloads) return false; // toggled off meanwhile
    debugPrint('Downloads paused: Wi-Fi-only mode and not on Wi-Fi');
    _requeueActiveDownloads();
    _setQueuePause(DownloadQueuePause.waitingForWifi);
    return true;
  }

  /// Stop every in-flight transfer and re-queue it at the head of the queue
  /// (partial data is discarded; the transfer restarts later).
  void _requeueActiveDownloads({List<String>? only}) {
    final ids = only ?? _activeTokens.keys.toList();
    if (ids.isEmpty) return;
    for (final id in ids.reversed) {
      _cancelActive(id);
      final item = _downloads[id];
      // A transfer that already finished keeps its file: never re-queue it.
      if (item == null || item.isCompleted) continue;
      _downloads[id] = item.copyWith(
        status: DownloadStatus.queued,
        progress: 0.0,
        downloadedBytes: 0,
      );
      _downloadQueue.remove(id);
      _downloadQueue.insert(0, id);
    }
    notifyListeners();
    unawaited(_saveDownloads());
  }

  /// Set the lyrics service for pre-caching lyrics on download
  void setLyricsService(LyricsService service) {
    _lyricsService = service;
  }

  /// Check if downloads are paused due to mobile data
  bool get isPausedForMobileData =>
      _queuePause == DownloadQueuePause.waitingForWifi;

  /// Whether the device is currently on cellular data (for UI warnings).
  Future<bool> isOnCellular() async =>
      await _connectivityService?.isOnMobileData() ?? false;

  void _setQueuePause(DownloadQueuePause pause) {
    if (_queuePause == pause) return;
    _queuePause = pause;
    if (pause != DownloadQueuePause.waitingForNetwork) {
      _networkRetryTimer?.cancel();
      _networkRetryTimer = null;
    }
    _notifySettings();
  }

  /// Check if we can proceed with download based on WiFi settings
  Future<bool> _canProceedWithDownload() async {
    final connectivity = _connectivityService;
    if (!_wifiOnlyDownloads || connectivity == null) {
      if (_queuePause == DownloadQueuePause.waitingForWifi) {
        _setQueuePause(DownloadQueuePause.none);
      }
      return true;
    }

    final isOnWifi = await connectivity.isOnWifi();
    if (!isOnWifi) {
      debugPrint('Downloads paused: WiFi-only mode enabled but on mobile data');
      _setQueuePause(DownloadQueuePause.waitingForWifi);
      return false;
    }
    if (_queuePause == DownloadQueuePause.waitingForWifi) {
      _setQueuePause(DownloadQueuePause.none);
    }
    return true;
  }

  Future<bool> _hasNetworkTransport() async {
    final connectivity = _connectivityService;
    if (connectivity == null) return true;
    return connectivity.hasNetworkTransport();
  }

  bool _storageLimitReached() {
    if (_storageLimitMB <= 0) return false;
    return completedBytes >= _storageLimitMB * 1024 * 1024;
  }

  /// Throttled notification to reduce UI rebuilds during downloads (max 2Hz).
  /// Call this instead of notifyListeners() during download progress updates.
  void _throttledNotify() {
    _pendingNotification = true;
    _notifyThrottle ??= Timer(const Duration(milliseconds: 500), () {
      _notifyThrottle = null;
      if (_pendingNotification && !_disposed) {
        _pendingNotification = false;
        _notifyProgress();
      }
    });
  }

  /// Map an exception thrown during download to a DownloadErrorKind for UI
  /// surfaces and retry-policy decisions. Order matters: more specific types
  /// must come before less specific ones.
  DownloadErrorKind _classifyDownloadError(Object e) {
    if (e is TimeoutException) return DownloadErrorKind.network;
    if (e is SocketException) return DownloadErrorKind.network;
    if (e is HttpException) return DownloadErrorKind.network;
    if (e is HandshakeException) return DownloadErrorKind.network;
    if (e is http.ClientException) return DownloadErrorKind.network;
    if (e is _UnexpectedContentException) return DownloadErrorKind.server;
    if (e is _TruncatedDownloadException) return DownloadErrorKind.network;
    if (e is _HttpStatusException) {
      // Proxy/gateway errors and throttling are usually transient (server
      // restarting behind a reverse proxy): retry like a network error.
      return e.isTransient ? DownloadErrorKind.network : DownloadErrorKind.server;
    }
    if (e is FileSystemException) {
      final code = e.osError?.errorCode;
      if (code == 28) return DownloadErrorKind.storageFull; // ENOSPC
      if (code == 13) return DownloadErrorKind.permission;  // EACCES
      return DownloadErrorKind.fileSystem;
    }
    // HTTP-level failures we throw ourselves use the 'HTTP <code>' string.
    final msg = e.toString();
    if (msg.contains('HTTP 4') || msg.contains('HTTP 5')) {
      return DownloadErrorKind.server;
    }
    return DownloadErrorKind.unknown;
  }

  /// Resume downloads when WiFi becomes available
  Future<void> resumeIfOnWifi() async {
    if (!_wifiOnlyDownloads ||
        _queuePause != DownloadQueuePause.waitingForWifi) {
      return;
    }
    await _processQueue();
  }

  void enableDemoMode({required Uint8List demoAudioBytes}) {
    _demoModeEnabled = true;
    _demoAudioBytes = demoAudioBytes;
  }

  void disableDemoMode() {
    _demoModeEnabled = false;
    _demoAudioBytes = null;
    _demoDownloadIds.clear();
  }

  Future<void> deleteDemoDownloads() async {
    if (_demoDownloadIds.isEmpty) return;
    final ids = List<String>.from(_demoDownloadIds);
    for (final trackId in ids) {
      await deleteDownloadReference(trackId, 'demo'); // Use new method
    }
    _demoDownloadIds.clear();
  }

  Future<void> seedDemoDownload({
    required JellyfinTrack track,
    required Uint8List bytes,
    String extension = 'mp3',
  }) async {
    final existing = _downloads[track.id];
    if (existing != null && existing.isCompleted) {
      return;
    }

    final path = await _getDownloadPath(track, extension: extension);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    _downloads[track.id] = DownloadItem(
      track: track,
      localPath: path,
      status: DownloadStatus.completed,
      progress: 1.0,
      totalBytes: bytes.length,
      downloadedBytes: bytes.length,
      queuedAt: DateTime.now(),
      completedAt: DateTime.now(),
      isDemoAsset: true,
      owners: {'demo'}, // Add 'demo' as owner
      fileSizeBytes: bytes.length,
    );

    _demoDownloadIds.add(track.id);
    _addToIndexes(track);
    notifyListeners();
    await _saveDownloads();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Rebuild a [DownloadItem] from a stored record. Null if unusable.
  DownloadItem? _itemFromRecord(String trackId, Map<String, dynamic> itemData) {
    try {
      // Fix duration loading logic
      int? runTimeTicks;
      if (itemData['runTimeTicks'] != null) {
        runTimeTicks = (itemData['runTimeTicks'] as num?)?.toInt();
      } else if (itemData['trackDuration'] != null) {
        // Legacy format: stored as milliseconds (1 ms = 10,000 ticks). Values
        // above 10 hours are the old 100x-corrupted records; scale them down.
        int val = (itemData['trackDuration'] as num?)?.toInt() ?? 0;
        if (val > 360000000000) {
          val = val ~/ 100;
        } else {
          val = val * 10000;
        }
        runTimeTicks = val;
      }

      // Parse artist IDs from saved data
      final rawArtistIds = itemData['trackArtistIds'];
      final artistIds = (rawArtistIds is List)
          ? rawArtistIds.whereType<String>().toList()
          : <String>[];

      // The full artist list (newer records); older records only kept the
      // display string, which can read "X & N more".
      final rawArtists = itemData['trackArtists'];
      final artists = (rawArtists is List)
          ? rawArtists.whereType<String>().toList()
          : <String>[];

      final track = JellyfinTrack(
        id: trackId,
        name: itemData['trackName'] as String? ?? 'Unknown Track',
        artists: artists.isNotEmpty
            ? artists
            : [itemData['trackArtist'] as String? ?? 'Unknown Artist'],
        artistIds: artistIds,
        album: itemData['trackAlbum'] as String?,
        albumId: itemData['trackAlbumId'] as String?,
        albumPrimaryImageTag: itemData['trackAlbumPrimaryImageTag'] as String?,
        runTimeTicks: runTimeTicks,
        container: itemData['trackContainer'] as String?,
        codec: itemData['trackCodec'] as String?,
        bitrate: (itemData['trackBitrate'] as num?)?.toInt(),
        sampleRate: (itemData['trackSampleRate'] as num?)?.toInt(),
        bitDepth: (itemData['trackBitDepth'] as num?)?.toInt(),
        channels: (itemData['trackChannels'] as num?)?.toInt(),
        productionYear: (itemData['trackProductionYear'] as num?)?.toInt(),
        serverUrl: _nonEmpty(itemData['serverUrl']),
        userId: _nonEmpty(itemData['userId']),
      );
      return DownloadItem.fromJson(itemData, track);
    } catch (e) {
      debugPrint('Skipping invalid download record for $trackId: $e');
      return null;
    }
  }

  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  Future<void> _loadDownloads() async {
    try {
      final box = _box;
      if (box == null) {
        debugPrint('Hive box not initialized');
        return;
      }

      String? rootPath = _rootPath;
      if (rootPath == null) {
        try {
          rootPath = (await _downloadsRoot()).absolute.path;
        } catch (e) {
          debugPrint('DownloadService: downloads root unavailable at load: $e');
        }
      }

      // Current format: one record per track.
      final records = <String, dynamic>{};
      for (final key in box.keys) {
        if (key is String && key.startsWith(_recordPrefix)) {
          records[key.substring(_recordPrefix.length)] = box.get(key);
        }
      }
      final storedIds = records.keys.toSet();

      // Legacy format: the whole map under one key. Per-track records win;
      // the legacy key is deleted after its records have been rewritten.
      final legacy = box.get(_downloadsKey);
      if (legacy != null) {
        _legacyRecordPending = true;
        if (legacy is Map) {
          for (final entry in legacy.entries) {
            final id = entry.key;
            if (id is String && !records.containsKey(id)) {
              records[id] = entry.value;
            }
          }
        }
      }

      final restoredQueue = <DownloadItem>[];
      final session = jellyfinService.session;

      for (final entry in records.entries) {
        final trackId = entry.key;
        final isStored = storedIds.contains(trackId);
        // A stored record we don't keep as-is must be rewritten or deleted.
        if (isStored) _persisted[trackId] = null;

        final value = entry.value;
        if (value is! Map) {
          debugPrint('Skipping invalid download entry for $trackId');
          continue;
        }
        var item = _itemFromRecord(trackId, Map<String, dynamic>.from(value));
        if (item == null) continue;
        if (!_demoModeEnabled && item.isDemoAsset) continue;
        // Entries created in memory before load finished win.
        if (_downloads.containsKey(trackId)) continue;

        var needsResave = !isStored;

        // Stored paths are relative to the downloads root; legacy records
        // hold absolute paths from a possibly stale app container.
        final stored = item.localPath;
        if (rootPath != null && stored.isNotEmpty) {
          final resolved = DownloadPaths.resolve(stored, rootPath);
          if (stored != DownloadPaths.toRelative(stored, rootPath: rootPath)) {
            needsResave = true; // migrate record to the relative form
          }
          if (resolved != stored) item = item.copyWith(localPath: resolved);
        }

        if (session != null && !session.isDemo && !item.isDemoAsset) {
          final hydrated = _hydrateTrack(item.track, session);
          if (_accountFieldsChanged(item.track, hydrated)) needsResave = true;
          item = item.copyWith(track: hydrated);
        }

        if (item.isDownloading || item.isPaused) {
          // The app was killed mid-download: the transfer is gone (stale
          // .tmp files are removed by verifyAndCleanupDownloads). Queue it
          // again.
          item = item.copyWith(
            status: DownloadStatus.queued,
            progress: 0.0,
            downloadedBytes: 0,
          );
          needsResave = true;
        }

        _downloads[trackId] = item;
        if (isStored && !needsResave) _persisted[trackId] = item;
        if (item.isQueued) restoredQueue.add(item);
      }

      // Re-enqueue restored work in its original order.
      restoredQueue.sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
      final inQueue = _downloadQueue.toSet();
      for (final item in restoredQueue) {
        if (inQueue.add(item.track.id)) _downloadQueue.add(item.track.id);
      }
      if (restoredQueue.isNotEmpty) {
        debugPrint('DownloadService: restored ${restoredQueue.length} queued download(s)');
      }
      if (session != null) _hydratedSession = session;

      _loadCompleted = true;
      _scheduleSave(); // no-op write if nothing changed
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading downloads: $e');
    } finally {
      _loadCompleted = true;
      if (_saveAfterLoad) {
        _saveAfterLoad = false;
        _scheduleSave();
      }
    }
  }

  /// Request a save. Writes are debounced (and capped at [_saveMaxDelay]
  /// under continuous activity) and only touch records that changed, so a
  /// 500-track batch no longer rewrites the whole library 500 times.
  /// Returns immediately; use [flushPendingSave] to force a write.
  Future<void> _saveDownloads() {
    _scheduleSave();
    return Future<void>.value();
  }

  void _scheduleSave() {
    if (_disposed) return;
    final now = DateTime.now();
    final since = _saveDirtySince ??= now;
    final overdue = now.difference(since) >= _saveMaxDelay;
    _saveTimer?.cancel();
    _saveTimer = Timer(overdue ? Duration.zero : _saveDebounce, () {
      _saveTimer = null;
      unawaited(flushPendingSave());
    });
  }

  /// Write pending changes now (called when the app is backgrounded, since
  /// iOS may terminate a suspended app without further notice).
  Future<void> flushPendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _saveDirtySince = null;
    return _saveCoalesced();
  }

  // Single-flight coalescer: only one write runs at a time; work arriving
  // meanwhile triggers exactly one follow-up write with the final state.
  Future<void>? _savePending;
  bool _saveDirty = false;

  Future<void> _saveCoalesced() async {
    if (_savePending != null) {
      _saveDirty = true;
      return _savePending;
    }
    final fut = _runSave();
    _savePending = fut;
    try {
      await fut;
    } finally {
      _savePending = null;
    }
    if (_saveDirty) {
      _saveDirty = false;
      return _saveCoalesced();
    }
  }

  Map<String, dynamic> _recordFor(DownloadItem item) {
    final json = item.toJson();
    // Paths are stored relative to the downloads root so they survive
    // app-container moves.
    json['localPath'] = _toStoredPath(item.localPath);
    return json;
  }

  Future<void> _runSave() async {
    final box = _box;
    if (box == null) {
      debugPrint('Hive box not initialized, cannot save');
      return;
    }
    if (!_loadCompleted) {
      // Saving now could clobber stored records with a partial map.
      _saveAfterLoad = true;
      return;
    }

    final changed = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      if (!identical(_persisted[entry.key], entry.value)) {
        changed['$_recordPrefix${entry.key}'] = _recordFor(entry.value);
      }
    }
    final removed = <String>[
      for (final id in _persisted.keys)
        if (!_downloads.containsKey(id)) '$_recordPrefix$id',
    ];
    final dropLegacy = _legacyRecordPending;
    if (changed.isEmpty && removed.isEmpty && !dropLegacy) return;

    // Snapshot before any await: later mutations are picked up by the next
    // save's identity diff.
    final snapshot = Map<String, DownloadItem?>.of(_downloads);
    try {
      if (changed.isNotEmpty) await box.putAll(changed);
      if (removed.isNotEmpty) await box.deleteAll(removed);
      if (dropLegacy) {
        await box.delete(_downloadsKey);
        _legacyRecordPending = false;
      }
      _persisted = snapshot;
    } catch (e) {
      debugPrint('Error saving downloads: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_saveTimer != null) unawaited(flushPendingSave());
      case AppLifecycleState.resumed:
        // iOS suspends the app ~30s after backgrounding unless audio plays;
        // transfers cut off meanwhile fail with a network error and are
        // re-queued. Retry right away instead of waiting out the backoff.
        if (_queuePause == DownloadQueuePause.waitingForNetwork) {
          _networkRetryTimer?.cancel();
          _networkRetryTimer = null;
        }
        if (_downloadQueue.isNotEmpty) _resumeRestoredQueue();
    }
  }

  // ---------------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------------

  /// Remove stale .tmp files left by interrupted downloads. Skips files that
  /// belong to a download currently in flight in this process.
  Future<void> _cleanupStaleTmpFiles() async {
    try {
      final downloadsDir = await _downloadsRoot();
      if (!await downloadsDir.exists()) return;
      await for (final entity in downloadsDir.list()) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          final name = entity.uri.pathSegments.last;
          final ownerId = name.split('_').first;
          if (_activeTokens.containsKey(ownerId)) continue;
          debugPrint('Cleaning up stale tmp file: ${entity.path}');
          await entity.delete();
        }
      }
      // Image temp files (artwork/, artists/) from an interrupted write. A
      // fetch may be writing one right now, so only old ones are removed.
      final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
      for (final name in const ['artwork', 'artists']) {
        final dir = Directory('${downloadsDir.path}/$name');
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File || !entity.path.endsWith('.tmp')) continue;
          try {
            if ((await entity.lastModified()).isBefore(cutoff)) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('Error cleaning up tmp files: $e');
    }
  }

  /// Delete album artwork for [albumIds] that no remaining download
  /// (any status) references. Artwork is stored per album, not per track.
  Future<void> _deleteUnreferencedArtwork(Iterable<String> albumIds) async {
    final pending = albumIds.toSet();
    if (pending.isEmpty) return;
    for (final d in _downloads.values) {
      pending.remove(d.track.albumId ?? d.track.id);
      if (pending.isEmpty) return;
    }
    for (final albumId in pending) {
      try {
        final artworkFile = File(await _getArtworkPath(albumId));
        if (await artworkFile.exists()) {
          await artworkFile.delete();
          debugPrint('Deleted orphaned artwork for album: $albumId');
        }
      } catch (e) {
        debugPrint('Error cleaning artwork for $albumId: $e');
      }
    }
  }

  /// Delete artist images no remaining completed download references.
  Future<void> _deleteUnreferencedArtistImages(Iterable<String> artistIds) async {
    for (final artistId in artistIds.toSet()) {
      if (_artistIdIndex[artistId]?.isNotEmpty ?? false) continue;
      try {
        final file = File(await _getArtistImagePath(artistId));
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Error cleaning artist image for $artistId: $e');
      }
    }
  }

  /// Verify all downloaded files exist and clean up orphaned references
  Future<void> verifyAndCleanupDownloads() async {
    await _cleanupStaleTmpFiles();
    if (_rootPath == null) {
      // Without the downloads root, stored (relative) paths can't be
      // resolved: every file would look missing and every record would be
      // dropped. Verify on a later launch instead.
      debugPrint('DownloadService: downloads root unavailable; skipping verification');
      return;
    }
    debugPrint('Verifying download files...');
    final toRemove = <String>{};  // Use Set to prevent duplicates
    bool pathsUpdated = false;

    // Stat files in parallel batches: sequential awaits cost seconds on a
    // library with thousands of downloads.
    final completed = [
      for (final entry in _downloads.entries)
        if (entry.value.isCompleted) entry,
    ];
    const batchSize = 32;
    final missing = <MapEntry<String, DownloadItem>>[];
    for (var i = 0; i < completed.length; i += batchSize) {
      final batch = completed.sublist(i, min(i + batchSize, completed.length));
      final exists = await Future.wait(batch.map((e) async {
        try {
          return await File(e.value.localPath).exists();
        } catch (_) {
          return false;
        }
      }));
      for (var j = 0; j < batch.length; j++) {
        if (!exists[j]) missing.add(batch[j]);
      }
    }

    for (final entry in missing) {
      final trackId = entry.key;
      final item = entry.value;
      // Changed or deleted while we were checking: leave it alone.
      if (!identical(_downloads[trackId], item)) continue;

      // The legacy Documents/downloads migration may not have finished
      // (e.g. interrupted, or a file failed to move): use the legacy
      // copy until the next launch retries the move.
      final legacyPath = await _findInLegacyRoot(item.localPath);
      if (!identical(_downloads[trackId], item)) continue;
      if (legacyPath != null) {
        debugPrint('Using legacy download path for ${item.track.name}: $legacyPath');
        _downloads[trackId] = item.copyWith(localPath: legacyPath);
        pathsUpdated = true;
        continue;
      }

      debugPrint('Missing file for track: ${item.track.name} (${item.localPath})');
      toRemove.add(trackId);
    }

    if (pathsUpdated) {
      notifyListeners();
      await _saveDownloads();
    }

    // Remove orphaned entries (batch operation)
    if (toRemove.isNotEmpty) {
      debugPrint('Cleaning up ${toRemove.length} orphaned download(s)');
      final affectedAlbums = <String>[];
      for (final trackId in toRemove) {
        final removed = _downloads.remove(trackId);
        _demoDownloadIds.remove(trackId);  // Also remove from demo set
        if (removed != null) {
          _removeFromIndexes(removed.track);
          affectedAlbums.add(removed.track.albumId ?? removed.track.id);
        }
      }
      // Artwork is keyed by album id; only delete it when no remaining
      // download references that album.
      await _deleteUnreferencedArtwork(affectedAlbums);
      notifyListeners();
      await _saveDownloads();
      debugPrint('Cleanup complete');
    } else {
      debugPrint('All download files verified OK');
    }
  }

  /// Verify a specific download file exists
  Future<bool> verifyDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null || !item.isCompleted) return false;

    final file = File(item.localPath);
    return await file.exists();
  }

  /// `<root>/<trackId>_<sanitized name>.<ext>`. The name is truncated so the
  /// file name (plus the `.<micros>.tmp` suffix) stays under iOS's 255-byte
  /// limit for long classical titles.
  String _pathFor(Directory root, JellyfinTrack track, String ext) {
    var sanitizedName = track.name.replaceAll(_unsafeNameChars, '').trim();
    if (sanitizedName.length > _maxNameLength) {
      sanitizedName = sanitizedName.substring(0, _maxNameLength).trim();
    }
    return File('${root.path}/${track.id}_$sanitizedName.$ext').absolute.path;
  }

  Future<String> _getDownloadPath(JellyfinTrack track, {String? extension}) async {
    final downloadsDir = await _downloadsRoot();

    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    return _pathFor(
      downloadsDir,
      track,
      extension ?? DownloadFormat.fallbackExtension,
    );
  }

  /// Get artwork path - uses albumId to avoid duplicating same album art for every track
  Future<String> _getArtworkPath(String albumId) async {
    final root = await _downloadsRoot();
    final artworkDir = Directory('${root.path}/artwork');

    if (!await artworkDir.exists()) {
      await artworkDir.create(recursive: true);
    }

    return File('${artworkDir.path}/$albumId.jpg').absolute.path;
  }

  /// Get artwork path for a track (uses its albumId)
  Future<String?> getArtworkPathForTrack(String trackId) async {
    final item = _downloads[trackId];
    if (item == null) return null;
    final albumId = item.track.albumId ?? item.track.id;
    return _getArtworkPath(albumId);
  }

  /// Whether an image file is present and non-empty (an interrupted write
  /// from an older version could leave an empty file behind).
  static Future<bool> _hasImageFile(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Write [bytes] to [path] through a temporary file and a rename, so a
  /// reader (or a crash) never sees a partial image.
  static Future<void> _writeFileAtomically(String path, List<int> bytes) async {
    final tmp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Returns true if artwork is present (already cached or newly fetched).
  /// Tracks of one album finishing together share one fetch.
  Future<bool> _downloadArtwork(JellyfinTrack track) {
    final albumId = track.albumId ?? track.id;
    final inFlight = _artworkFetches[albumId];
    if (inFlight != null) return inFlight;
    final fetch = _fetchArtwork(track, albumId);
    _artworkFetches[albumId] = fetch;
    return fetch.whenComplete(() => _artworkFetches.remove(albumId));
  }

  Future<bool> _fetchArtwork(JellyfinTrack track, String albumId) async {
    try {
      final artworkUrl = track.artworkUrl();
      if (artworkUrl == null) return false;

      // Use albumId for artwork storage to avoid duplicates
      final artworkPath = await _getArtworkPath(albumId);
      if (await _hasImageFile(File(artworkPath))) {
        return true; // Already cached for this album
      }

      final response = await _httpClient
          .get(Uri.parse(artworkUrl))
          .timeout(_imageFetchTimeout);
      if (response.statusCode == 200) {
        // Validate response is actually an image before caching
        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.startsWith('image/') || response.bodyBytes.isEmpty) {
          debugPrint('Artwork response is not an image ($contentType), skipping');
          return false;
        }
        await _writeFileAtomically(artworkPath, response.bodyBytes);
        debugPrint('Artwork cached for album: $albumId');
        return true;
      }
    } catch (e) {
      debugPrint('Failed to cache artwork for ${track.name}: $e');
    }
    return false;
  }

  /// Get artist image path - stores artist images by artist ID
  Future<String> _getArtistImagePath(String artistId) async {
    final root = await _downloadsRoot();
    final artistImageDir = Directory('${root.path}/artists');

    if (!await artistImageDir.exists()) {
      await artistImageDir.create(recursive: true);
    }

    return File('${artistImageDir.path}/$artistId.jpg').absolute.path;
  }

  /// Download artist image for offline use. Returns true if newly fetched.
  Future<bool> _downloadArtistImage(String artistId) async {
    try {
      final artistImagePath = await _getArtistImagePath(artistId);
      final file = File(artistImagePath);

      if (await _hasImageFile(file)) {
        return false; // Already cached for this artist
      }

      // Build artist image URL using Jellyfin service
      final imageUrl = jellyfinService.buildImageUrl(
        itemId: artistId,
        maxWidth: 400,
      );

      final response = await _httpClient
          .get(
            Uri.parse(imageUrl),
            headers: jellyfinService.imageHeaders(),
          )
          .timeout(_imageFetchTimeout);
      final contentType = response.headers['content-type'] ?? '';
      if (response.statusCode == 200 &&
          contentType.startsWith('image/') &&
          response.bodyBytes.isNotEmpty) {
        await _writeFileAtomically(artistImagePath, response.bodyBytes);
        debugPrint('Artist image cached for: $artistId');
        return true;
      }
    } catch (e) {
      debugPrint('Failed to cache artist image for $artistId: $e');
    }
    return false;
  }

  /// Best-effort artwork + artist image fetch after a download completed.
  /// Never blocks completion; each request times out after 15s.
  Future<void> _fetchImagesForTrack(JellyfinTrack track) async {
    var fetchedAny = await _downloadArtwork(track);
    for (final artistId in track.artistIds) {
      if (_disposed) return;
      if (await _downloadArtistImage(artistId)) fetchedAny = true;
    }
    if (_disposed) return;
    if (!_downloads.containsKey(track.id)) {
      // Deleted while the images were being fetched: don't leave images
      // behind that no download references.
      await _deleteUnreferencedArtwork([track.albumId ?? track.id]);
      await _deleteUnreferencedArtistImages(track.artistIds);
      return;
    }
    // Image files are addressed by album/artist id, not stored in records;
    // notify so offline artwork widgets reload.
    if (fetchedAny) _throttledNotify();
  }

  /// Get artist image file for offline display
  Future<File?> getArtistImageFile(String artistId) async {
    final path = await _getArtistImagePath(artistId);
    final file = File(path);
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// Extract actual duration from downloaded audio file
  Future<Duration?> _extractAudioDuration(String filePath) async {
    AudioPlayer? player;
    try {
      player = AudioPlayer();
      await player.setSourceDeviceFile(filePath);

      // Wait for duration to be available (with timeout)
      Duration? duration;
      for (int i = 0; i < 10; i++) {
        duration = await player.getDuration();
        if (duration != null) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }

      return duration;
    } catch (e) {
      debugPrint('Failed to extract audio duration from $filePath: $e');
      return null;
    } finally {
      await player?.dispose();
    }
  }

  /// Decoded length of a downloaded file, or null (probe failed or took
  /// longer than [_durationProbeTimeout]).
  Future<Duration?> _probeDuration(String path) async {
    try {
      return await _extractAudioDuration(path).timeout(_durationProbeTimeout);
    } on TimeoutException {
      debugPrint('Duration probe timed out for $path');
      return null;
    }
  }

  /// Extract the waveform of a finished download, one file at a time.
  void _queueWaveform(String trackId, String path) {
    final waveforms = WaveformService.instance;
    if (!waveforms.isAvailable) return;
    _waveformChain = _waveformChain.then((_) async {
      if (_disposed || !(_downloads[trackId]?.isCompleted ?? false)) return;
      final subscription =
          waveforms.extractWaveform(trackId, path).listen(null);
      try {
        await subscription.asFuture<void>().timeout(_waveformTimeout);
      } on TimeoutException {
        // Stop the extraction (not just stop waiting for it) so the next
        // file never decodes in parallel with this one.
        debugPrint('Waveform extraction timed out for $trackId');
        await subscription
            .cancel()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      } catch (e) {
        debugPrint('Waveform extraction failed for $trackId: $e');
      }
    });
  }

  Future<File?> getArtworkFile(String trackId) async {
    // Look up the track to get its albumId (artwork is stored by album, not track)
    final item = _downloads[trackId];
    if (item == null) return null;

    final albumId = item.track.albumId ?? item.track.id;
    final path = await _getArtworkPath(albumId);
    final file = File(path);
    if (await file.exists()) {
      return file;
    }
    return null;
  }

  /// Get artwork file directly by album ID (for album-level offline lookup).
  /// Unlike getArtworkFile(trackId), this does not require a track download entry.
  Future<File?> getArtworkFileByAlbumId(String albumId) async {
    final path = await _getArtworkPath(albumId);
    final file = File(path);
    if (await file.exists()) return file;
    return null;
  }

  Future<void> _simulateDemoDownload(JellyfinTrack track) async {
    if (_downloads[track.id]?.isCompleted ?? false) {
      return;
    }
    final bytes = _demoAudioBytes;
    if (bytes == null) {
      debugPrint('Demo audio bytes missing; cannot simulate download.');
      return;
    }

    final localPath = await _getDownloadPath(track, extension: 'wav');
    final startTime = DateTime.now();

    _downloads[track.id] = DownloadItem(
      track: track,
      localPath: localPath,
      status: DownloadStatus.downloading,
      progress: 0.0,
      queuedAt: startTime,
      isDemoAsset: true,
      owners: {'demo'}, // Add 'demo' as owner for simulated downloads
    );
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 800));

    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    final current = _downloads[track.id];
    if (current == null) return; // deleted while simulating
    _downloads[track.id] = current.copyWith(
      status: DownloadStatus.completed,
      progress: 1.0,
      totalBytes: bytes.length,
      downloadedBytes: bytes.length,
      completedAt: DateTime.now(),
      isDemoAsset: true,
      owners: {'demo'}, // Add 'demo' as owner for simulated downloads
      fileSizeBytes: bytes.length,
    );
    _demoDownloadIds.add(track.id);
    _addToIndexes(track);
    notifyListeners();
    await _saveDownloads();
  }

  // ---------------------------------------------------------------------------
  // Queueing
  // ---------------------------------------------------------------------------

  Future<void> downloadTrack(JellyfinTrack track, {String? ownerId}) async {
    await downloadTracks([track], ownerId: ownerId);
  }

  /// Queue [tracks] for download in order, with [ownerId] (album/playlist
  /// id) recorded as an owner. Tracks already downloaded or in progress just
  /// gain the owner; failed ones are retried. One notification and one
  /// (debounced) save for the whole batch. Returns the number newly queued.
  Future<int> downloadTracks(
    Iterable<JellyfinTrack> tracks, {
    String? ownerId,
  }) async {
    final list = tracks.toList(growable: false);
    if (list.isEmpty) return 0;

    var changed = false;
    final toQueue = <JellyfinTrack>[];
    final seen = <String>{};
    for (final track in list) {
      if (!seen.add(track.id)) continue;
      final existing = _downloads[track.id];
      if (existing != null && !existing.isFailed) {
        if (ownerId != null && !existing.owners.contains(ownerId)) {
          _downloads[track.id] =
              existing.copyWith(owners: {...existing.owners, ownerId});
          changed = true;
        }
        continue;
      }
      toQueue.add(track);
    }

    if (_demoModeEnabled) {
      if (changed) {
        notifyListeners();
        await _saveDownloads();
      }
      for (final track in toQueue) {
        await _simulateDemoDownload(track);
      }
      return toQueue.length;
    }

    Directory? root;
    if (toQueue.isNotEmpty) {
      try {
        root = await _downloadsRoot();
      } catch (e) {
        debugPrint('DownloadService: downloads root unavailable: $e');
      }
    }

    var queued = 0;
    final now = DateTime.now();
    final inQueue = _downloadQueue.toSet();
    for (final track in toQueue) {
      // Re-check after the await above: a concurrent call may have queued it.
      final existing = _downloads[track.id];
      if (existing != null && !existing.isFailed) continue;
      _downloads[track.id] = DownloadItem(
        track: track,
        localPath: root == null
            ? ''
            : _pathFor(root, track, DownloadFormat.fallbackExtension),
        status: DownloadStatus.queued,
        // Strictly increasing so the batch keeps its order after a restart.
        queuedAt: now.add(Duration(microseconds: queued)),
        owners: {...?existing?.owners, ?ownerId},
      );
      _networkFailures.remove(track.id);
      if (inQueue.add(track.id)) _downloadQueue.add(track.id);
      queued++;
      changed = true;
    }

    if (changed) {
      notifyListeners();
      await _saveDownloads();
    }
    if (queued > 0) {
      // A new request from the user is worth another try after a storage
      // error (space may have been freed).
      if (_queuePause == DownloadQueuePause.storageFull) {
        _setQueuePause(DownloadQueuePause.none);
      }
      _resumeRestoredQueue();
    }
    return queued;
  }

  /// Fetch an album's tracks and queue them. Returns the number queued.
  Future<int> downloadAlbum(JellyfinAlbum album) async {
    if (!_albumBatchInFlight.add(album.id)) {
      debugPrint('downloadAlbum: batch already in flight for ${album.id}');
      return 0;
    }
    try {
      final tracks = await jellyfinService.loadAlbumTracks(albumId: album.id);
      return await downloadTracks(tracks, ownerId: album.id);
    } catch (e) {
      debugPrint('Error downloading album: $e');
      return 0;
    } finally {
      _albumBatchInFlight.remove(album.id);
    }
  }

  /// Queue every track in a playlist for download, guarded against duplicate
  /// concurrent calls (rapid double-tap on the playlist download button).
  /// Returns the number of tracks newly queued.
  Future<int> downloadPlaylist({
    required String playlistId,
    required List<JellyfinTrack> tracks,
  }) async {
    if (!_playlistBatchInFlight.add(playlistId)) {
      debugPrint('downloadPlaylist: batch already in flight for $playlistId');
      return 0;
    }
    try {
      return await downloadTracks(tracks, ownerId: playlistId);
    } finally {
      _playlistBatchInFlight.remove(playlistId);
    }
  }

  Future<void> _processQueue() async {
    if (_disposed || !_loadCompleted) return;
    if (_downloadQueue.isEmpty) {
      if (_activeDownloads == 0) _onQueueDrained();
      return;
    }
    if (_activeDownloads >= _maxConcurrentDownloads) return;
    if (_queuePause == DownloadQueuePause.storageFull) return;
    // Backing off after a network error: the retry timer resumes the queue.
    if (_queuePause == DownloadQueuePause.waitingForNetwork &&
        _networkRetryTimer != null) {
      return;
    }
    final currentSession = jellyfinService.session;
    if (currentSession == null) {
      _resumeRestoredQueue(); // waits for the session
      return;
    }
    // Only other accounts' downloads are left: they wait (queued) for that
    // account to sign in again, so for this session the queue has drained.
    if (_activeDownloads == 0 && _onlyOtherAccountsQueued(currentSession)) {
      _onQueueDrained();
      return;
    }

    // Check WiFi status if WiFi-only downloads is enabled
    if (!await _canProceedWithDownload()) return;
    if (_storageLimitReached()) {
      debugPrint('Download queue paused: storage limit reached');
      _setQueuePause(DownloadQueuePause.storageLimit);
      return;
    }
    if (!await _hasNetworkTransport()) {
      // Airplane mode: wait for a connectivity event (or app resume).
      _setQueuePause(DownloadQueuePause.waitingForNetwork);
      return;
    }
    if (_disposed) return;
    // Every blocking condition was re-checked above: the queue can run.
    if (_queuePause != DownloadQueuePause.none) {
      _setQueuePause(DownloadQueuePause.none);
    }

    final session = jellyfinService.session;
    if (session == null) return;
    final limit = _networkProbe ? 1 : _maxConcurrentDownloads;
    // Downloads queued under another server or user stay queued (in order)
    // until that account signs in again; they are never sent to this one.
    final deferred = <String>[];
    var next = 0;
    while (_activeDownloads < limit && next < _downloadQueue.length) {
      final trackId = _downloadQueue[next++];
      final item = _downloads[trackId];
      if (item == null || !item.isQueued || _activeTokens.containsKey(trackId)) {
        continue; // dropped below
      }
      if (!session.isDemo && !_belongsTo(item.track, session)) {
        deferred.add(trackId);
        continue;
      }
      // Start download (unawaited, but increments _activeDownloads synchronously)
      unawaited(_startDownload(trackId));
    }
    // Remove what was consumed from the head in one pass; foreign items go
    // back in front, in their original order.
    _downloadQueue
      ..removeRange(0, next)
      ..insertAll(0, deferred);
  }

  /// Whether every download still queued belongs to another account than
  /// [session] (and at least one does).
  bool _onlyOtherAccountsQueued(JellyfinSession session) {
    if (session.isDemo) return false;
    var foreign = false;
    for (final id in _downloadQueue) {
      final item = _downloads[id];
      if (item == null || !item.isQueued) continue; // dropped by the queue
      if (_belongsTo(item.track, session)) return false;
      foreign = true;
    }
    return foreign;
  }

  /// The queue emptied: post a summary and reset per-batch state.
  void _onQueueDrained() {
    _networkProbe = false;
    _consecutiveNetworkFailures = 0;
    if (_queuePause != DownloadQueuePause.none) {
      _setQueuePause(DownloadQueuePause.none);
    }
    if (_batchCompleted == 0 && _batchFailed == 0) return;
    final body = _batchFailed == 0
        ? '$_batchCompleted downloaded'
        : '$_batchCompleted downloaded, $_batchFailed failed';
    _batchCompleted = 0;
    _batchFailed = 0;
    unawaited(_notificationService?.showComplete(
      title: 'Downloads finished',
      body: body,
    ));
  }

  /// Back off before retrying after a network error: 5s, 10s, 20s … 2 min.
  void _scheduleNetworkRetry() {
    _networkProbe = true;
    _setQueuePause(DownloadQueuePause.waitingForNetwork);
    // Several in-flight transfers failing together count as one round.
    if (_networkRetryTimer != null) return;
    _consecutiveNetworkFailures++;
    final delay = networkRetryDelay(_consecutiveNetworkFailures);
    debugPrint('Downloads waiting for network; retrying in ${delay.inSeconds}s');
    _networkRetryTimer = Timer(delay, () {
      _networkRetryTimer = null;
      unawaited(_processQueue());
    });
  }

  /// Open the transfer for [track]. Originals AVPlayer can decode come from
  /// `/Items/{id}/Download` (the untouched file); formats it can't (Opus,
  /// Vorbis, WMA, APE, …) are fetched through `/Audio/{id}/universal`,
  /// which transcodes them to 320 kbps MP3 so they play offline. When the
  /// user lacks the "Allow media downloading" permission (403), the
  /// universal endpoint is used as a fallback.
  Future<_DownloadSource> _openDownloadStream(
    JellyfinTrack original,
    Completer<void> cancelToken,
  ) async {
    final session = jellyfinService.session;
    final track = (session != null && !session.isDemo)
        ? _hydrateTrack(original, session)
        : original;
    String? universalUrl;
    if (session != null && track.streamUrlOverride == null) {
      try {
        universalUrl = track.originalQualityStreamUrl(deviceId: session.deviceId);
      } catch (_) {
        universalUrl = null;
      }
    }

    Future<_DownloadSource> viaUniversal(String url) async {
      final response = await _send(url, cancelToken);
      return _DownloadSource(
        response,
        viaUniversal: true,
        extension: DownloadFormat.extensionFor(
          contentType: response.headers['content-type'],
          contentDisposition: response.headers['content-disposition'],
        ),
      );
    }

    if (!track.isAvPlayerNativeFormat && universalUrl != null) {
      return viaUniversal(universalUrl);
    }

    final url = track.downloadUrl(jellyfinService.baseUrl, jellyfinService.token);
    final response = await _send(url, cancelToken);
    if (response.statusCode == 403 && universalUrl != null) {
      debugPrint('Download endpoint forbidden for ${track.name}; using stream endpoint');
      _discard(response);
      return viaUniversal(universalUrl);
    }
    final extension = DownloadFormat.extensionFor(
      contentType: response.headers['content-type'],
      contentDisposition: response.headers['content-disposition'],
      container: track.container,
    );
    if (response.statusCode == 200 &&
        universalUrl != null &&
        !DownloadFormat.isOfflinePlayableExtension(extension)) {
      // Codec metadata was missing or wrong and the original turned out to
      // be a format AVPlayer can't play: fetch the transcode instead.
      debugPrint('Original of ${track.name} is .$extension; using transcode');
      _discard(response);
      return viaUniversal(universalUrl);
    }
    return _DownloadSource(response, viaUniversal: false, extension: extension);
  }

  /// GET [url]. Completing [cancelToken] aborts the request (also while
  /// waiting for headers); no headers within [_connectTimeout] aborts it too.
  Future<http.StreamedResponse> _send(
    String url,
    Completer<void> cancelToken,
  ) async {
    final request = http.AbortableRequest(
      'GET',
      Uri.parse(url),
      abortTrigger: cancelToken.future,
    );
    try {
      return await _httpClient.send(request).timeout(_connectTimeout);
    } on TimeoutException {
      if (!cancelToken.isCompleted) cancelToken.complete();
      rethrow;
    }
  }

  /// Close a response we won't read. Cancelling (instead of draining) stops
  /// the transfer, so an unwanted full-length body isn't downloaded.
  void _discard(http.StreamedResponse response) {
    try {
      unawaited(response.stream.listen(null, onError: (_) {}).cancel()
          .catchError((_) {}));
    } catch (_) {}
  }

  /// Stop an in-flight transfer (if any) for [trackId].
  void _cancelActive(String trackId) {
    final token = _activeTokens.remove(trackId);
    if (token != null && !token.isCompleted) token.complete();
  }

  void _cancelAllActive() {
    for (final token in _activeTokens.values) {
      if (!token.isCompleted) token.complete();
    }
    _activeTokens.clear();
  }

  Future<void> _startDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null) return;

    _activeDownloads++;

    // Cancellation token: deleting/cancelling a download removes and
    // completes it; that aborts the HTTP request and the transfer loop exits
    // cleanly without writing any state back.
    final cancelToken = Completer<void>();
    _activeTokens[trackId] = cancelToken;
    bool isCancelled() =>
        !identical(_activeTokens[trackId], cancelToken) ||
        !_downloads.containsKey(trackId);
    void throwIfCancelled() {
      if (isCancelled()) throw const _DownloadCancelled();
    }

    _downloads[trackId] = item.copyWith(
      status: DownloadStatus.downloading,
      progress: 0.0,
      downloadedBytes: 0,
      clearErrorKind: true,
    );
    // queued -> downloading doesn't change the completed/failed sets.
    _notifyProgress();

    // Hoisted so the catch block can clean up the actual tmp file even when the
    // detected extension differs from item.localPath's extension.
    String? activeTmpPath;
    IOSink? sink;
    Future<void> closeSink() async {
      final s = sink;
      sink = null;
      if (s == null) return;
      try {
        await s.close();
      } catch (e) {
        debugPrint('DownloadService: closing partial file failed: $e');
      }
    }

    // Final file renamed into place but not yet recorded as completed.
    String? unownedFinalPath;
    Future<void> deleteUnownedFinal() async {
      final path = unownedFinalPath;
      unownedFinalPath = null;
      if (path == null) return;
      // A newer attempt for the same track may already own this path.
      final current = _downloads[trackId];
      if (current != null && current.isCompleted && current.localPath == path) {
        return;
      }
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('DownloadService: unrecorded file cleanup failed: $e');
      }
    }

    Future<void> deleteTmp() async {
      // Only the tmp file this attempt created; never a path another attempt
      // for the same track might be writing.
      final cleanupPath = activeTmpPath;
      if (cleanupPath == null) return;
      try {
        final tmpFile = File(cleanupPath);
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (e) {
        debugPrint('DownloadService: partial temp cleanup failed: $e');
      }
    }

    try {
      final source = await _openDownloadStream(item.track, cancelToken);
      final response = source.response;

      if (response.statusCode != 200) {
        _discard(response);
        throw _HttpStatusException(response.statusCode);
      }
      final contentType = response.headers['content-type'];
      if (!isAcceptableDownloadContentType(contentType)) {
        // e.g. a reverse-proxy login page answered with 200: not audio.
        _discard(response);
        throw _UnexpectedContentException(contentType ?? '');
      }
      throwIfCancelled();

      final extension = source.extension;

      // Get correct path with detected extension
      final correctPath = await _getDownloadPath(item.track, extension: extension);
      throwIfCancelled();

      // Update item with correct path if it changed
      if (correctPath != _downloads[trackId]!.localPath) {
        _downloads[trackId] = _downloads[trackId]!.copyWith(localPath: correctPath);
      }

      // Write to temp file first, then atomic rename to prevent corrupt partial
      // files. The tmp name is unique per attempt so a cancelled transfer can
      // never clobber a fresh re-download of the same track.
      final tmpPath =
          '$correctPath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      activeTmpPath = tmpPath;
      final tmpFile = File(tmpPath);
      sink = tmpFile.openWrite();
      final totalBytes = response.contentLength ?? 0;
      int downloadedBytes = 0;
      int unflushedBytes = 0;
      final throttle = ProgressThrottle();

      // No-progress timeout: fires when no chunk arrives within the duration,
      // so a server that sends headers but stalls the body can't hold a
      // download slot forever. (No onTimeout callback: an exception thrown
      // from one is reported to the zone, not delivered to the stream.)
      final stalledStream = response.stream.timeout(_stallTimeout);

      // Throwing inside the loop cancels the stream subscription, which
      // aborts the HTTP transfer. Chunks are buffered by the IOSink (no
      // per-chunk flush).
      await for (final chunk in stalledStream) {
        throwIfCancelled();
        sink!.add(chunk);
        downloadedBytes += chunk.length;
        unflushedBytes += chunk.length;
        if (unflushedBytes >= _flushInterval) {
          // Backpressure (the stream is paused while awaiting) so a slow
          // disk can't make the sink buffer the whole file in memory, and a
          // write error (disk full) surfaces now rather than at close().
          unflushedBytes = 0;
          await sink!.flush();
        }

        if (_networkProbe) {
          // Data is flowing again: lift the single-download probe.
          _networkProbe = false;
          _consecutiveNetworkFailures = 0;
          unawaited(_processQueue());
        }

        if (!throttle.shouldEmit(downloadedBytes, totalBytes)) continue;

        // Use -1.0 for indeterminate progress when Content-Length is unknown
        // (transcodes).
        final progress = totalBytes > 0 ? downloadedBytes / totalBytes : -1.0;
        _downloads[trackId] = _downloads[trackId]!.copyWith(
          progress: progress,
          totalBytes: totalBytes,
          downloadedBytes: downloadedBytes,
        );
        _throttledNotify();
      }

      await sink!.close();
      sink = null;
      throwIfCancelled();
      if (totalBytes > 0 && downloadedBytes < totalBytes) {
        // Connection closed early without an error: don't keep a truncated
        // file as a finished download.
        throw HttpException(
          'Connection closed after $downloadedBytes of $totalBytes bytes',
        );
      }
      // Atomic rename: only moves the file to final path after fully written
      await tmpFile.rename(correctPath);
      activeTmpPath = null;
      // From here until the download is marked completed, a cancellation or
      // failure must delete the final file too (no record would own it).
      unownedFinalPath = correctPath;
      throwIfCancelled();

      // Get file size and cache it to avoid repeated file I/O in getTotalDownloadSize
      final fileSize = await File(correctPath).length();
      throwIfCancelled();

      // A transcode of unknown length has no byte count to check: compare
      // its decoded length with the server's instead, before accepting it.
      final expectedTicks = _downloads[trackId]!.track.runTimeTicks ?? 0;
      Duration? probed;
      var probeAttempted = false;
      if (source.viaUniversal && totalBytes <= 0 && expectedTicks > 0) {
        probeAttempted = true;
        probed = await _probeDuration(correctPath);
        throwIfCancelled();
        final probedTicks = (probed?.inMicroseconds ?? 0) * 10;
        if (isLikelyTruncated(
          probedTicks: probedTicks,
          expectedTicks: expectedTicks,
        )) {
          final attempts = (_truncatedAttempts[trackId] ?? 0) + 1;
          if (attempts < _maxTruncatedAttempts) {
            _truncatedAttempts[trackId] = attempts;
            throw _TruncatedDownloadException(probedTicks, expectedTicks);
          }
          // Consistently short: the server's length is probably wrong.
          // Keep the file (its probed length replaces the server's below).
          debugPrint('Keeping short transcode of ${item.track.name} after '
              '$attempts attempts');
        }
      }

      // Completion: the audio is on disk. Everything after this point
      // (duration probe, images, lyrics, waveform) is best-effort and must
      // not be able to lose a finished download.
      _downloads[trackId] = _downloads[trackId]!.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        totalBytes: totalBytes > 0 ? totalBytes : fileSize,
        downloadedBytes: downloadedBytes,
        completedAt: DateTime.now(),
        fileSizeBytes: fileSize,
        clearErrorKind: true,
      );
      unownedFinalPath = null;
      _networkFailures.remove(trackId);
      _truncatedAttempts.remove(trackId);
      _consecutiveNetworkFailures = 0;
      _batchCompleted++;
      _addToIndexes(_downloads[trackId]!.track);
      // The transfer is over: drop the token now so pausing or re-queueing
      // in-flight transfers can never touch this finished download.
      if (identical(_activeTokens[trackId], cancelToken)) {
        _activeTokens.remove(trackId);
      }
      notifyListeners();
      await _saveDownloads();
      debugPrint('Download completed: ${item.track.name} ($extension)');

      // Duration probe, images, lyrics and waveform run off the download
      // slot, one track at a time.
      _queuePostCompletion(
        trackId,
        correctPath,
        probed: probed,
        probe: !probeAttempted &&
            (source.viaUniversal ||
                (_downloads[trackId]?.track.runTimeTicks ?? 0) <= 0),
      );
    } on _DownloadCancelled {
      debugPrint('Download cancelled: ${item.track.name}');
      await closeSink();
      await deleteTmp();
      await deleteUnownedFinal();
    } catch (e) {
      await closeSink();
      await deleteTmp();
      await deleteUnownedFinal();
      if (isCancelled()) {
        // Deleted mid-transfer; the error is a side effect of cancellation.
        debugPrint('Download cancelled: ${item.track.name} ($e)');
      } else {
        _handleDownloadFailure(trackId, item, e);
      }
    } finally {
      await closeSink();
      if (identical(_activeTokens[trackId], cancelToken)) {
        _activeTokens.remove(trackId);
      }
      _activeDownloads--;
      unawaited(_processQueue());
    }
  }

  /// Best-effort work after a download completed, chained so only one
  /// duration probe (an AVPlayer) runs at a time and none holds a download
  /// slot. Skipped when the download was deleted or replaced meanwhile.
  void _queuePostCompletion(
    String trackId,
    String path, {
    required bool probe,
    Duration? probed,
  }) {
    bool stillCompleted() {
      final current = _downloads[trackId];
      return !_disposed &&
          current != null &&
          current.isCompleted &&
          current.localPath == path;
    }

    _postCompletionChain = _postCompletionChain.then((_) async {
      if (!stillCompleted()) return;
      var duration = probed;
      if (duration == null && probe) duration = await _probeDuration(path);
      if (!stillCompleted()) return;
      final current = _downloads[trackId]!;
      var track = current.track;
      final actualTicks = (duration?.inMicroseconds ?? 0) * 10;
      if (actualTicks > 0 && actualTicks != track.runTimeTicks) {
        track = track.copyWith(runTimeTicks: actualTicks);
        _downloads[trackId] = current.copyWith(track: track);
        notifyListeners();
        await _saveDownloads();
      }

      // Artwork + artist images: best-effort, time-bounded.
      unawaited(_fetchImagesForTrack(track));

      // Pre-cache lyrics for offline playback
      final lyrics = _lyricsService;
      if (lyrics != null) {
        unawaited(lyrics.getLyrics(track).then((_) {}).catchError(
          (Object e) {
            debugPrint('Lyrics pre-cache failed for ${track.name}: $e');
          },
        ));
      }

      _queueWaveform(trackId, path);
    }).catchError((Object e) {
      debugPrint('DownloadService: post-download work failed for $trackId: $e');
    });
  }

  /// Network errors re-queue the track and pause the queue until the
  /// network is back (retried with backoff); a track that keeps failing
  /// while the network is up is eventually marked failed. Other errors fail
  /// the track; running out of space also pauses the whole queue instead
  /// of failing every remaining track in turn.
  void _handleDownloadFailure(String trackId, DownloadItem item, Object e) {
    final kind = _classifyDownloadError(e);
    final current = _downloads[trackId] ?? item;
    if (current.isCompleted) return;
    debugPrint('Download failed for ${item.track.name} ($kind): $e');

    if (e is _TruncatedDownloadException) {
      // The network worked; the server's transcode ended early. Retry this
      // track later (end of the queue) without pausing the whole queue.
      _downloads[trackId] = current.copyWith(
        status: DownloadStatus.queued,
        progress: 0.0,
        downloadedBytes: 0,
        errorMessage: e.toString(),
        errorKind: DownloadErrorKind.network,
      );
      _downloadQueue
        ..remove(trackId)
        ..add(trackId);
      notifyListeners();
      unawaited(_saveDownloads());
      return;
    }

    if (kind == DownloadErrorKind.network) {
      final failures = (_networkFailures[trackId] ?? 0) + 1;
      _networkFailures[trackId] = failures;
      if (failures < _maxNetworkFailures) {
        _downloads[trackId] = current.copyWith(
          status: DownloadStatus.queued,
          progress: 0.0,
          downloadedBytes: 0,
          errorMessage: e.toString(),
          errorKind: DownloadErrorKind.network,
        );
        _downloadQueue.remove(trackId);
        _downloadQueue.insert(0, trackId);
        _scheduleNetworkRetry();
        notifyListeners();
        unawaited(_saveDownloads());
        return;
      }
    }

    _networkFailures.remove(trackId);
    _downloads[trackId] = current.copyWith(
      status: DownloadStatus.failed,
      progress: 0.0,
      errorMessage: e.toString(),
      errorKind: kind,
    );
    _batchFailed++;
    if (kind == DownloadErrorKind.storageFull) {
      _setQueuePause(DownloadQueuePause.storageFull);
    }
    notifyListeners();
    unawaited(_saveDownloads());
  }

  // ---------------------------------------------------------------------------
  // Deleting / cancelling
  // ---------------------------------------------------------------------------

  /// Remove [ids] regardless of owners: cancel in-flight transfers, drop the
  /// records, then delete files and now-unreferenced artwork. Returns the
  /// number of records removed.
  Future<int> _removeDownloads(Iterable<String> ids) async {
    final removed = <DownloadItem>[];
    final idSet = ids.toSet();
    // One pass over the queue (not a linear remove per id: cancelling a
    // several-thousand-track queue would be quadratic).
    _downloadQueue.removeWhere(idSet.contains);
    for (final id in idSet) {
      final item = _downloads.remove(id);
      _cancelActive(id);
      _demoDownloadIds.remove(id);
      _networkFailures.remove(id);
      _truncatedAttempts.remove(id);
      if (item == null) continue;
      if (item.isCompleted) _removeFromIndexes(item.track);
      removed.add(item);
    }
    if (removed.isEmpty) return 0;

    // Update the UI first; file deletion follows.
    notifyListeners();
    await _saveDownloads();

    final waveforms = WaveformService.instance;
    for (final item in removed) {
      if (item.isCompleted && item.localPath.isNotEmpty) {
        try {
          final file = File(item.localPath);
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('Error deleting ${item.localPath}: $e');
        }
        if (waveforms.isAvailable) {
          unawaited(waveforms.deleteWaveform(item.track.id).catchError((_) {}));
        }
      }
    }
    await _deleteUnreferencedArtwork(
      removed.map((d) => d.track.albumId ?? d.track.id),
    );
    await _deleteUnreferencedArtistImages(
      removed.expand((d) => d.track.artistIds),
    );

    // Freed space may lift a storage-limit pause.
    if (_queuePause == DownloadQueuePause.storageLimit &&
        !_storageLimitReached()) {
      _setQueuePause(DownloadQueuePause.none);
    }
    if (_downloadQueue.isNotEmpty) unawaited(_processQueue());
    debugPrint('Removed ${removed.length} download(s)');
    return removed.length;
  }

  /// Permanently delete downloads (any status, regardless of owners).
  Future<int> deleteDownloads(Iterable<String> trackIds) async {
    final ids = trackIds
        .where((id) => _downloads.containsKey(id) && !_operationLocks.contains(id))
        .toSet();
    if (ids.isEmpty) return 0;
    _operationLocks.addAll(ids);
    try {
      return await _removeDownloads(ids);
    } finally {
      _operationLocks.removeAll(ids);
    }
  }

  /// Release [ownerId]'s (album / playlist / artist) claim on [trackIds].
  /// Tracks left without an owner — including ones downloaded on their own,
  /// which have none — are deleted (or cancelled while queued or in
  /// progress). Tracks another album or playlist still owns are kept.
  Future<({int removed, int kept})> releaseDownloads(
    Iterable<String> trackIds,
    String ownerId,
  ) async {
    final ids = trackIds
        .where((id) => _downloads.containsKey(id) && !_operationLocks.contains(id))
        .toSet();
    if (ids.isEmpty) return (removed: 0, kept: 0);
    _operationLocks.addAll(ids);
    try {
      final toRemove = <String>[];
      var kept = 0;
      var ownersChanged = false;
      for (final id in ids) {
        final item = _downloads[id];
        if (item == null) continue;
        final owners = {...item.owners}..remove(ownerId);
        if (owners.isEmpty) {
          toRemove.add(id);
          continue;
        }
        kept++;
        if (owners.length != item.owners.length) {
          _downloads[id] = item.copyWith(owners: owners);
          ownersChanged = true;
        }
      }
      // _removeDownloads notifies and saves (including the owner changes).
      final removed = toRemove.isEmpty ? 0 : await _removeDownloads(toRemove);
      if (ownersChanged && removed == 0) {
        notifyListeners();
        await _saveDownloads();
      }
      return (removed: removed, kept: kept);
    } finally {
      _operationLocks.removeAll(ids);
    }
  }

  /// Permanently delete one download regardless of owners (e.g. from an
  /// "all downloads" list).
  Future<void> deleteDownload(String trackId) async {
    if (_operationLocks.contains(trackId)) {
      debugPrint('Delete blocked: operation in progress for $trackId');
      return;
    }
    await deleteDownloads([trackId]);
  }

  /// Cancel a queued/in-progress download or dismiss a failed one.
  Future<void> cancelDownload(String trackId) => deleteDownload(trackId);

  /// Cancel every queued and in-progress download.
  Future<int> cancelAllActive() => deleteDownloads(
        _downloads.values
            .where((d) => d.isQueued || d.isDownloading || d.isPaused)
            .map((d) => d.track.id)
            .toList(),
      );

  /// Dismiss every failed download.
  Future<int> clearFailed() =>
      deleteDownloads(failedDownloads.map((d) => d.track.id).toList());

  /// Delete every download (any status) of an album, regardless of owners.
  /// [albumId] matches `track.albumId`, or 'unknown' for tracks without one
  /// (the key used by [StorageStats.byAlbum]).
  Future<int> deleteAlbumDownloads(String albumId) => deleteDownloads(
        _downloads.values
            .where((d) => (d.track.albumId ?? 'unknown') == albumId)
            .map((d) => d.track.id)
            .toList(),
      );

  /// Delete every download (any status) whose display artist is
  /// [artistName], regardless of owners.
  Future<int> deleteArtistDownloads(String artistName) => deleteDownloads(
        _downloads.values
            .where((d) => d.track.displayArtist == artistName)
            .map((d) => d.track.id)
            .toList(),
      );

  Future<void> deleteDownloadReference(String trackId, String ownerId) async {
    // Prevent concurrent operations on same track
    if (_operationLocks.contains(trackId)) {
      debugPrint('Delete reference blocked: operation in progress for $trackId');
      return;
    }
    _operationLocks.add(trackId);

    try {
      final item = _downloads[trackId];
      if (item == null) return;

      final owners = {...item.owners}..remove(ownerId);
      if (owners.isEmpty) {
        // Last owner gone: cancel (queued/in-progress) or delete the file.
        await _removeDownloads([trackId]);
        debugPrint('No more owners for "${item.track.name}". Removed.');
      } else {
        _downloads[trackId] = item.copyWith(owners: owners);
        notifyListeners();
        await _saveDownloads();
        debugPrint('Track "${item.track.name}" still has owners. Not physically deleted.');
      }
    } finally {
      _operationLocks.remove(trackId);
    }
  }

  /// Clear all downloads - complete reset including orphaned files
  Future<void> clearAllDownloads() async {
    debugPrint('Starting complete downloads reset...');

    final items = _downloads.values.toList();

    // Clear all state (completing tokens aborts in-flight transfers)
    _cancelAllActive();
    _downloads.clear();
    _downloadQueue.clear();
    _demoDownloadIds.clear();
    _albumIndex.clear();
    _artistIndex.clear();
    _artistIdIndex.clear();
    _networkFailures.clear();
    _truncatedAttempts.clear();
    _networkRetryTimer?.cancel();
    _networkRetryTimer = null;
    _networkProbe = false;
    _consecutiveNetworkFailures = 0;
    _queuePause = DownloadQueuePause.none;
    notifyListeners();
    await _saveDownloads();

    for (final item in items) {
      if (item.localPath.isEmpty) continue;
      try {
        final file = File(item.localPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Error deleting track file: $e');
      }
    }

    Directory? root;
    try {
      root = await _downloadsRoot();
    } catch (e) {
      debugPrint('Error resolving downloads root: $e');
    }

    if (root != null) {
      // Delete entire artwork folder to handle any orphaned/corrupted artwork
      try {
        final artworkDir = Directory('${root.path}/artwork');
        if (await artworkDir.exists()) {
          await artworkDir.delete(recursive: true);
          debugPrint('Deleted artwork folder');
        }
      } catch (e) {
        debugPrint('Error clearing artwork folder: $e');
      }

      // Delete entire artists folder (artist images)
      try {
        final artistsDir = Directory('${root.path}/artists');
        if (await artistsDir.exists()) {
          await artistsDir.delete(recursive: true);
          debugPrint('Deleted artists folder');
        }
      } catch (e) {
        debugPrint('Error clearing artists folder: $e');
      }

      // Also scan for orphaned audio files not in our tracking
      try {
        if (await root.exists()) {
          await for (final entity in root.list()) {
            if (entity is File &&
                !entity.path.endsWith(DownloadMigration.markerName)) {
              // Delete audio files (not directories)
              try {
                await entity.delete();
                debugPrint('Deleted orphaned file: ${entity.path}');
              } catch (e) {
                debugPrint('Error deleting orphaned file: $e');
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error scanning for orphaned files: $e');
      }
    }

    notifyListeners();
    debugPrint('Downloads reset complete');
  }

  // ---------------------------------------------------------------------------
  // Retrying
  // ---------------------------------------------------------------------------

  /// Re-queue [ids] (failed, or stuck queued/paused records) at the head of
  /// the queue, in order. A user retry also lifts a network/storage pause.
  int _requeue(List<String> ids) {
    final requeued = <String>[];
    final requeuedSet = <String>{};
    for (final id in ids) {
      final item = _downloads[id];
      if (item == null ||
          item.isCompleted ||
          _activeTokens.containsKey(id) ||
          !requeuedSet.add(id)) {
        continue;
      }
      _downloads[id] = item.copyWith(
        status: DownloadStatus.queued,
        progress: 0.0,
        downloadedBytes: 0,
        clearErrorKind: true,
      );
      _networkFailures.remove(id);
      requeued.add(id);
    }
    if (requeued.isEmpty) return 0;
    _downloadQueue
      ..removeWhere(requeuedSet.contains)
      ..insertAll(0, requeued);
    if (_queuePause == DownloadQueuePause.storageFull ||
        _queuePause == DownloadQueuePause.waitingForNetwork) {
      _networkProbe = false;
      _consecutiveNetworkFailures = 0;
      _setQueuePause(DownloadQueuePause.none);
    }
    notifyListeners();
    unawaited(_saveDownloads());
    _resumeRestoredQueue();
    return requeued.length;
  }

  /// Retry a download that has not completed, right away. Works for failed
  /// downloads and for stuck queued/paused records (e.g. restored after iOS
  /// killed the app).
  Future<void> retryDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null || item.isCompleted) return;
    // Genuinely transferring right now in this process: nothing to do.
    if (_activeTokens.containsKey(trackId)) return;
    _requeue([trackId]);
  }

  /// Retry the given downloads (those that are not completed or running).
  int retryDownloads(Iterable<String> trackIds) => _requeue(trackIds.toList());

  /// Retry every failed download, oldest first.
  int retryAllFailed() {
    final failed = failedDownloads.toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return _requeue(failed.map((d) => d.track.id).toList());
  }

  /// Re-download [incompatibleDownloads] (formats AVPlayer can't play); the
  /// new transfer fetches a playable transcode. Keeps owners. Returns the
  /// number re-queued.
  Future<int> redownloadIncompatible() async {
    final items = incompatibleDownloads.toList();
    if (items.isEmpty) return 0;
    final ids = <String>[];
    for (final item in items) {
      if (!identical(_downloads[item.track.id], item)) continue;
      _removeFromIndexes(item.track);
      _downloads[item.track.id] = item.copyWith(
        status: DownloadStatus.failed,
        progress: 0.0,
        errorKind: DownloadErrorKind.unknown,
      );
      ids.add(item.track.id);
      try {
        final file = File(item.localPath);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Error deleting ${item.localPath}: $e');
      }
    }
    return _requeue(ids);
  }

  Future<String?> getLocalPath(String trackId) async {
    final item = _downloads[trackId];
    if (item != null && item.isCompleted) {
      final file = File(item.localPath);
      if (await file.exists()) {
        return item.localPath;
      }
    }
    return null;
  }

  Future<int> getTotalDownloadSize() async {
    int totalSize = 0;
    for (final item in completedDownloads) {
      // Use cached file size if available, otherwise fall back to file I/O
      if (item.fileSizeBytes != null) {
        totalSize += item.fileSizeBytes!;
      } else {
        try {
          final file = File(item.localPath);
          if (await file.exists()) {
            totalSize += await file.length();
          }
        } catch (e) {
          debugPrint('Error getting file size: $e');
        }
      }
    }
    return totalSize;
  }

  /// Get detailed storage statistics
  Future<StorageStats> getStorageStats() async {
    int totalBytes = 0;
    int trackCount = 0;
    final byAlbum = <String, int>{};
    final byArtist = <String, int>{};
    final albumNames = <String, String>{};

    for (final item in completedDownloads) {
      // Use cached file size if available, otherwise fall back to file I/O
      int fileSize;
      if (item.fileSizeBytes != null) {
        fileSize = item.fileSizeBytes!;
      } else {
        try {
          final file = File(item.localPath);
          if (await file.exists()) {
            fileSize = await file.length();
          } else {
            continue;
          }
        } catch (e) {
          debugPrint('Error getting file size for ${item.track.name}: $e');
          continue;
        }
      }

      totalBytes += fileSize;
      trackCount++;

      // Group by album
      final albumId = item.track.albumId ?? 'unknown';
      byAlbum[albumId] = (byAlbum[albumId] ?? 0) + fileSize;
      albumNames[albumId] = item.track.album ?? 'Unknown Album';

      // Group by artist
      final artistName = item.track.displayArtist;
      byArtist[artistName] = (byArtist[artistName] ?? 0) + fileSize;
    }

    final aux = await _auxiliaryStorageStats();

    return StorageStats(
      totalBytes: totalBytes,
      trackCount: trackCount,
      byAlbum: byAlbum,
      byArtist: byArtist,
      albumNames: albumNames,
      cacheBytes: aux.cacheBytes,
      cacheFileCount: aux.cacheFileCount,
      cachedTrackIds: aux.cachedTrackIds,
      waveformBytes: aux.waveformBytes,
      waveformFileCount: aux.waveformFileCount,
      chartBytes: aux.chartBytes,
      chartCount: aux.chartCount,
    );
  }

  // Last scan of the audio cache, waveform and chart directories (the
  // expensive part of [getStorageStats]).
  _AuxStorageStats? _auxStats;
  int _auxStatsRevision = -1;
  DateTime _auxStatsAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<_AuxStorageStats>? _auxStatsInFlight;
  static const _auxStatsMaxAge = Duration(seconds: 30);

  /// Cache, waveform and chart usage. Concurrent calls share one scan, and
  /// a call caused by downloads changing (new [revision]) reuses a recent
  /// scan, so a batch finishing track after track doesn't rescan those
  /// directories on every completion. Asking again at the same revision
  /// (an explicit refresh) rescans.
  Future<_AuxStorageStats> _auxiliaryStorageStats() {
    final inFlight = _auxStatsInFlight;
    if (inFlight != null) return inFlight;
    final cached = _auxStats;
    if (cached != null &&
        canReuseStorageScan(
          hasScan: true,
          scanRevision: _auxStatsRevision,
          currentRevision: _revision,
          age: DateTime.now().difference(_auxStatsAt),
          maxAge: _auxStatsMaxAge,
        )) {
      _auxStatsRevision = _revision;
      return Future.value(cached);
    }
    final revision = _revision;
    final scan = _scanAuxiliaryStorage().then((stats) {
      _auxStats = stats;
      _auxStatsRevision = revision;
      _auxStatsAt = DateTime.now();
      return stats;
    });
    _auxStatsInFlight = scan;
    return scan.whenComplete(() => _auxStatsInFlight = null);
  }

  Future<_AuxStorageStats> _scanAuxiliaryStorage() async {
    // Get cache stats from AudioCacheService
    int cacheBytes = 0;
    int cacheFileCount = 0;
    List<String> cachedTrackIds = [];

    try {
      // Ensure cache service is initialized
      await AudioCacheService.instance.initialize();
      final cacheStats = await AudioCacheService.instance.getCacheStats();
      cacheBytes = (cacheStats['totalSizeBytes'] as int?) ?? 0;
      cacheFileCount = (cacheStats['fileCount'] as int?) ?? 0;
      cachedTrackIds = await AudioCacheService.instance.getCachedTrackIds();
    } catch (e) {
      debugPrint('Error getting cache stats: $e');
    }

    // Get waveform stats
    int waveformBytes = 0;
    int waveformFileCount = 0;
    try {
      final waveformStats = await WaveformService.instance.getStorageStats();
      waveformBytes = (waveformStats['totalBytes'] as int?) ?? 0;
      waveformFileCount = (waveformStats['fileCount'] as int?) ?? 0;
    } catch (e) {
      debugPrint('Error getting waveform stats: $e');
    }

    // Get chart stats
    int chartBytes = 0;
    int chartCount = 0;
    try {
      final chartService = ChartCacheService.instance;
      if (!chartService.isInitialized) await chartService.initialize();
      chartBytes = await chartService.getTotalStorageBytes();
      chartCount = chartService.chartCount;
    } catch (e) {
      debugPrint('Error getting chart stats: $e');
    }

    return _AuxStorageStats(
      cacheBytes: cacheBytes,
      cacheFileCount: cacheFileCount,
      cachedTrackIds: cachedTrackIds,
      waveformBytes: waveformBytes,
      waveformFileCount: waveformFileCount,
      chartBytes: chartBytes,
      chartCount: chartCount,
    );
  }

  /// Check if storage limit is exceeded
  Future<bool> isStorageLimitExceeded() async => _storageLimitReached();

  /// Get remaining storage space before limit
  Future<int> getRemainingStorage() async {
    if (_storageLimitMB == 0) return -1; // Unlimited
    final limitBytes = _storageLimitMB * 1024 * 1024;
    return (limitBytes - completedBytes).clamp(0, limitBytes);
  }

  /// Cleanup downloads older than specified duration.
  /// Only deletes tracks with no owners, i.e. tracks downloaded one by one;
  /// album and playlist downloads are kept.
  Future<int> cleanupByAge(Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final toDelete = <String>[
      for (final item in completedDownloads)
        if (item.completedAt != null &&
            item.completedAt!.isBefore(cutoff) &&
            item.owners.isEmpty)
          item.track.id,
    ];
    final deletedCount = await deleteDownloads(toDelete);
    debugPrint('Cleaned up $deletedCount ownerless downloads older than ${maxAge.inDays} days');
    return deletedCount;
  }

  /// Cleanup downloads to free space, starting with oldest.
  /// Only deletes tracks with no owners (album/playlist downloads are kept).
  Future<int> cleanupToFreeSpace(int targetFreeMB) async {
    if (targetFreeMB <= 0) return 0;

    final targetFreeBytes = targetFreeMB * 1024 * 1024;
    int currentSize = completedBytes;
    final targetSize = (_storageLimitMB > 0 ? _storageLimitMB * 1024 * 1024 : currentSize) - targetFreeBytes;

    if (currentSize <= targetSize) return 0;

    // Sort by completion date (oldest first), only consider tracks with no owners
    final sortedDownloads = List<DownloadItem>.from(completedDownloads)
      ..removeWhere((item) => item.owners.isNotEmpty)
      ..sort((a, b) {
        final aDate = a.completedAt ?? DateTime(2000);
        final bDate = b.completedAt ?? DateTime(2000);
        return aDate.compareTo(bDate);
      });

    final toDelete = <String>[];
    for (final item in sortedDownloads) {
      if (currentSize <= targetSize) break;
      currentSize -= item.fileSizeBytes ?? item.totalBytes ?? 0;
      toDelete.add(item.track.id);
    }
    final deletedCount = await deleteDownloads(toDelete);

    debugPrint('Cleaned up $deletedCount ownerless downloads to free ${targetFreeMB}MB');
    return deletedCount;
  }

  /// Cleanup all downloads for a specific album
  /// Uses deleteDownloadReference to respect other owners (e.g., playlists)
  Future<int> cleanupAlbum(String albumId) async {
    final trackIds = trackIdsForAlbum(albumId).toList();
    int deletedCount = 0;
    for (final trackId in trackIds) {
      final item = _downloads[trackId];
      final hadOwner = item?.owners.contains(albumId) ?? false;
      await deleteDownloadReference(trackId, albumId);
      // Count as deleted if album was an owner (track may still exist if other owners)
      if (hadOwner) deletedCount++;
    }
    debugPrint('Removed album $albumId ownership from $deletedCount tracks');
    return deletedCount;
  }

  /// Cleanup all downloads for a specific artist
  /// Uses deleteDownloadReference to respect other owners (e.g., playlists)
  Future<int> cleanupArtist(String artistName) async {
    final trackIds = trackIdsForArtist(artistName).toList();
    int deletedCount = 0;
    for (final trackId in trackIds) {
      final item = _downloads[trackId];
      final hadOwner = item?.owners.contains(artistName) ?? false;
      await deleteDownloadReference(trackId, artistName);
      if (hadOwner) deletedCount++;
    }
    debugPrint('Removed artist $artistName ownership from $deletedCount tracks');
    return deletedCount;
  }

  /// Run auto-cleanup if enabled
  Future<int> runAutoCleanupIfEnabled() async {
    if (!_autoCleanupEnabled) return 0;
    return cleanupByAge(Duration(days: _autoCleanupDays));
  }

  /// Format bytes to human readable string (static utility)
  static String formatBytes(int bytes) => formatDownloadBytes(bytes);

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    // Persist anything still pending before tearing down.
    if (_saveTimer != null) {
      _saveTimer!.cancel();
      _saveTimer = null;
      unawaited(_saveCoalesced());
    }
    _disposed = true;
    _restoreKickTimer?.cancel();
    _notifyThrottle?.cancel();
    _networkRetryTimer?.cancel();
    _cancelAllActive();
    _connectivitySub?.cancel();
    _httpClient.close();
    super.dispose();
  }
}

/// Non-200 response to a download request.
class _HttpStatusException implements Exception {
  const _HttpStatusException(this.statusCode);

  final int statusCode;

  bool get isTransient =>
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  @override
  String toString() => 'Failed to download: HTTP $statusCode';
}

/// A `200 OK` download response whose content type is not audio.
class _UnexpectedContentException implements Exception {
  const _UnexpectedContentException(this.contentType);

  final String contentType;

  @override
  String toString() => 'Server did not send audio ($contentType)';
}

/// A transcode (no Content-Length) decoded shorter than the server's length.
class _TruncatedDownloadException implements Exception {
  const _TruncatedDownloadException(this.probedTicks, this.expectedTicks);

  final int probedTicks;
  final int expectedTicks;

  @override
  String toString() => 'Transcode ended early '
      '(${probedTicks ~/ 10000000}s of ${expectedTicks ~/ 10000000}s)';
}

/// Internal signal: the download was deleted/cancelled while in flight.
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
