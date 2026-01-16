import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';
import 'audio_cache_service.dart';
import 'connectivity_service.dart';
import 'notification_service.dart';

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

  StorageStats({
    required this.totalBytes,
    required this.trackCount,
    required this.byAlbum,
    required this.byArtist,
    required this.albumNames,
    this.cacheBytes = 0,
    this.cacheFileCount = 0,
    this.cachedTrackIds = const [],
  });

  String get formattedTotal => _formatBytes(totalBytes);
  String get formattedCache => _formatBytes(cacheBytes);
  String get formattedCombined => _formatBytes(totalBytes + cacheBytes);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class DownloadService extends ChangeNotifier {
  final JellyfinService jellyfinService;
  final NotificationService? _notificationService;
  ConnectivityService? _connectivityService;
  final Map<String, DownloadItem> _downloads = {};
  final List<String> _downloadQueue = [];
  bool _isDownloading = false;
  int _maxConcurrentDownloads = 3; // Now configurable
  int _activeDownloads = 0;
  bool _demoModeEnabled = false;
  Uint8List? _demoAudioBytes;
  final Set<String> _demoDownloadIds = <String>{};

  // Download settings
  bool _wifiOnlyDownloads = false;
  int _storageLimitMB = 0; // 0 = unlimited
  bool _autoCleanupEnabled = false;
  int _autoCleanupDays = 30;
  bool _pausedForMobileData = false; // Track if downloads paused due to mobile data

  // Secondary indexes for O(1) album/artist lookups instead of O(n) scans
  final Map<String, Set<String>> _albumIndex = {}; // albumId -> Set<trackId>
  final Map<String, Set<String>> _artistIndex = {}; // artistName -> Set<trackId>

  static const _boxName = 'nautune_downloads';
  static const _downloadsKey = 'downloads';
  static bool _hiveInitialized = false;
  Box<dynamic>? _box;

  DownloadService({
    required this.jellyfinService,
    NotificationService? notificationService,
  }) : _notificationService = notificationService {
    _initializeAndLoad();
  }

  Future<void> _initializeAndLoad() async {
    await _initHive();
    await _loadDownloads();
    _rebuildIndexes(); // Build secondary indexes after loading
    await verifyAndCleanupDownloads();
  }

  Future<void> _initHive() async {
    if (!_hiveInitialized) {
      await Hive.initFlutter('nautune');
      _hiveInitialized = true;
    }
    _box = await Hive.openBox<dynamic>(_boxName);
  }

  /// Rebuild all secondary indexes from current downloads
  void _rebuildIndexes() {
    _albumIndex.clear();
    _artistIndex.clear();
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
  }

  // Lock to prevent race conditions between download and delete operations
  final Set<String> _operationLocks = {};

  List<DownloadItem> get downloads => _downloads.values.toList()
    ..sort((a, b) => b.queuedAt.compareTo(a.queuedAt));

  List<DownloadItem> get completedDownloads =>
      downloads.where((d) => d.isCompleted).toList();

  List<DownloadItem> get activeDownloads =>
      downloads.where((d) => d.isDownloading || d.isQueued).toList();

  bool isDownloaded(String trackId) =>
      _downloads[trackId]?.isCompleted ?? false;

  DownloadItem? getDownload(String trackId) => _downloads[trackId];

  JellyfinTrack? trackFor(String trackId) => _downloads[trackId]?.track;

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
  bool get isDemoMode => _demoModeEnabled;

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
      notifyListeners();
      unawaited(_processQueue()); // Resume any waiting downloads
    }
  }

  /// Update WiFi-only downloads setting
  void setWifiOnlyDownloads(bool value) {
    if (_wifiOnlyDownloads != value) {
      _wifiOnlyDownloads = value;
      notifyListeners();
    }
  }

  /// Update storage limit in MB (0 = unlimited)
  void setStorageLimitMB(int value) {
    if (_storageLimitMB != value) {
      _storageLimitMB = value;
      notifyListeners();
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
    if (changed) notifyListeners();
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
  }

  /// Set the connectivity service for WiFi-only checks
  void setConnectivityService(ConnectivityService service) {
    _connectivityService = service;
  }

  /// Check if downloads are paused due to mobile data
  bool get isPausedForMobileData => _pausedForMobileData;

  /// Check if we can proceed with download based on WiFi settings
  Future<bool> _canProceedWithDownload() async {
    if (!_wifiOnlyDownloads) return true;
    if (_connectivityService == null) return true;

    final isOnWifi = await _connectivityService!.isOnWifi();
    if (!isOnWifi) {
      _pausedForMobileData = true;
      debugPrint('Downloads paused: WiFi-only mode enabled but on mobile data');
      notifyListeners();
      return false;
    }

    if (_pausedForMobileData) {
      _pausedForMobileData = false;
      notifyListeners();
    }
    return true;
  }

  void _updateNotification() {
    final notificationService = _notificationService;
    if (notificationService == null) return;
    
    if (_activeDownloads == 0) {
       // Handled in _processQueue or finally block for completion
       return;
    }

    if (_activeDownloads == 1) {
       // Find the active one
       try {
         final activeItem = _downloads.values.firstWhere((d) => d.isDownloading);
         notificationService.showProgress(
            title: 'Downloading ${activeItem.track.name}',
            body: '${(activeItem.progress * 100).toInt()}%',
            progress: (activeItem.progress * 100).toInt(),
         );
       } catch (_) {
         // Fallback if state is inconsistent
       }
    } else {
       notificationService.showProgress(
          title: 'Downloading $_activeDownloads tracks',
          body: '$_activeDownloads active, ${_downloadQueue.length} queued',
          progress: null,
       );
    }
  }

  /// Resume downloads when WiFi becomes available
  Future<void> resumeIfOnWifi() async {
    if (!_wifiOnlyDownloads || !_pausedForMobileData) return;

    if (await _canProceedWithDownload()) {
      _pausedForMobileData = false;
      notifyListeners();
      await _processQueue();
    }
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
    );

    _demoDownloadIds.add(track.id);
    notifyListeners();
    await _saveDownloads();
  }

  Future<void> _loadDownloads() async {
    try {
      // Load from Hive
      final box = _box;
      if (box == null) {
        debugPrint('Hive box not initialized');
        return;
      }

      final raw = box.get(_downloadsKey);
      if (raw != null && raw is Map) {
        _downloads.clear();
        bool removedDemoEntries = false;

        for (final entry in raw.entries) {
          final trackId = entry.key as String;
          final dynamic value = entry.value;
          final Map<String, dynamic> itemData;
          
          if (value is Map) {
             itemData = Map<String, dynamic>.from(value);
          } else {
             debugPrint('Skipping invalid download entry for $trackId');
             continue;
          }

          // Fix duration loading logic
          int? runTimeTicks;
          if (itemData['runTimeTicks'] != null) {
            runTimeTicks = itemData['runTimeTicks'] as int;
          } else if (itemData['trackDuration'] != null) {
            // Legacy format: was stored as milliseconds
            // Need to convert to ticks (1 ms = 10,000 ticks)
            // But previous code might have multiplied by 10 (micros) or other errors
            // Apply heuristic healing if the value seems impossibly large (e.g. > 24 hours)
            int val = (itemData['trackDuration'] as int);
            
            // If it was already stored as ticks in the duration field by mistake
            if (val > 360000000000) { // > 10 hours
               // Heuristic: assume it's corrupted 100x or similar, scale down
               // But safest is to just treat it as ms -> ticks if it's small,
               // or leave it if it's already ticks-sized?
               // The user mentioned a 100x bug. Let's try to detect that.
               val = val ~/ 100;
            } else {
               // Standard conversion: ms -> ticks
               val = val * 10000;
            }
            runTimeTicks = val;
          }

          final track = JellyfinTrack(
            id: trackId,
            name: itemData['trackName'] as String,
            artists: [itemData['trackArtist'] as String],
            album: itemData['trackAlbum'] as String?,
            runTimeTicks: runTimeTicks,
            container: itemData['trackContainer'] as String?,
            codec: itemData['trackCodec'] as String?,
            bitrate: (itemData['trackBitrate'] as num?)?.toInt(),
            sampleRate: (itemData['trackSampleRate'] as num?)?.toInt(),
            bitDepth: (itemData['trackBitDepth'] as num?)?.toInt(),
            channels: (itemData['trackChannels'] as num?)?.toInt(),
          );

          final item = DownloadItem.fromJson(itemData, track);
          if (item != null) {
            if (!_demoModeEnabled && item.isDemoAsset) {
              removedDemoEntries = true;
              continue;
            }
            _downloads[trackId] = item;
          }
        }

        if (removedDemoEntries) {
          await _saveDownloads();
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading downloads: $e');
    }
  }



  Future<void> _saveDownloads() async {
    try {
      final box = _box;
      if (box == null) {
        debugPrint('Hive box not initialized, cannot save');
        return;
      }

      final data = <String, dynamic>{};
      for (final entry in _downloads.entries) {
        data[entry.key] = entry.value.toJson();
      }

      await box.put(_downloadsKey, data);
    } catch (e) {
      debugPrint('Error saving downloads: $e');
    }
  }

  /// Verify all downloaded files exist and clean up orphaned references
  Future<void> verifyAndCleanupDownloads() async {
    debugPrint('Verifying download files...');
    final toRemove = <String>{};  // Use Set to prevent duplicates
    bool pathsUpdated = false;

    for (final entry in _downloads.entries) {
      final trackId = entry.key;
      final item = entry.value;

      if (item.isCompleted) {
        final file = File(item.localPath);
        if (!await file.exists()) {
          // Attempt rescue for iOS path changes
          bool rescued = false;
          if (Platform.isIOS) {
            try {
              final filename = item.localPath.split(Platform.pathSeparator).last;
              final dir = await getApplicationDocumentsDirectory();
              // Reconstruct path: Documents/downloads/filename
              final newPath = '${dir.path}/downloads/$filename';
              final newFile = File(newPath);
              
              if (await newFile.exists()) {
                debugPrint('Rescued download path for ${item.track.name}: $newPath');
                _downloads[trackId] = item.copyWith(localPath: newPath);
                rescued = true;
                pathsUpdated = true;
              }
            } catch (e) {
              debugPrint('Failed to rescue iOS path for $trackId: $e');
            }
          }

          if (!rescued) {
            debugPrint('Missing file for track: ${item.track.name} (${item.localPath})');
            toRemove.add(trackId);

            // Also clean up artwork
            try {
              final artworkPath = await _getArtworkPath(trackId);
              final artworkFile = File(artworkPath);
              if (await artworkFile.exists()) {
                await artworkFile.delete();
              }
            } catch (e) {
              debugPrint('Error cleaning artwork: $e');
            }
          }
        }
      }
    }

    if (pathsUpdated) {
      await _saveDownloads();
      notifyListeners();
    }

    // Remove orphaned entries (batch operation)
    if (toRemove.isNotEmpty) {
      debugPrint('Cleaning up ${toRemove.length} orphaned download(s)');
      for (final trackId in toRemove) {
        _downloads.remove(trackId);
        _demoDownloadIds.remove(trackId);  // Also remove from demo set
      }
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

  Future<String> _getDownloadPath(JellyfinTrack track, {String? extension}) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory downloadsDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      downloadsDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}downloads',
      );
    } else {
      // iOS/Android: MUST use app documents directory (sandbox requirement)
      downloadsDir = Directory('${docsDir.path}/downloads');
    }
    
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    
    final sanitizedName = track.name.replaceAll(RegExp(r'[^\w\s-]'), '');
    // Use provided extension or default to flac (original quality)
    final ext = extension ?? 'flac';
    return File('${downloadsDir.path}/${track.id}_$sanitizedName.$ext')
        .absolute
        .path;
  }

  /// Get artwork path - uses albumId to avoid duplicating same album art for every track
  Future<String> _getArtworkPath(String albumId) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory artworkDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      artworkDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}downloads${Platform.pathSeparator}artwork',
      );
    } else {
      artworkDir = Directory('${docsDir.path}/downloads/artwork');
    }

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

  Future<void> _downloadArtwork(JellyfinTrack track) async {
    try {
      final artworkUrl = track.artworkUrl();
      if (artworkUrl == null) return;

      // Use albumId for artwork storage to avoid duplicates
      final albumId = track.albumId ?? track.id;
      final artworkPath = await _getArtworkPath(albumId);
      final file = File(artworkPath);

      if (await file.exists()) {
        return; // Already cached for this album
      }

      final response = await http.get(Uri.parse(artworkUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('Artwork cached for album: $albumId');
      }
    } catch (e) {
      debugPrint('Failed to cache artwork for ${track.name}: $e');
    }
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

  String? getArtworkPath(String trackId) {
    // Return cached artwork path if it exists
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final path = 'downloads/artwork/$trackId.jpg';
      if (File(path).existsSync()) {
        return path;
      }
    } else {
      // For mobile, we need async path, so this won't work perfectly
      // Better to use a Future getter or callback
      return null;
    }
    return null;
  }

  Future<File?> getArtworkFile(String trackId) async {
    final path = await _getArtworkPath(trackId);
    final file = File(path);
    if (await file.exists()) {
      return file;
    }
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

    _downloads[track.id] = _downloads[track.id]!.copyWith(
      status: DownloadStatus.completed,
      progress: 1.0,
      totalBytes: bytes.length,
      downloadedBytes: bytes.length,
      completedAt: DateTime.now(),
      isDemoAsset: true,
      owners: {'demo'}, // Add 'demo' as owner for simulated downloads
    );
    _demoDownloadIds.add(track.id);
    notifyListeners();
    await _saveDownloads();
  }

  Future<void> downloadTrack(JellyfinTrack track, {String? ownerId}) async {
    if (_downloads.containsKey(track.id)) {
      final existingItem = _downloads[track.id]!;
      if (existingItem.isCompleted) {
        // If already completed, just add the new owner and return
        if (ownerId != null && !existingItem.owners.contains(ownerId)) {
          existingItem.owners.add(ownerId);
          await _saveDownloads();
          notifyListeners();
          debugPrint('Added owner $ownerId to already downloaded track: ${track.name}');
        }
        debugPrint('Track already downloaded: ${track.name}');
        return;
      }
      if (existingItem.isDownloading || existingItem.isQueued) {
        // If in progress, just add the new owner and return
        if (ownerId != null && !existingItem.owners.contains(ownerId)) {
          existingItem.owners.add(ownerId);
          await _saveDownloads();
          notifyListeners();
          debugPrint('Added owner $ownerId to in-progress track: ${track.name}');
        }
        debugPrint('Track already in queue: ${track.name}');
        return;
      }
    }

    if (_demoModeEnabled) {
      await _simulateDemoDownload(track);
      return;
    }

    final localPath = await _getDownloadPath(track);
    final downloadItem = DownloadItem(
      track: track,
      localPath: localPath,
      status: DownloadStatus.queued,
      queuedAt: DateTime.now(),
      owners: ownerId != null ? {ownerId} : {}, // Initialize with ownerId if provided
    );

    _downloads[track.id] = downloadItem;
    _downloadQueue.add(track.id);
    notifyListeners();
    await _saveDownloads();

    unawaited(_processQueue());
  }

  Future<void> downloadAlbum(JellyfinAlbum album) async {
    try {
      final tracks = await jellyfinService.loadAlbumTracks(albumId: album.id);
      for (final track in tracks) {
        await downloadTrack(track, ownerId: album.id); // Pass album ID as owner
      }
    } catch (e) {
      debugPrint('Error downloading album: $e');
    }
  }

  Future<void> _processQueue() async {
    // Check if we just finished everything
    if (_activeDownloads == 0 && _downloadQueue.isEmpty) {
      if (_isDownloading) { // Was running
         _isDownloading = false;
         _notificationService?.showComplete(title: 'Downloads Finished', body: 'All downloads complete');
      }
      return;
    }
    
    // Mark as downloading if we have active items (or are about to start)
    if (_activeDownloads > 0) {
      _isDownloading = true;
    }

    // Check WiFi status if WiFi-only downloads is enabled
    if (!await _canProceedWithDownload()) {
      debugPrint('Download queue paused: waiting for WiFi connection');
      return;
    }

    while (_activeDownloads < _maxConcurrentDownloads && _downloadQueue.isNotEmpty) {
      final trackId = _downloadQueue.removeAt(0);
      final item = _downloads[trackId];
      if (item != null && item.isQueued) {
        // Start download (unawaited, but increments _activeDownloads synchronously)
        _startDownload(trackId);
        _isDownloading = true;
      }
    }
  }

  Future<void> _startDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null) return;

    _activeDownloads++;
    _isDownloading = true;

    _downloads[trackId] = item.copyWith(
      status: DownloadStatus.downloading,
      progress: 0.0,
    );
    notifyListeners();

    try {
      final url = item.track.downloadUrl(jellyfinService.baseUrl, jellyfinService.token);
      final response = await http.Client().send(http.Request('GET', Uri.parse(url)));
      
      if (response.statusCode != 200) {
        throw Exception('Failed to download: HTTP ${response.statusCode}');
      }

      // Detect file extension from Content-Type header
      String extension = 'flac'; // Default to FLAC
      final contentType = response.headers['content-type'];
      if (contentType != null) {
        if (contentType.contains('flac')) {
          extension = 'flac';
        } else if (contentType.contains('mp3') || contentType.contains('mpeg')) {
          extension = 'mp3';
        } else if (contentType.contains('m4a') || contentType.contains('mp4')) {
          extension = 'm4a';
        } else if (contentType.contains('ogg')) {
          extension = 'ogg';
        } else if (contentType.contains('opus')) {
          extension = 'opus';
        } else if (contentType.contains('wav')) {
          extension = 'wav';
        }
      }

      // Get correct path with detected extension
      final correctPath = await _getDownloadPath(item.track, extension: extension);
      
      // Update item with correct path if it changed
      if (correctPath != item.localPath) {
        _downloads[trackId] = item.copyWith(localPath: correctPath);
      }

      final file = File(correctPath);
      final sink = file.openWrite();
      final totalBytes = response.contentLength ?? 0;
      int downloadedBytes = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        
        final progress = totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
        _downloads[trackId] = _downloads[trackId]!.copyWith(
          progress: progress,
          totalBytes: totalBytes,
          downloadedBytes: downloadedBytes,
        );
        
        if (downloadedBytes % (500 * 1024) == 0 || progress == 1.0) {
          notifyListeners();
          _updateNotification();
        }
      }

      await sink.close();

      // Extract actual duration from downloaded file
      JellyfinTrack updatedTrack = item.track;
      final actualDuration = await _extractAudioDuration(correctPath);
      if (actualDuration != null) {
        final actualTicks = actualDuration.inMicroseconds * 10;
        updatedTrack = item.track.copyWith(runTimeTicks: actualTicks);
        debugPrint('Updated duration for ${item.track.name}: ${actualDuration.inSeconds}s (was ${item.track.duration?.inSeconds ?? 0}s)');
      }

      _downloads[trackId] = _downloads[trackId]!.copyWith(
        track: updatedTrack,
        status: DownloadStatus.completed,
        progress: 1.0,
        completedAt: DateTime.now(),
      );

      // Download artwork after track completes
      await _downloadArtwork(updatedTrack);

      notifyListeners();
      await _saveDownloads();

      debugPrint('Download completed: ${updatedTrack.name} ($extension)');
    } catch (e) {
      debugPrint('Download failed for ${item.track.name}: $e');
      _downloads[trackId] = item.copyWith(
        status: DownloadStatus.failed,
        errorMessage: e.toString(),
      );
      notifyListeners();
      await _saveDownloads();
    } finally {
      _activeDownloads--;
      if (_activeDownloads == 0) {
        _isDownloading = false;
      }
      unawaited(_processQueue());
    }
  }

  Future<void> deleteDownload(String trackId) async {
    // Prevent concurrent operations on same track
    if (_operationLocks.contains(trackId)) {
      debugPrint('⚠️ Delete blocked: operation in progress for $trackId');
      return;
    }
    _operationLocks.add(trackId);

    try {
      final item = _downloads[trackId];
      if (item == null) return;

      // This method is for permanently deleting a download regardless of owners
      // (e.g., from an "all downloads" list)
      // If there are owners, this implies a forced deletion.
      final deleted = await _performDelete(trackId, item);
      if (!deleted) {
        debugPrint('⚠️ Failed to delete files for ${item.track.name}');
      }

      _removeFromIndexes(item.track);
      _downloads.remove(trackId);
      _downloadQueue.remove(trackId);
      _demoDownloadIds.remove(trackId);

      notifyListeners();
      await _saveDownloads();

      debugPrint('Permanently deleted download: ${item.track.name}');
    } finally {
      _operationLocks.remove(trackId);
    }
  }

  Future<void> deleteDownloadReference(String trackId, String ownerId) async {
    // Prevent concurrent operations on same track
    if (_operationLocks.contains(trackId)) {
      debugPrint('⚠️ Delete reference blocked: operation in progress for $trackId');
      return;
    }
    _operationLocks.add(trackId);

    try {
      final item = _downloads[trackId];
      if (item == null) return;

      // Remove the owner ID
      item.owners.remove(ownerId);
      debugPrint('Removed owner "$ownerId" from track "${item.track.name}". Remaining owners: ${item.owners.length}');

      // If no more owners, proceed with removal
      if (item.owners.isEmpty) {
        // If download is queued or in progress, just remove from queue/map
        if (item.isQueued || item.isDownloading) {
          _downloadQueue.remove(trackId);
          _removeFromIndexes(item.track);
          _downloads.remove(trackId);
          _demoDownloadIds.remove(trackId);
          debugPrint('Cancelled ${item.isQueued ? "queued" : "in-progress"} download: ${item.track.name}');
        } else {
          // Only delete file if download was completed
          await _performDelete(trackId, item);
          _removeFromIndexes(item.track);
          _downloads.remove(trackId);
          _downloadQueue.remove(trackId);
          _demoDownloadIds.remove(trackId);
          debugPrint('No more owners for "${item.track.name}". Physically deleted.');
        }
        await _saveDownloads();
      } else {
        // If owners still exist, just save the updated item (with fewer owners)
        await _saveDownloads();
        debugPrint('Track "${item.track.name}" still has owners. Not physically deleted.');
      }

      notifyListeners();
    } finally {
      _operationLocks.remove(trackId);
    }
  }

  /// Perform physical deletion of track file and artwork (if no other tracks use it)
  /// Returns true if deletion succeeded, false otherwise
  Future<bool> _performDelete(String trackId, DownloadItem item) async {
    bool success = true;

    try {
      // Delete track file
      final file = File(item.localPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted file: ${item.localPath}');
      }

      // Only delete artwork if no other downloaded tracks share this album
      final albumId = item.track.albumId ?? item.track.id;
      final albumTrackIds = trackIdsForAlbum(albumId);

      // Remove current track from consideration (it's being deleted)
      final remainingTracks = albumTrackIds.where((id) => id != trackId).toList();

      if (remainingTracks.isEmpty) {
        // No other tracks from this album - safe to delete artwork
        final artworkPath = await _getArtworkPath(albumId);
        final artworkFile = File(artworkPath);
        if (await artworkFile.exists()) {
          await artworkFile.delete();
          debugPrint('Deleted artwork for album: $albumId');
        }
      } else {
        debugPrint('Keeping artwork for album $albumId (${remainingTracks.length} tracks remain)');
      }
    } catch (e) {
      debugPrint('Error during physical deletion of $trackId: $e');
      success = false;
    }

    return success;
  }

  /// Clear all downloads - complete reset including orphaned files
  Future<void> clearAllDownloads() async {
    debugPrint('🗑️ Starting complete downloads reset...');

    // First, delete all tracked downloads
    final trackedIds = _downloads.keys.toList();
    for (final trackId in trackedIds) {
      final item = _downloads[trackId];
      if (item != null) {
        try {
          final file = File(item.localPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (e) {
          debugPrint('Error deleting track file: $e');
        }
      }
    }

    // Clear all state
    _downloads.clear();
    _downloadQueue.clear();
    _demoDownloadIds.clear();
    _albumIndex.clear();
    _artistIndex.clear();

    // Delete entire artwork folder to handle any orphaned/corrupted artwork
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final Directory artworkDir;
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        artworkDir = Directory(
          '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}downloads${Platform.pathSeparator}artwork',
        );
      } else {
        artworkDir = Directory('${docsDir.path}/downloads/artwork');
      }

      if (await artworkDir.exists()) {
        await artworkDir.delete(recursive: true);
        debugPrint('Deleted artwork folder');
      }
    } catch (e) {
      debugPrint('Error clearing artwork folder: $e');
    }

    // Also scan for orphaned audio files not in our tracking
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final Directory downloadsDir;
      if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
        downloadsDir = Directory(
          '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}downloads',
        );
      } else {
        downloadsDir = Directory('${docsDir.path}/downloads');
      }

      if (await downloadsDir.exists()) {
        await for (final entity in downloadsDir.list()) {
          if (entity is File) {
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

    await _saveDownloads();
    notifyListeners();
    debugPrint('✅ Downloads reset complete');
  }

  Future<void> retryDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null || !item.isFailed) return;

    _downloads[trackId] = item.copyWith(
      status: DownloadStatus.queued,
      progress: 0.0,
      errorMessage: null,
    );
    
    _downloadQueue.add(trackId);
    notifyListeners();
    await _saveDownloads();

    unawaited(_processQueue());
  }

  String? getLocalPath(String trackId) {
    final item = _downloads[trackId];
    if (item != null && item.isCompleted) {
      final file = File(item.localPath);
      if (file.existsSync()) {
        return item.localPath;
      }
    }
    return null;
  }

  Future<int> getTotalDownloadSize() async {
    int totalSize = 0;
    for (final item in completedDownloads) {
      try {
        final file = File(item.localPath);
        if (await file.exists()) {
          totalSize += await file.length();
        }
      } catch (e) {
        debugPrint('Error getting file size: $e');
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
      try {
        final file = File(item.localPath);
        if (await file.exists()) {
          final fileSize = await file.length();
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
      } catch (e) {
        debugPrint('Error getting file size for ${item.track.name}: $e');
      }
    }

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
      debugPrint('📦 Storage stats: downloads=$totalBytes bytes ($trackCount tracks), cache=$cacheBytes bytes ($cacheFileCount files)');
    } catch (e) {
      debugPrint('⚠️ Error getting cache stats: $e');
    }

    return StorageStats(
      totalBytes: totalBytes,
      trackCount: trackCount,
      byAlbum: byAlbum,
      byArtist: byArtist,
      albumNames: albumNames,
      cacheBytes: cacheBytes,
      cacheFileCount: cacheFileCount,
      cachedTrackIds: cachedTrackIds,
    );
  }

  /// Check if storage limit is exceeded
  Future<bool> isStorageLimitExceeded() async {
    if (_storageLimitMB == 0) return false; // Unlimited
    final totalSize = await getTotalDownloadSize();
    return totalSize > _storageLimitMB * 1024 * 1024;
  }

  /// Get remaining storage space before limit
  Future<int> getRemainingStorage() async {
    if (_storageLimitMB == 0) return -1; // Unlimited
    final totalSize = await getTotalDownloadSize();
    final limitBytes = _storageLimitMB * 1024 * 1024;
    return (limitBytes - totalSize).clamp(0, limitBytes);
  }

  /// Cleanup downloads older than specified duration
  /// Only deletes tracks with no remaining owners (respects playlists, etc.)
  Future<int> cleanupByAge(Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final toDelete = <String>[];

    for (final item in completedDownloads) {
      final completedAt = item.completedAt;
      // Only consider tracks with no owners or just the auto-cleanup owner
      if (completedAt != null && completedAt.isBefore(cutoff)) {
        if (item.owners.isEmpty) {
          toDelete.add(item.track.id);
        } else {
          debugPrint('Skipping age cleanup for "${item.track.name}" - has ${item.owners.length} owners');
        }
      }
    }

    int deletedCount = 0;
    for (final trackId in toDelete) {
      await deleteDownload(trackId);
      deletedCount++;
    }

    debugPrint('Cleaned up $deletedCount ownerless downloads older than ${maxAge.inDays} days');
    return deletedCount;
  }

  /// Cleanup downloads to free space, starting with oldest
  /// Only deletes tracks with no remaining owners (respects playlists, etc.)
  Future<int> cleanupToFreeSpace(int targetFreeMB) async {
    if (targetFreeMB <= 0) return 0;

    final targetFreeBytes = targetFreeMB * 1024 * 1024;
    int currentSize = await getTotalDownloadSize();
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

    int deletedCount = 0;
    for (final item in sortedDownloads) {
      if (currentSize <= targetSize) break;

      final file = File(item.localPath);
      if (await file.exists()) {
        final fileSize = await file.length();
        await deleteDownload(item.track.id);
        currentSize -= fileSize;
        deletedCount++;
      }
    }

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
  static String formatBytes(int bytes) {
    return StorageStats._formatBytes(bytes);
  }
}
