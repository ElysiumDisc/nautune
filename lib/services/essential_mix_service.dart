import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/essential_mix_track.dart';

/// Download status for the Essential Mix.
enum EssentialMixDownloadStatus {
  notDownloaded,
  downloading,
  downloaded,
  failed,
}

/// Download state for Essential Mix.
class EssentialMixDownloadState {
  final EssentialMixDownloadStatus status;
  final double progress;
  final String? audioPath;
  final String? artworkPath;
  final DateTime? downloadedAt;
  final String? errorMessage;

  const EssentialMixDownloadState({
    required this.status,
    this.progress = 0.0,
    this.audioPath,
    this.artworkPath,
    this.downloadedAt,
    this.errorMessage,
  });

  EssentialMixDownloadState copyWith({
    EssentialMixDownloadStatus? status,
    double? progress,
    String? audioPath,
    String? artworkPath,
    DateTime? downloadedAt,
    String? errorMessage,
  }) {
    return EssentialMixDownloadState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      audioPath: audioPath ?? this.audioPath,
      artworkPath: artworkPath ?? this.artworkPath,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'progress': progress,
        'audioPath': audioPath,
        'artworkPath': artworkPath,
        'downloadedAt': downloadedAt?.toIso8601String(),
        'errorMessage': errorMessage,
      };

