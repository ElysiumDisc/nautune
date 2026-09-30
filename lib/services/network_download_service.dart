import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/network_channels.dart';
import '../models/network_channel.dart';
import 'hive_init.dart';
import '../utils/backup_exclusion.dart';

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

/// Thrown inside a download when the user cancels it.
class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
  @override
  String toString() => 'Download cancelled';
}

/// Service for downloading and managing network channel content offline.
///
/// A single app-wide instance ([instance]; the unnamed constructor returns it
/// too) so downloads survive leaving The Network screen and every screen sees
/// the same queue and state.
///
/// Files live under `Documents/network/`. Paths are persisted *relative* to
/// that directory (the app container path changes between installs/updates)
/// and resolved on use; absolute paths from older builds are migrated on load.
class NetworkDownloadService extends ChangeNotifier {
  NetworkDownloadService._() {
    _initFuture = _initializeAndLoad();
  }

  static final NetworkDownloadService instance = NetworkDownloadService._();

  /// Returns the shared [instance].
  factory NetworkDownloadService() => instance;

  static const Duration _connectTimeout = Duration(seconds: 30);
  static const Duration _idleTimeout = Duration(seconds: 60);
  static const Duration _progressNotifyInterval = Duration(milliseconds: 250);

  final Map<int, NetworkDownloadItem> _downloads = {};
  final Set<int> _downloadQueue = {};
  bool _isProcessingQueue = false;
  final http.Client _httpClient = http.Client();

  /// Channel whose files are being fetched right now, and a callback that
  /// aborts that transfer immediately (used by cancel).
  int? _activeChannel;
  void Function()? _abortActive;

  Timer? _progressNotifyTimer;

  // Auto-cache mode setting
  bool _autoCacheEnabled = false;
  bool get autoCacheEnabled => _autoCacheEnabled;

  // Listening stats
  final Map<int, NetworkChannelStats> _channelStats = {};

  static const _boxName = 'nautune_network_downloads';
  static const _downloadsKey = 'downloads';
  static const _autoCacheKey = 'auto_cache_enabled';
  static const _statsKey = 'channel_stats';
  Box<dynamic>? _box;

  /// Absolute path of `Documents/network`, set during init.
  String? _rootPath;

  late final Future<void> _initFuture;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  /// Completes once state is loaded (or loading failed; the service then runs
  /// with empty state instead of blocking callers forever).
  Future<void> initialize() => _initFuture;

