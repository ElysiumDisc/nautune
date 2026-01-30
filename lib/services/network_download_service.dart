import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/network_channels.dart';
import '../models/network_channel.dart';

/// Download status for a network channel.
enum NetworkDownloadStatus {
  notDownloaded,
  downloading,
  downloaded,
  failed,
}

/// Tracks download state for a network channel.
class NetworkDownloadItem {
  final int channelNumber;
  final NetworkDownloadStatus status;
  final double progress;
  final String? audioPath;
  final String? imagePath;
  final DateTime? downloadedAt;
  final String? errorMessage;

  const NetworkDownloadItem({
    required this.channelNumber,
    required this.status,
    this.progress = 0.0,
    this.audioPath,
    this.imagePath,
    this.downloadedAt,
    this.errorMessage,
  });

  NetworkDownloadItem copyWith({
    int? channelNumber,
    NetworkDownloadStatus? status,
    double? progress,
    String? audioPath,
    String? imagePath,
    DateTime? downloadedAt,
    String? errorMessage,
  }) {
    return NetworkDownloadItem(
      channelNumber: channelNumber ?? this.channelNumber,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      audioPath: audioPath ?? this.audioPath,
      imagePath: imagePath ?? this.imagePath,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
        'channelNumber': channelNumber,
        'status': status.name,
        'progress': progress,
        'audioPath': audioPath,
        'imagePath': imagePath,
        'downloadedAt': downloadedAt?.toIso8601String(),
        'errorMessage': errorMessage,
      };

  factory NetworkDownloadItem.fromJson(Map<String, dynamic> json) {
    return NetworkDownloadItem(
      channelNumber: json['channelNumber'] as int,
      status: NetworkDownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => NetworkDownloadStatus.notDownloaded,
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      audioPath: json['audioPath'] as String?,
      imagePath: json['imagePath'] as String?,
      downloadedAt: json['downloadedAt'] != null
          ? DateTime.tryParse(json['downloadedAt'] as String)
          : null,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  bool get isDownloaded => status == NetworkDownloadStatus.downloaded;
  bool get isDownloading => status == NetworkDownloadStatus.downloading;
}

/// Storage statistics for network downloads.
class NetworkStorageStats {
  final int totalBytes;
  final int channelCount;
  final int audioBytes;
  final int imageBytes;

  const NetworkStorageStats({
    required this.totalBytes,
    required this.channelCount,
    required this.audioBytes,
    required this.imageBytes,
  });

  String get formattedTotal => _formatBytes(totalBytes);
  String get formattedAudio => _formatBytes(audioBytes);
  String get formattedImages => _formatBytes(imageBytes);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Listening stats for a network channel.
class NetworkChannelStats {
  final int channelNumber;
  final int playCount;
  final int listenTimeSeconds;
  final DateTime? lastPlayed;

  const NetworkChannelStats({
    required this.channelNumber,
    this.playCount = 0,
    this.listenTimeSeconds = 0,
    this.lastPlayed,
  });

  NetworkChannelStats copyWith({
    int? channelNumber,
    int? playCount,
    int? listenTimeSeconds,
    DateTime? lastPlayed,
  }) {
    return NetworkChannelStats(
      channelNumber: channelNumber ?? this.channelNumber,
      playCount: playCount ?? this.playCount,
      listenTimeSeconds: listenTimeSeconds ?? this.listenTimeSeconds,
      lastPlayed: lastPlayed ?? this.lastPlayed,
    );
  }

  Map<String, dynamic> toJson() => {
        'channelNumber': channelNumber,
        'playCount': playCount,
        'listenTimeSeconds': listenTimeSeconds,
        'lastPlayed': lastPlayed?.toIso8601String(),
      };

  factory NetworkChannelStats.fromJson(Map<String, dynamic> json) {
    return NetworkChannelStats(
      channelNumber: json['channelNumber'] as int,
      playCount: json['playCount'] as int? ?? 0,
      listenTimeSeconds: json['listenTimeSeconds'] as int? ?? 0,
      lastPlayed: json['lastPlayed'] != null
          ? DateTime.tryParse(json['lastPlayed'] as String)
          : null,
    );
  }

  /// Format listen time as human readable string.
  String get formattedListenTime {
    if (listenTimeSeconds < 60) return '${listenTimeSeconds}s';
    if (listenTimeSeconds < 3600) {
      final mins = listenTimeSeconds ~/ 60;
      final secs = listenTimeSeconds % 60;
      return '${mins}m ${secs}s';
    }
    final hours = listenTimeSeconds ~/ 3600;
    final mins = (listenTimeSeconds % 3600) ~/ 60;
    return '${hours}h ${mins}m';
  }
}

/// Service for downloading and managing network channel content offline.
///
/// Supports two modes:
/// - Auto-cache ON: Channels are automatically saved when played
/// - Auto-cache OFF: Streaming only, no local storage
class NetworkDownloadService extends ChangeNotifier {
  final Map<int, NetworkDownloadItem> _downloads = {};
  final Set<int> _downloadQueue = {};
  bool _isProcessingQueue = false;

  // Auto-cache mode setting
  bool _autoCacheEnabled = false;
  bool get autoCacheEnabled => _autoCacheEnabled;

  // Listening stats
  final Map<int, NetworkChannelStats> _channelStats = {};

  static const _boxName = 'nautune_network_downloads';
  static const _downloadsKey = 'downloads';
  static const _autoCacheKey = 'auto_cache_enabled';
  static const _statsKey = 'channel_stats';
  static bool _hiveInitialized = false;
  Box<dynamic>? _box;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  NetworkDownloadService() {
    _initializeAndLoad();
  }

  /// Wait for initialization to complete (for external callers)
  Future<void> initialize() async {
    if (_isInitialized) return;
    // Wait for _initializeAndLoad to complete
    while (!_isInitialized) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _initializeAndLoad() async {
    await _initHive();
    await _loadSettings();
    await _loadDownloads();
    await _loadStats();
    await _verifyDownloads();
    _isInitialized = true;
    notifyListeners();
  }

  Future<void> _initHive() async {
    if (!_hiveInitialized) {
      await Hive.initFlutter('nautune');
      _hiveInitialized = true;
    }
    _box = await Hive.openBox<dynamic>(_boxName);
  }

  Future<void> _loadSettings() async {
    if (_box == null) return;
    _autoCacheEnabled = _box!.get(_autoCacheKey, defaultValue: false) as bool;
  }

  Future<void> _loadDownloads() async {
    if (_box == null) return;

    final raw = _box!.get(_downloadsKey);
    if (raw is Map) {
      for (final entry in raw.entries) {
        try {
          final item = NetworkDownloadItem.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          _downloads[item.channelNumber] = item;
        } catch (e) {
          debugPrint('Failed to load network download: $e');
        }
      }
    }
  }

  Future<void> _saveDownloads() async {
    if (_box == null) return;

    final data = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      data[entry.key.toString()] = entry.value.toJson();
    }
    await _box!.put(_downloadsKey, data);
  }

  Future<void> _loadStats() async {
    if (_box == null) return;

    final raw = _box!.get(_statsKey);
    if (raw is Map) {
      for (final entry in raw.entries) {
        try {
          final stats = NetworkChannelStats.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          _channelStats[stats.channelNumber] = stats;
        } catch (e) {
          debugPrint('Failed to load network stats: $e');
        }
      }
    }
  }

  Future<void> _saveStats() async {
    if (_box == null) return;

    final data = <String, dynamic>{};
    for (final entry in _channelStats.entries) {
      data[entry.key.toString()] = entry.value.toJson();
    }
    await _box!.put(_statsKey, data);
  }

  /// Record listening time for a channel.
  Future<void> recordListenTime(int channelNumber, int seconds) async {
    if (seconds <= 0) return;

    final existing = _channelStats[channelNumber];
    if (existing != null) {
      _channelStats[channelNumber] = existing.copyWith(
        listenTimeSeconds: existing.listenTimeSeconds + seconds,
        playCount: existing.playCount + 1,
        lastPlayed: DateTime.now(),
      );
    } else {
      _channelStats[channelNumber] = NetworkChannelStats(
        channelNumber: channelNumber,
        playCount: 1,
        listenTimeSeconds: seconds,
        lastPlayed: DateTime.now(),
      );
    }
    await _saveStats();
    notifyListeners();
  }

  /// Get stats for a specific channel.
  NetworkChannelStats? getChannelStats(int channelNumber) {
    return _channelStats[channelNumber];
  }

  /// Get top channels by listening time.
  List<NetworkChannelStats> getTopChannels({int limit = 5}) {
    final sorted = _channelStats.values.toList()
      ..sort((a, b) => b.listenTimeSeconds.compareTo(a.listenTimeSeconds));
    return sorted.take(limit).toList();
  }

  /// Get total listening time across all channels.
  int get totalListenTimeSeconds {
    return _channelStats.values.fold(0, (sum, s) => sum + s.listenTimeSeconds);
  }

  /// Get total play count across all channels.
  int get totalPlayCount {
    return _channelStats.values.fold(0, (sum, s) => sum + s.playCount);
  }

  /// Format total listen time as human readable string.
  String get formattedTotalListenTime {
    final seconds = totalListenTimeSeconds;
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) {
      final mins = seconds ~/ 60;
      return '${mins}m';
    }
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    return '${hours}h ${mins}m';
  }

  /// Export stats as JSON string for backup.
  String exportStatsAsJson() {
    final data = <String, dynamic>{};
    for (final entry in _channelStats.entries) {
      data[entry.key.toString()] = entry.value.toJson();
    }
    return jsonEncode({
      'network_stats': data,
      'exported_at': DateTime.now().toIso8601String(),
    });
  }

  /// Import stats from JSON string (merges with existing, keeps higher values).
  Future<int> importStatsFromJson(String jsonString) async {
    try {
      final decoded = jsonString.trim();
      if (!decoded.startsWith('{')) return 0;

      final Map<String, dynamic> parsed;
      final jsonData = jsonDecode(decoded) as Map<String, dynamic>;

      if (jsonData.containsKey('network_stats')) {
        // New format with wrapper
        parsed = Map<String, dynamic>.from(jsonData['network_stats'] as Map);
      } else {
        // Direct stats map
        parsed = jsonData;
      }

      int importedCount = 0;
      for (final entry in parsed.entries) {
        try {
          final stats = NetworkChannelStats.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          final existing = _channelStats[stats.channelNumber];

          if (existing != null) {
            // Merge: keep higher play count and listen time
            _channelStats[stats.channelNumber] = NetworkChannelStats(
              channelNumber: stats.channelNumber,
              playCount: existing.playCount > stats.playCount
                  ? existing.playCount
                  : stats.playCount,
              listenTimeSeconds: existing.listenTimeSeconds > stats.listenTimeSeconds
                  ? existing.listenTimeSeconds
                  : stats.listenTimeSeconds,
              lastPlayed: (existing.lastPlayed != null && stats.lastPlayed != null)
                  ? (existing.lastPlayed!.isAfter(stats.lastPlayed!)
                      ? existing.lastPlayed
                      : stats.lastPlayed)
                  : (existing.lastPlayed ?? stats.lastPlayed),
            );
          } else {
            _channelStats[stats.channelNumber] = stats;
          }
          importedCount++;
        } catch (e) {
          debugPrint('Failed to import channel stats: $e');
        }
      }

      if (importedCount > 0) {
        await _saveStats();
        notifyListeners();
      }
      return importedCount;
    } catch (e) {
      debugPrint('Failed to import stats: $e');
      return 0;
    }
  }

  /// Toggle auto-cache mode.
  Future<void> setAutoCacheEnabled(bool enabled) async {
    if (_autoCacheEnabled == enabled) return;

    _autoCacheEnabled = enabled;
    await _box?.put(_autoCacheKey, enabled);
    notifyListeners();
  }

  /// Verify downloaded files still exist on disk.
  Future<void> _verifyDownloads() async {
    final toRemove = <int>[];

    for (final entry in _downloads.entries) {
      final item = entry.value;
      if (item.status == NetworkDownloadStatus.downloaded) {
        bool audioExists = true;

        if (item.audioPath != null) {
          audioExists = await File(item.audioPath!).exists();
        }

        // If audio is missing, mark for removal
        if (!audioExists) {
          toRemove.add(entry.key);
          // Clean up orphaned image
          if (item.imagePath != null) {
            try {
              final imageFile = File(item.imagePath!);
              if (await imageFile.exists()) {
                await imageFile.delete();
              }
            } catch (_) {}
          }
        }
      }
    }

    for (final key in toRemove) {
      _downloads.remove(key);
    }

    if (toRemove.isNotEmpty) {
      await _saveDownloads();
    }
  }

  /// Get download item for a channel.
  NetworkDownloadItem? getDownloadItem(int channelNumber) {
    return _downloads[channelNumber];
  }

  /// Check if a channel is downloaded.
  bool isChannelDownloaded(int channelNumber) {
    final item = _downloads[channelNumber];
    return item?.status == NetworkDownloadStatus.downloaded;
  }

  /// Check if a channel is currently downloading.
  bool isChannelDownloading(int channelNumber) {
    final item = _downloads[channelNumber];
    return item?.status == NetworkDownloadStatus.downloading ||
        _downloadQueue.contains(channelNumber);
  }

  /// Get local audio path for a channel, or null if not downloaded.
  String? getLocalAudioPath(int channelNumber) {
    final item = _downloads[channelNumber];
    if (item?.status == NetworkDownloadStatus.downloaded) {
      return item?.audioPath;
    }
    return null;
  }

  /// Get local image path for a channel, or null if not downloaded.
  String? getLocalImagePath(int channelNumber) {
    final item = _downloads[channelNumber];
    if (item?.status == NetworkDownloadStatus.downloaded) {
      return item?.imagePath;
    }
    return null;
  }

  /// Get list of all downloaded channels.
  List<NetworkChannel> get downloadedChannels {
    final downloaded = <NetworkChannel>[];
    for (final item in _downloads.values) {
      if (item.status == NetworkDownloadStatus.downloaded) {
        final channel = networkChannels.cast<NetworkChannel?>().firstWhere(
              (c) => c?.number == item.channelNumber,
              orElse: () => null,
            );
        if (channel != null) {
          downloaded.add(channel);
        }
      }
    }
    return downloaded..sort((a, b) => a.number.compareTo(b.number));
  }

  /// Get number of downloaded channels.
  int get downloadedCount =>
      _downloads.values.where((d) => d.isDownloaded).length;

  /// Check if any downloads are in progress.
  bool get isDownloadingAny =>
      _downloadQueue.isNotEmpty ||
      _downloads.values.any((d) => d.status == NetworkDownloadStatus.downloading);

  /// Get count of channels currently downloading or queued.
  int get downloadingCount =>
      _downloads.values.where((d) => d.status == NetworkDownloadStatus.downloading).length;

  /// Get download progress for a channel (0.0 to 1.0).
  double getDownloadProgress(int channelNumber) {
    return _downloads[channelNumber]?.progress ?? 0.0;
  }

  /// Called when a channel is played - auto-caches if enabled.
  /// Returns the local path if available, otherwise the stream URL.
  Future<String> getPlaybackUrl(NetworkChannel channel) async {
    // If already downloaded, return local path
    final localPath = getLocalAudioPath(channel.number);
    if (localPath != null) {
      return localPath;
    }

    // If auto-cache is enabled, start background download
    if (_autoCacheEnabled) {
      // Return stream URL immediately for playback
      // Download in background for future offline access
      _downloadChannelInBackground(channel);
    }

    // Return stream URL for immediate playback
    return channel.audioUrl;
  }

  /// Download a channel in the background (for auto-cache).
  void _downloadChannelInBackground(NetworkChannel channel) {
    if (_downloads[channel.number]?.status == NetworkDownloadStatus.downloaded ||
        _downloads[channel.number]?.status == NetworkDownloadStatus.downloading ||
        _downloadQueue.contains(channel.number)) {
      return; // Already downloaded or in progress
    }

    _downloadQueue.add(channel.number);
    _downloads[channel.number] = NetworkDownloadItem(
      channelNumber: channel.number,
      status: NetworkDownloadStatus.downloading,
      progress: 0.0,
    );
    notifyListeners();

    _processQueue();
  }

  /// Manually trigger download for a channel.
  Future<void> downloadChannel(NetworkChannel channel) async {
    if (_downloads[channel.number]?.status == NetworkDownloadStatus.downloaded) {
      return; // Already downloaded
    }

    _downloadQueue.add(channel.number);
    _downloads[channel.number] = NetworkDownloadItem(
      channelNumber: channel.number,
      status: NetworkDownloadStatus.downloading,
      progress: 0.0,
    );
    notifyListeners();

    _processQueue();
  }

  /// Download all channels.
  Future<void> downloadAllChannels() async {
    for (final channel in networkChannels) {
      if (!isChannelDownloaded(channel.number) &&
          !isChannelDownloading(channel.number)) {
        _downloadQueue.add(channel.number);
        _downloads[channel.number] = NetworkDownloadItem(
          channelNumber: channel.number,
          status: NetworkDownloadStatus.downloading,
          progress: 0.0,
        );
      }
    }
    notifyListeners();
    _processQueue();
  }

  /// Process the download queue.
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    while (_downloadQueue.isNotEmpty) {
      final channelNumber = _downloadQueue.first;
      _downloadQueue.remove(channelNumber);

      final channel = networkChannels.cast<NetworkChannel?>().firstWhere(
            (c) => c?.number == channelNumber,
            orElse: () => null,
          );

      if (channel == null) continue;

      try {
        await _downloadChannelFiles(channel);
      } catch (e) {
        debugPrint('Failed to download channel ${channel.number}: $e');
        _downloads[channel.number] = NetworkDownloadItem(
          channelNumber: channel.number,
          status: NetworkDownloadStatus.failed,
          errorMessage: e.toString(),
        );
        notifyListeners();
      }
    }

    _isProcessingQueue = false;
    await _saveDownloads();
  }

  /// Download audio and image files for a channel.
  Future<void> _downloadChannelFiles(NetworkChannel channel) async {
    final audioDir = await _getAudioDirectory();
    final imageDir = await _getImageDirectory();

    // Sanitize filename
    final safeAudioName = _sanitizeFilename(channel.audioFile);
    final audioPath = '${audioDir.path}/$safeAudioName';

    String? imagePath;
    if (channel.imageFile != null) {
      final safeImageName = _sanitizeFilename(channel.imageFile!);
      imagePath = '${imageDir.path}/$safeImageName';
    }

    // Download audio
    final audioFile = File(audioPath);
    if (!await audioFile.exists()) {
      await _downloadFile(
        channel.audioUrl,
        audioPath,
        onProgress: (progress) {
          _downloads[channel.number] = _downloads[channel.number]!.copyWith(
            progress: progress * 0.9, // Audio is 90% of progress
          );
          notifyListeners();
        },
      );
    }

    // Download image if available
    if (channel.imageUrl != null && imagePath != null) {
      final imageFile = File(imagePath);
      if (!await imageFile.exists()) {
        try {
          await _downloadFile(
            channel.imageUrl!,
            imagePath,
            onProgress: (progress) {
              _downloads[channel.number] = _downloads[channel.number]!.copyWith(
                progress: 0.9 + (progress * 0.1), // Image is last 10%
              );
              notifyListeners();
            },
          );
        } catch (e) {
          // Image download failure is not critical
          debugPrint('Failed to download image for channel ${channel.number}: $e');
          imagePath = null;
        }
      }
    }

    // Mark as completed
    _downloads[channel.number] = NetworkDownloadItem(
      channelNumber: channel.number,
      status: NetworkDownloadStatus.downloaded,
      progress: 1.0,
      audioPath: audioPath,
      imagePath: imagePath,
      downloadedAt: DateTime.now(),
    );
    notifyListeners();
  }

  /// Download a file with progress callback.
  Future<void> _downloadFile(
    String url,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final contentLength = response.contentLength ?? 0;
    int receivedBytes = 0;

    final file = File(savePath);
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      sink.add(chunk);
      receivedBytes += chunk.length;

      if (contentLength > 0 && onProgress != null) {
        onProgress(receivedBytes / contentLength);
      }
    }

    await sink.close();
  }

  /// Delete a downloaded channel.
  Future<void> deleteChannel(int channelNumber) async {
    final item = _downloads[channelNumber];
    if (item == null) return;

    // Delete audio file
    if (item.audioPath != null) {
      try {
        final file = File(item.audioPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete audio: $e');
      }
    }

    // Delete image file
    if (item.imagePath != null) {
      try {
        final file = File(item.imagePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete image: $e');
      }
    }

    _downloads.remove(channelNumber);
    await _saveDownloads();
    notifyListeners();
  }

  /// Delete all downloaded channels.
  Future<void> deleteAllChannels() async {
    final channelsToDelete = _downloads.keys.toList();
    for (final channelNumber in channelsToDelete) {
      await deleteChannel(channelNumber);
    }
  }

  /// Cancel a downloading channel.
  void cancelDownload(int channelNumber) {
    _downloadQueue.remove(channelNumber);
    if (_downloads[channelNumber]?.status == NetworkDownloadStatus.downloading) {
      _downloads.remove(channelNumber);
      notifyListeners();
    }
  }

  /// Cancel all pending and in-progress downloads.
  void cancelAllDownloads() {
    _downloadQueue.clear();
    final toRemove = <int>[];
    for (final entry in _downloads.entries) {
      if (entry.value.status == NetworkDownloadStatus.downloading) {
        toRemove.add(entry.key);
      }
    }
    for (final key in toRemove) {
      _downloads.remove(key);
    }
    notifyListeners();
  }

  /// Get storage statistics.
  Future<NetworkStorageStats> getStorageStats() async {
    int audioBytes = 0;
    int imageBytes = 0;
    int channelCount = 0;

    for (final item in _downloads.values) {
      if (item.status != NetworkDownloadStatus.downloaded) continue;

      channelCount++;

      if (item.audioPath != null) {
        try {
          final file = File(item.audioPath!);
          if (await file.exists()) {
            audioBytes += await file.length();
          }
        } catch (_) {}
      }

      if (item.imagePath != null) {
        try {
          final file = File(item.imagePath!);
          if (await file.exists()) {
            imageBytes += await file.length();
          }
        } catch (_) {}
      }
    }

    return NetworkStorageStats(
      totalBytes: audioBytes + imageBytes,
      channelCount: channelCount,
      audioBytes: audioBytes,
      imageBytes: imageBytes,
    );
  }

  /// Get the audio download directory.
  Future<Directory> _getAudioDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory audioDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      audioDir = Directory('${docsDir.path}/nautune/network/audio');
    } else {
      audioDir = Directory('${docsDir.path}/network/audio');
    }

    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return audioDir;
  }

  /// Get the image download directory.
  Future<Directory> _getImageDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory imageDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      imageDir = Directory('${docsDir.path}/nautune/network/images');
    } else {
      imageDir = Directory('${docsDir.path}/network/images');
    }

    if (!await imageDir.exists()) {
      await imageDir.create(recursive: true);
    }
    return imageDir;
  }

  /// Sanitize a filename for safe storage.
  String _sanitizeFilename(String filename) {
    // Replace problematic characters
    return filename
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