  factory EssentialMixDownloadState.fromJson(Map<String, dynamic> json) {
    return EssentialMixDownloadState(
      status: EssentialMixDownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => EssentialMixDownloadStatus.notDownloaded,
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      audioPath: json['audioPath'] as String?,
      artworkPath: json['artworkPath'] as String?,
      downloadedAt: json['downloadedAt'] != null
          ? DateTime.tryParse(json['downloadedAt'] as String)
          : null,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  bool get isDownloaded => status == EssentialMixDownloadStatus.downloaded;
  bool get isDownloading => status == EssentialMixDownloadStatus.downloading;
}

/// Storage statistics for Essential Mix.
class EssentialMixStorageStats {
  final int totalBytes;
  final int audioBytes;
  final int artworkBytes;

  const EssentialMixStorageStats({
    required this.totalBytes,
    required this.audioBytes,
    required this.artworkBytes,
  });

  String get formattedTotal => _formatBytes(totalBytes);
  String get formattedAudio => _formatBytes(audioBytes);
  String get formattedArtwork => _formatBytes(artworkBytes);

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Service for downloading and managing the Essential Mix easter egg content.
class EssentialMixService extends ChangeNotifier {
  static EssentialMixService? _instance;
  static EssentialMixService get instance => _instance ??= EssentialMixService._();

  EssentialMixService._() {
    _initializeAndLoad();
  }

  final http.Client _httpClient = http.Client();

  static const _boxName = 'nautune_essential_mix';
  static const _stateKey = 'download_state';
  static const _listenTimeKey = 'listen_time_seconds';
  static bool _hiveInitialized = false;
  Box<dynamic>? _box;

  EssentialMixDownloadState _state = const EssentialMixDownloadState(
    status: EssentialMixDownloadStatus.notDownloaded,
  );
  bool _isInitialized = false;
  bool _isCancelled = false;
  int _listenTimeSeconds = 0;

  // Cached storage stats to avoid repeated file I/O
  EssentialMixStorageStats? _cachedStats;

  final EssentialMixTrack track = const EssentialMixTrack();

  bool get isInitialized => _isInitialized;
  EssentialMixDownloadState get state => _state;
  bool get isDownloaded => _state.isDownloaded;
  bool get isDownloading => _state.isDownloading;
  double get downloadProgress => _state.progress;
  int get listenTimeSeconds => _listenTimeSeconds;

  /// Format listen time as human readable string.
  String get formattedListenTime {
    if (_listenTimeSeconds < 60) return '${_listenTimeSeconds}s';
    if (_listenTimeSeconds < 3600) {
      final mins = _listenTimeSeconds ~/ 60;
      final secs = _listenTimeSeconds % 60;
      return '${mins}m ${secs}s';
    }
    final hours = _listenTimeSeconds ~/ 3600;
    final mins = (_listenTimeSeconds % 3600) ~/ 60;
    return '${hours}h ${mins}m';
  }

  Future<void> _initializeAndLoad() async {
    await _initHive();
    await _loadState();
    await _loadListenTime();
    await _verifyDownload();
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

  Future<void> _loadState() async {
    if (_box == null) return;

    final raw = _box!.get(_stateKey);
    if (raw is Map) {
      try {
        _state = EssentialMixDownloadState.fromJson(
          Map<String, dynamic>.from(raw),
        );
      } catch (e) {
        debugPrint('Failed to load essential mix state: $e');
      }
    }
  }

  Future<void> _saveState() async {
    if (_box == null) return;
    await _box!.put(_stateKey, _state.toJson());
  }

  Future<void> _loadListenTime() async {
    if (_box == null) return;
    _listenTimeSeconds = _box!.get(_listenTimeKey, defaultValue: 0) as int;
  }

  Future<void> _saveListenTime() async {
    if (_box == null) return;
    await _box!.put(_listenTimeKey, _listenTimeSeconds);
  }

  /// Record listening time.
  Future<void> recordListenTime(int seconds) async {
    if (seconds <= 0) return;
    _listenTimeSeconds += seconds;
    await _saveListenTime();
    notifyListeners();
  }

  /// Verify downloaded files still exist.
  Future<void> _verifyDownload() async {
    if (_state.status != EssentialMixDownloadStatus.downloaded) return;

    bool audioExists = true;
    if (_state.audioPath != null) {
      audioExists = await File(_state.audioPath!).exists();
    }

    if (!audioExists) {
      // Capture old artwork path BEFORE overwriting state so we can clean up.
      final oldArtworkPath = _state.artworkPath;

      _state = const EssentialMixDownloadState(
        status: EssentialMixDownloadStatus.notDownloaded,
      );
      await _saveState();

      // Clean up orphaned artwork from the previous state.
      if (oldArtworkPath != null) {
        try {
          final artworkFile = File(oldArtworkPath);
          if (await artworkFile.exists()) {
            await artworkFile.delete();
          }
        } catch (e) {
          debugPrint('EssentialMixService: orphan artwork cleanup failed: $e');
        }
      }
    }
  }

  /// Get playback URL (local path if downloaded, stream URL otherwise).
  String getPlaybackUrl() {
    if (_state.isDownloaded && _state.audioPath != null) {
      return _state.audioPath!;
    }
    return track.audioUrl;
  }

  /// Get artwork URL (local path if downloaded, network URL otherwise).
  String getArtworkUrl() {
    if (_state.isDownloaded && _state.artworkPath != null) {
      return 'file://${_state.artworkPath}';
    }
    return track.artworkUrl;
  }

  /// Check if using local file.
  bool get isPlayingOffline => _state.isDownloaded && _state.audioPath != null;

  /// Create a virtual JellyfinTrack for use with AudioPlayerService.
  /// Returns null if not downloaded (Essential Mix requires download).
  JellyfinTrack? getVirtualTrack() {
    if (!isPlayingOffline) return null;

    // 2 hours in ticks (10,000,000 ticks per second)
    const twoHoursInTicks = 2 * 60 * 60 * 10000000;

    return JellyfinTrack(
      id: track.id,
      name: track.name,
      album: track.album,
      artists: [track.artist],
      runTimeTicks: twoHoursInTicks,
      assetPathOverride: _state.audioPath,
      // No server/token needed - using local file
      serverUrl: null,
      token: null,
      userId: null,
      container: 'MP3',
      codec: 'MP3',
      bitrate: 256000, // Approximate
      sampleRate: 44100,
      channels: 2,
    );
  }

  /// Start downloading the Essential Mix.
  Future<void> startDownload() async {
    if (_state.isDownloading) return;
    if (_state.isDownloaded) return;

    _isCancelled = false;
    _state = const EssentialMixDownloadState(
      status: EssentialMixDownloadStatus.downloading,
      progress: 0.0,
    );
    notifyListeners();

    try {
      final audioDir = await _getAudioDirectory();
      final artworkDir = await _getArtworkDirectory();

      final audioPath = '${audioDir.path}/essential_mix_soulwax_2017.mp3';
      final artworkPath = '${artworkDir.path}/essential_mix_soulwax_2017.jpg';

      // Download artwork first (small, quick)
      String? savedArtworkPath;
      try {
        await _downloadFile(
          track.artworkUrl,
          artworkPath,
          onProgress: (progress) {
            if (_isCancelled) throw Exception('Cancelled');
            _state = _state.copyWith(progress: progress * 0.02); // 2% for artwork
            notifyListeners();
          },
        );
        savedArtworkPath = artworkPath;
      } catch (e) {
        debugPrint('Artwork download failed (non-critical): $e');
      }

      if (_isCancelled) {
        throw Exception('Cancelled');
      }

      // Download audio (main file)
      await _downloadFile(
        track.audioUrl,
        audioPath,
        onProgress: (progress) {
          if (_isCancelled) throw Exception('Cancelled');
          _state = _state.copyWith(
            progress: 0.02 + (progress * 0.98), // 98% for audio
          );
          notifyListeners();
        },
      );

      // Mark as completed
      _state = EssentialMixDownloadState(
        status: EssentialMixDownloadStatus.downloaded,
        progress: 1.0,
        audioPath: audioPath,
        artworkPath: savedArtworkPath,
        downloadedAt: DateTime.now(),
      );
      await _saveState();
      notifyListeners();

      debugPrint('Essential Mix downloaded successfully');
    } catch (e) {
      if (_isCancelled) {
        _state = const EssentialMixDownloadState(
          status: EssentialMixDownloadStatus.notDownloaded,
        );
      } else {
        _state = EssentialMixDownloadState(
          status: EssentialMixDownloadStatus.failed,
          errorMessage: e.toString(),
        );
      }
      await _saveState();
      notifyListeners();
      debugPrint('Essential Mix download failed: $e');
    }
  }

  /// Cancel ongoing download.
  void cancelDownload() {
    if (_state.isDownloading) {
      _isCancelled = true;
    }
  }

  /// Delete downloaded files.
  Future<void> deleteDownload() async {
    // Delete audio file
    if (_state.audioPath != null) {
      try {
        final file = File(_state.audioPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete audio: $e');
      }
    }

    // Delete artwork file
    if (_state.artworkPath != null) {
      try {
        final file = File(_state.artworkPath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete artwork: $e');
      }
    }

    _state = const EssentialMixDownloadState(
      status: EssentialMixDownloadStatus.notDownloaded,
    );
    _cachedStats = null; // Clear cached stats
    await _saveState();
    notifyListeners();
  }

  /// Get storage statistics (cached to avoid repeated file I/O).
  Future<EssentialMixStorageStats> getStorageStats() async {
    // Return cached stats if available and still downloaded
    if (_cachedStats != null && _state.isDownloaded) {
      return _cachedStats!;
    }

    int audioBytes = 0;
    int artworkBytes = 0;

    if (_state.audioPath != null) {
      try {
        final file = File(_state.audioPath!);
        if (await file.exists()) {
          audioBytes = await file.length();
        }
      } catch (e) {
        debugPrint('EssentialMixService: audio stat failed: $e');
      }
    }

    if (_state.artworkPath != null) {
      try {
        final file = File(_state.artworkPath!);
        if (await file.exists()) {
          artworkBytes = await file.length();
        }
      } catch (e) {
        debugPrint('EssentialMixService: artwork stat failed: $e');
      }
    }

    _cachedStats = EssentialMixStorageStats(
      totalBytes: audioBytes + artworkBytes,
      audioBytes: audioBytes,
      artworkBytes: artworkBytes,
    );
    return _cachedStats!;
  }

  /// Download a file with progress callback.
  Future<void> _downloadFile(
    String url,
    String savePath, {
    void Function(double)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    // Add User-Agent header to avoid 403 from archive.org
    request.headers['User-Agent'] = 'Nautune/5.7.0 (Music Player)';
    final response = await _httpClient.send(request);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final contentLength = response.contentLength ?? 0;
    int receivedBytes = 0;

    final file = File(savePath);
    final sink = file.openWrite();

    await for (final chunk in response.stream) {
      if (_isCancelled) {
        await sink.close();
        await file.delete();
        throw Exception('Cancelled');
      }

      sink.add(chunk);
      receivedBytes += chunk.length;

      if (contentLength > 0 && onProgress != null) {
        onProgress(receivedBytes / contentLength);
      }
    }

    await sink.close();
  }

  /// Get the audio download directory.
  Future<Directory> _getAudioDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory audioDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      audioDir = Directory('${docsDir.path}/nautune/essential/audio');
    } else {
      audioDir = Directory('${docsDir.path}/essential/audio');
    }

    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    return audioDir;
  }

  /// Get the artwork download directory.
  Future<Directory> _getArtworkDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory artworkDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      artworkDir = Directory('${docsDir.path}/nautune/essential/artwork');
    } else {
      artworkDir = Directory('${docsDir.path}/essential/artwork');
    }

    if (!await artworkDir.exists()) {
      await artworkDir.create(recursive: true);
    }
    return artworkDir;
  }
}
