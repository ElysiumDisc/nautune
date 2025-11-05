import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';

class DownloadService extends ChangeNotifier {
  final JellyfinService jellyfinService;
  final Map<String, DownloadItem> _downloads = {};
  final List<String> _downloadQueue = [];
  bool _isDownloading = false;
  int _maxConcurrentDownloads = 3;
  int _activeDownloads = 0;

  DownloadService({required this.jellyfinService}) {
    _loadDownloads().then((_) => verifyAndCleanupDownloads());
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

  Future<void> _loadDownloads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final downloadsJson = prefs.getString('downloads');
      if (downloadsJson != null) {
        final Map<String, dynamic> data = jsonDecode(downloadsJson);
        _downloads.clear();
        
        for (final entry in data.entries) {
          final itemData = entry.value as Map<String, dynamic>;
          final track = JellyfinTrack(
            id: entry.key,
            name: itemData['trackName'] as String,
            artists: [itemData['trackArtist'] as String],
            album: itemData['trackAlbum'] as String?,
            runTimeTicks: itemData['trackDuration'] != null
                ? (itemData['trackDuration'] as int) * 10
                : null,
          );
          
          final item = DownloadItem.fromJson(itemData, track);
          if (item != null) {
            _downloads[entry.key] = item;
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading downloads: $e');
    }
  }

  Future<void> _saveDownloads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{};
      for (final entry in _downloads.entries) {
        data[entry.key] = entry.value.toJson();
      }
      await prefs.setString('downloads', jsonEncode(data));
    } catch (e) {
      debugPrint('Error saving downloads: $e');
    }
  }

  /// Verify all downloaded files exist and clean up orphaned references
  Future<void> verifyAndCleanupDownloads() async {
    debugPrint('Verifying download files...');
    final toRemove = <String>[];
    
    for (final entry in _downloads.entries) {
      final trackId = entry.key;
      final item = entry.value;
      
      if (item.isCompleted) {
        final file = File(item.localPath);
        if (!await file.exists()) {
          debugPrint('Missing file for track: ${item.track.name}');
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
    
    // Remove orphaned entries
    for (final trackId in toRemove) {
      _downloads.remove(trackId);
    }
    
    if (toRemove.isNotEmpty) {
      debugPrint('Cleaned up ${toRemove.length} orphaned download(s)');
      notifyListeners();
      await _saveDownloads();
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
      // Desktop: use project directory for easy access
      downloadsDir = Directory('downloads');
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
    return '${downloadsDir.path}/${track.id}_$sanitizedName.$ext';
  }

  Future<String> _getArtworkPath(String trackId) async {
    Directory downloadsDir;
    
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      downloadsDir = Directory('downloads/artwork');
    } else {
      final dir = await getApplicationDocumentsDirectory();
      downloadsDir = Directory('${dir.path}/downloads/artwork');
    }
    
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    
    return '${downloadsDir.path}/$trackId.jpg';
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

  Future<void> downloadTrack(JellyfinTrack track) async {
    if (_downloads.containsKey(track.id)) {
      if (_downloads[track.id]!.isCompleted) {
        debugPrint('Track already downloaded: ${track.name}');
        return;
      }
      if (_downloads[track.id]!.isDownloading || _downloads[track.id]!.isQueued) {
        debugPrint('Track already in queue: ${track.name}');
        return;
      }
    }

    final localPath = await _getDownloadPath(track);
    final downloadItem = DownloadItem(
      track: track,
      localPath: localPath,
      status: DownloadStatus.queued,
      queuedAt: DateTime.now(),
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
        await downloadTrack(track);
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

      _downloads[trackId] = _downloads[trackId]!.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        completedAt: DateTime.now(),
      );
      
      // Download artwork after track completes
      await _downloadArtwork(item.track);
      
      notifyListeners();
      await _saveDownloads();
      
      debugPrint('Download completed: ${item.track.name} ($extension)');
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

    try {
      final file = File(item.localPath);
      if (await file.exists()) {
        await file.delete();
      }
      
      // Also delete cached artwork
      final artworkPath = await _getArtworkPath(trackId);
      final artworkFile = File(artworkPath);
      if (await artworkFile.exists()) {
        await artworkFile.delete();
      }
      
      _downloads.remove(trackId);
      _downloadQueue.remove(trackId);
      
      notifyListeners();
      await _saveDownloads();
      
      debugPrint('Deleted download: ${item.track.name}');
    } catch (e) {
      debugPrint('Error deleting download: $e');
    }
  }

  Future<void> clearAllDownloads() async {
    for (final item in completedDownloads) {
      await deleteDownload(item.track.id);
    }
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