  Future<void> _initializeAndLoad() async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      _rootPath = p.join(docsDir.path, 'network');
      await _initHive();
      await _loadSettings();
      await _loadDownloads();
      await _loadStats();
      await _verifyDownloads();
    } catch (e) {
      debugPrint('NetworkDownloadService: init failed: $e');
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  Future<void> _initHive() async {
    await ensureHiveInitialized();
    _box = await Hive.openBox<dynamic>(_boxName);
  }

  Future<void> _loadSettings() async {
    if (_box == null) return;
    _autoCacheEnabled = _box!.get(_autoCacheKey, defaultValue: false) as bool;
  }

  /// Convert a stored path to one relative to `Documents/network`.
  /// Older builds stored absolute paths, which break when the app container
  /// moves; those are migrated. Returns null if it can't be mapped.
  static String? _toRelative(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    if (!stored.startsWith('/')) return stored;
    const marker = '/network/';
    final i = stored.lastIndexOf(marker);
    if (i < 0) return null;
    return stored.substring(i + marker.length);
  }

  /// Absolute path for a stored relative path.
  String? _resolve(String? relative) {
    final root = _rootPath;
    if (relative == null || root == null) return null;
    return p.join(root, relative);
  }

  Future<void> _loadDownloads() async {
    if (_box == null) return;

    final raw = _box!.get(_downloadsKey);
    var migrated = false;
    if (raw is Map) {
      for (final entry in raw.entries) {
        try {
          final item = NetworkDownloadItem.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          // Only finished downloads survive a restart; anything that was
          // mid-flight or failed is simply not downloaded.
          if (!item.isDownloaded) {
            migrated = true;
            continue;
          }
          final audio = _toRelative(item.audioPath);
          final image = _toRelative(item.imagePath);
          if (audio != item.audioPath || image != item.imagePath) {
            migrated = true;
          }
          if (audio == null) continue;
          _downloads[item.channelNumber] = NetworkDownloadItem(
            channelNumber: item.channelNumber,
            status: NetworkDownloadStatus.downloaded,
            progress: 1.0,
            audioPath: audio,
            imagePath: image,
            downloadedAt: item.downloadedAt,
          );
        } catch (e) {
          debugPrint('Failed to load network download: $e');
        }
      }
    }
    if (migrated) await _saveDownloads();
  }

  /// Persist finished downloads (relative paths).
  Future<void> _saveDownloads() async {
    if (_box == null) return;

    final data = <String, dynamic>{};
    for (final entry in _downloads.entries) {
      if (!entry.value.isDownloaded) continue;
      data[entry.key.toString()] = entry.value.toJson();
    }
    try {
      await _box!.put(_downloadsKey, data);
    } catch (e) {
      debugPrint('NetworkDownloadService: save failed: $e');
    }
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
      if (item.status != NetworkDownloadStatus.downloaded) continue;
      final audioPath = _resolve(item.audioPath);
      final audioExists =
          audioPath != null && await File(audioPath).exists();
      if (!audioExists) toRemove.add(entry.key);
    }

    for (final key in toRemove) {
      final item = _downloads.remove(key);
      // Clean up the orphaned image unless another channel still uses it.
      final imagePath = _resolve(item?.imagePath);
      if (imagePath != null && !_isPathInUse(item!.imagePath!, image: true)) {
        try {
          final imageFile = File(imagePath);
          if (await imageFile.exists()) await imageFile.delete();
        } catch (_) {}
      }
    }

    if (toRemove.isNotEmpty) {
      await _saveDownloads();
    }
  }

  /// Whether any tracked (downloaded or in-progress) channel references the
  /// relative [path]. Several channels share one audio or image file.
  bool _isPathInUse(String path, {bool image = false, int? except}) {
    for (final item in _downloads.values) {
      if (item.channelNumber == except) continue;
      final other = image ? item.imagePath : item.audioPath;
      if (other == path) return true;
    }
    return false;
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
      return _resolve(item?.audioPath);
    }
    return null;
  }

  /// Get local image path for a channel, or null if not downloaded.
  String? getLocalImagePath(int channelNumber) {
    final item = _downloads[channelNumber];
    if (item?.status == NetworkDownloadStatus.downloaded) {
      return _resolve(item?.imagePath);
    }
    return null;
  }

  /// Get list of all downloaded channels, sorted by number.
  List<NetworkChannel> get downloadedChannels {
    final downloaded = <NetworkChannel>[];
    for (final item in _downloads.values) {
      if (item.status != NetworkDownloadStatus.downloaded) continue;
      final channel = networkChannelsByNumber[item.channelNumber];
      if (channel != null) downloaded.add(channel);
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
      _enqueue(channel.number);
      notifyListeners();
      unawaited(_processQueue());
    }

    // Return stream URL for immediate playback
    return channel.audioUrl;
  }

  /// Mark [channelNumber] as queued. Returns false if it is already
  /// downloaded or in progress.
  bool _enqueue(int channelNumber) {
    if (isChannelDownloaded(channelNumber) ||
        isChannelDownloading(channelNumber)) {
      return false;
    }
    _downloadQueue.add(channelNumber);
    _downloads[channelNumber] = NetworkDownloadItem(
      channelNumber: channelNumber,
      status: NetworkDownloadStatus.downloading,
      progress: 0.0,
    );
    return true;
  }

  /// Manually trigger download for a channel.
  Future<void> downloadChannel(NetworkChannel channel) async {
    if (!_enqueue(channel.number)) return;
    notifyListeners();
    unawaited(_processQueue());
  }

  /// Download all channels (queued; returns once they are queued).
  Future<void> downloadAllChannels() async {
    for (final channel in networkChannels) {
      _enqueue(channel.number);
    }
    notifyListeners();
    unawaited(_processQueue());
  }

  /// Process the download queue, persisting after every channel.
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    try {
      await _initFuture;
      while (_downloadQueue.isNotEmpty) {
        final channelNumber = _downloadQueue.first;
        _downloadQueue.remove(channelNumber);

        final channel = networkChannelsByNumber[channelNumber];
        if (channel == null) {
          _downloads.remove(channelNumber);
          continue;
        }

        _activeChannel = channelNumber;
        try {
          await _downloadChannelFiles(channel);
        } on _DownloadCancelled {
          debugPrint('Network download cancelled: channel $channelNumber');
          // Drop the entry unless the user re-queued it meanwhile.
          if (!_downloadQueue.contains(channelNumber) &&
              _downloads[channelNumber]?.isDownloading == true) {
            _downloads.remove(channelNumber);
          }
        } catch (e) {
          debugPrint('Failed to download channel $channelNumber: $e');
          if (!_downloadQueue.contains(channelNumber) &&
              _downloads[channelNumber]?.isDownloading == true) {
            _downloads[channelNumber] = NetworkDownloadItem(
              channelNumber: channelNumber,
              status: NetworkDownloadStatus.failed,
              errorMessage: e.toString(),
            );
          }
        } finally {
          _activeChannel = null;
          _abortActive = null;
        }

        _progressNotifyTimer?.cancel();
        notifyListeners();
        await _saveDownloads();
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  void _setProgress(int channelNumber, double progress) {
    final item = _downloads[channelNumber];
    if (item == null || !item.isDownloading) return;
    if ((progress - item.progress).abs() < 0.005 && progress < 1.0) return;
    _downloads[channelNumber] = item.copyWith(progress: progress);
    // Throttle: at most one notification per interval while bytes stream in.
    if (_progressNotifyTimer?.isActive ?? false) return;
    _progressNotifyTimer = Timer(_progressNotifyInterval, notifyListeners);
  }

  /// Download audio and image files for a channel.
  Future<void> _downloadChannelFiles(NetworkChannel channel) async {
    final root = _rootPath;
    if (root == null) throw StateError('Download directory unavailable');
    await _ensureDirectory(p.join(root, 'audio'));
    await _ensureDirectory(p.join(root, 'images'));

    final relAudio = 'audio/${_sanitizeFilename(channel.audioFile)}';
    String? relImage = channel.imageFile != null
        ? 'images/${_sanitizeFilename(channel.imageFile!)}'
        : null;

    // Reuse a file only when another downloaded channel already owns it
    // (shared recordings). Any other existing file may be a partial left by
    // an older build, so it is downloaded again.
    final audioPath = p.join(root, relAudio);
    final audioShared = _downloads.values.any((d) =>
        d.isDownloaded &&
        d.channelNumber != channel.number &&
        d.audioPath == relAudio);
    if (!(audioShared && await File(audioPath).exists())) {
      await _downloadFile(
        channel.audioUrl,
        audioPath,
        onProgress: (progress) => _setProgress(channel.number, progress * 0.9),
      );
    }

    if (channel.imageUrl != null && relImage != null) {
      final imagePath = p.join(root, relImage);
      final imageShared = _downloads.values.any((d) =>
          d.isDownloaded &&
          d.channelNumber != channel.number &&
          d.imagePath == relImage);
      if (!(imageShared && await File(imagePath).exists())) {
        try {
          await _downloadFile(
            channel.imageUrl!,
            imagePath,
            onProgress: (progress) =>
                _setProgress(channel.number, 0.9 + progress * 0.1),
          );
        } on _DownloadCancelled {
          rethrow;
        } catch (e) {
          // Image download failure is not critical
          debugPrint('Failed to download image for channel ${channel.number}: $e');
          relImage = null;
        }
      }
    }

    // Mark as completed
    _downloads[channel.number] = NetworkDownloadItem(
      channelNumber: channel.number,
      status: NetworkDownloadStatus.downloaded,
      progress: 1.0,
      audioPath: relAudio,
      imagePath: relImage,
      downloadedAt: DateTime.now(),
    );
  }

  /// Download [url] to [savePath] via a `.part` file that is renamed into
  /// place only after the whole body arrived. Partial files are always
  /// removed. Throws [_DownloadCancelled] if aborted through [_abortActive].
  Future<void> _downloadFile(
    String url,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    final part = File('$savePath.part');
    IOSink? sink;
    StreamSubscription<List<int>>? subscription;
    final done = Completer<void>();
    _abortActive = () {
      if (!done.isCompleted) done.completeError(const _DownloadCancelled());
    };

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await Future.any([
        _httpClient.send(request).timeout(_connectTimeout),
        // Lets a cancel during connect abort right away.
        done.future.then<http.StreamedResponse>(
          (_) => throw const _DownloadCancelled(),
        ),
      ]);

      if (response.statusCode != 200) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw HttpException('HTTP ${response.statusCode}', uri: request.url);
      }

      final contentLength = response.contentLength ?? 0;
      var receivedBytes = 0;
      final out = part.openWrite();
      sink = out;

      subscription = response.stream.timeout(_idleTimeout).listen(
        (chunk) {
          out.add(chunk);
          receivedBytes += chunk.length;
          if (contentLength > 0 && onProgress != null) {
            onProgress(receivedBytes / contentLength);
          }
        },
        onError: (Object e, StackTrace st) {
          if (!done.isCompleted) done.completeError(e, st);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );

      await done.future;
      await out.flush();
      await out.close();
      sink = null;

      if (contentLength > 0 && receivedBytes != contentLength) {
        throw HttpException(
          'Incomplete download ($receivedBytes of $contentLength bytes)',
          uri: request.url,
        );
      }
      await part.rename(savePath);
    } finally {
      _abortActive = null;
      await subscription?.cancel();
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      // Swallow the pending error of an abandoned signal future.
      if (!done.isCompleted) done.complete();
    }
  }

  /// Delete a downloaded channel. Files shared with another tracked channel
  /// are kept.
  Future<void> deleteChannel(int channelNumber) async {
    if (isChannelDownloading(channelNumber)) cancelDownload(channelNumber);
    final item = _downloads.remove(channelNumber);
    if (item == null) {
      notifyListeners();
      return;
    }

    final audio = item.audioPath;
    if (audio != null && !_isPathInUse(audio)) {
      try {
        final file = File(_resolve(audio)!);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Failed to delete audio: $e');
      }
    }

    final image = item.imagePath;
    if (image != null && !_isPathInUse(image, image: true)) {
      try {
        final file = File(_resolve(image)!);
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('Failed to delete image: $e');
      }
    }

    await _saveDownloads();
    notifyListeners();
  }

  /// Delete all downloaded channels.
  Future<void> deleteAllChannels() async {
    cancelAllDownloads();
    final channelsToDelete = _downloads.keys.toList();
    for (final channelNumber in channelsToDelete) {
      await deleteChannel(channelNumber);
    }
  }

  /// Cancel a downloading channel.
  void cancelDownload(int channelNumber) {
    _downloadQueue.remove(channelNumber);
    if (_activeChannel == channelNumber) _abortActive?.call();
    if (_downloads[channelNumber]?.status == NetworkDownloadStatus.downloading) {
      _downloads.remove(channelNumber);
    }
    notifyListeners();
  }

  /// Cancel all pending and in-progress downloads.
  void cancelAllDownloads() {
    _downloadQueue.clear();
    _abortActive?.call();
    _downloads.removeWhere(
      (_, item) => item.status == NetworkDownloadStatus.downloading,
    );
    notifyListeners();
  }

  /// Get storage statistics. Shared files are counted once.
  Future<NetworkStorageStats> getStorageStats() async {
    int audioBytes = 0;
    int imageBytes = 0;
    int channelCount = 0;
    final seenAudio = <String>{};
    final seenImages = <String>{};

    for (final item in _downloads.values.toList()) {
      if (item.status != NetworkDownloadStatus.downloaded) continue;

      channelCount++;

      final audio = item.audioPath;
      if (audio != null && seenAudio.add(audio)) {
        try {
          final file = File(_resolve(audio)!);
          if (await file.exists()) audioBytes += await file.length();
        } catch (_) {}
      }

      final image = item.imagePath;
      if (image != null && seenImages.add(image)) {
        try {
          final file = File(_resolve(image)!);
          if (await file.exists()) imageBytes += await file.length();
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

  Future<void> _ensureDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await excludeFromBackup(path);
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
