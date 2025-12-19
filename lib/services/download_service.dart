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

class DownloadService extends ChangeNotifier {
  final JellyfinService jellyfinService;
  final Map<String, DownloadItem> _downloads = {};
  final List<String> _downloadQueue = [];
  bool _isDownloading = false;
  final int _maxConcurrentDownloads = 3;
  int _activeDownloads = 0;
  bool _demoModeEnabled = false;
  Uint8List? _demoAudioBytes;
  final Set<String> _demoDownloadIds = <String>{};

  static const _boxName = 'nautune_downloads';
  static const _downloadsKey = 'downloads';
  static bool _hiveInitialized = false;
  Box<dynamic>? _box;

  DownloadService({required this.jellyfinService}) {
    _initializeAndLoad();
  }

  Future<void> _initializeAndLoad() async {
    await _initHive();
    await _loadDownloads();
    await verifyAndCleanupDownloads();
  }

  Future<void> _initHive() async {
    if (!_hiveInitialized) {
      await Hive.initFlutter();
      _hiveInitialized = true;
    }
    _box = await Hive.openBox<dynamic>(_boxName);
  }

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

  int get totalDownloads => _downloads.length;
  int get completedCount => completedDownloads.length;
  int get activeCount => activeDownloads.length;
  bool get isDemoMode => _demoModeEnabled;

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
    Directory downloadsDir;
    
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      downloadsDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}downloads',
      );
    } else {
      // iOS/Android: MUST use app documents directory (sandbox requirement)
      final dir = await getApplicationDocumentsDirectory();
      downloadsDir = Directory('${dir.path}/downloads');
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

  Future<String> _getArtworkPath(String trackId) async {
    Directory downloadsDir;
    
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      downloadsDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}downloads/artwork',
      );
    } else {
      final dir = await getApplicationDocumentsDirectory();
      downloadsDir = Directory('${dir.path}/downloads/artwork');
    }
    
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    
    return File('${downloadsDir.path}/$trackId.jpg').absolute.path;
  }

  Future<void> _downloadArtwork(JellyfinTrack track) async {
    try {
      final artworkUrl = track.artworkUrl();
      if (artworkUrl == null) return;

      final artworkPath = await _getArtworkPath(track.id);
      final file = File(artworkPath);

      if (await file.exists()) {
        return; // Already cached
      }

      final response = await http.get(Uri.parse(artworkUrl));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        debugPrint('Artwork cached: ${track.name}');
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

    _processQueue();
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

  void _processQueue() {
    if (_isDownloading || _downloadQueue.isEmpty) return;
    
    while (_activeDownloads < _maxConcurrentDownloads && _downloadQueue.isNotEmpty) {
      final trackId = _downloadQueue.removeAt(0);
      final item = _downloads[trackId];
      if (item != null && item.isQueued) {
        _startDownload(trackId);
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
      _processQueue();
    }
  }

  Future<void> deleteDownload(String trackId) async {
    final item = _downloads[trackId];
    if (item == null) return;

    // This method is for permanently deleting a download regardless of owners
    // (e.g., from an "all downloads" list)
    // If there are owners, this implies a forced deletion.
    await _performDelete(trackId, item.localPath);
    _downloads.remove(trackId);
    _downloadQueue.remove(trackId);
    _demoDownloadIds.remove(trackId);
    
    notifyListeners();
    await _saveDownloads();
    
    debugPrint('Permanently deleted download: ${item.track.name}');
  }

  Future<void> deleteDownloadReference(String trackId, String ownerId) async {
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
        _downloads.remove(trackId);
        _demoDownloadIds.remove(trackId);
        debugPrint('Cancelled ${item.isQueued ? "queued" : "in-progress"} download: ${item.track.name}');
      } else {
        // Only delete file if download was completed
        await _performDelete(trackId, item.localPath);
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
  }

  Future<void> _performDelete(String trackId, String localPath) async {
    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted file: $localPath');
      }
      
      // Also delete cached artwork
      final artworkPath = await _getArtworkPath(trackId);
      final artworkFile = File(artworkPath);
      if (await artworkFile.exists()) {
        await artworkFile.delete();
        debugPrint('Deleted artwork: $artworkPath');
      }
    } catch (e) {
      debugPrint('Error during physical deletion of $trackId: $e');
    }
  }

  Future<void> clearAllDownloads() async {
    for (final item in completedDownloads) {
      // Intentionally call deleteDownload to force removal of all files
      // regardless of owner, as this is a "clear all" operation.
      await deleteDownload(item.track.id);
    }
    _demoDownloadIds.clear();
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
    
    _processQueue();
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
}
