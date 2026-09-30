import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/essential_mix_track.dart';
import 'hive_init.dart';
import '../utils/backup_exclusion.dart';

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

/// Thrown inside a download when the user cancels it.
class _EssentialMixCancelled implements Exception {
  const _EssentialMixCancelled();
  @override
  String toString() => 'Download cancelled';
}

/// Service for downloading and managing the Essential Mix easter egg content.
class EssentialMixService extends ChangeNotifier {
  static EssentialMixService? _instance;
  static EssentialMixService get instance => _instance ??= EssentialMixService._();

  EssentialMixService._() {
    _initializeAndLoad();
  }

  final http.Client _httpClient = http.Client();

  static const Duration _connectTimeout = Duration(seconds: 30);
  static const Duration _idleTimeout = Duration(seconds: 60);
  static const String _audioFileName = 'essential_mix_soulwax_2017.mp3';
  static const String _artworkFileName = 'essential_mix_soulwax_2017.jpg';

  /// Aborts the in-flight transfer (set while a file is downloading).
  void Function()? _abortActive;

  static const _boxName = 'nautune_essential_mix';
  static const _stateKey = 'download_state';
  static const _listenTimeKey = 'listen_time_seconds';
  Box<dynamic>? _box;

  EssentialMixDownloadState _state = const EssentialMixDownloadState(
    status: EssentialMixDownloadStatus.notDownloaded,
  );
  bool _isInitialized = false;
  bool _isCancelled = false;
  int _listenTimeSeconds = 0;

  // Cached storage stats to avoid repeated file I/O
  EssentialMixStorageStats? _cachedStats;

  // Throttle progress notifications so downstream consumers don't rebuild
  // once per HTTP chunk (hundreds of times per MB). Fires at most every 100 ms
  // and only when progress has moved by >=1% since the last notify.
  Timer? _notifyTimer;
  double _lastNotifiedProgress = -1.0;

  void _scheduleNotify({bool force = false}) {
    if (force) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotifiedProgress = _state.progress;
      notifyListeners();
      return;
    }
    // Throttle (not debounce): a pending timer is left alone, so steady
    // chunk arrival still produces an update every 100 ms.
    if (_notifyTimer?.isActive ?? false) return;
    if ((_state.progress - _lastNotifiedProgress).abs() < 0.01) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _lastNotifiedProgress = _state.progress;
      notifyListeners();
    });
  }

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
    try {
      await _initHive();
      await _loadState();
      await _loadListenTime();
      await _verifyDownload();
    } catch (e) {
      debugPrint('EssentialMixService: init failed: $e');
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  Future<void> _initHive() async {
    await ensureHiveInitialized();
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

    // Stored paths are absolute; the app container path can change between
    // installs/updates. Remap to the current Documents directory when the
    // stored path is gone but the file is where we'd save it today.
    final storedAudio = _state.audioPath;
    if (storedAudio != null && !await File(storedAudio).exists()) {
      final audioDir = await _getAudioDirectory();
      final artworkDir = await _getArtworkDirectory();
      final currentAudio = '${audioDir.path}/$_audioFileName';
      if (await File(currentAudio).exists()) {
        final currentArtwork = '${artworkDir.path}/$_artworkFileName';
        final hasArtwork =
            _state.artworkPath != null && await File(currentArtwork).exists();
        _state = EssentialMixDownloadState(
          status: EssentialMixDownloadStatus.downloaded,
          progress: 1.0,
          audioPath: currentAudio,
          artworkPath: hasArtwork ? currentArtwork : null,
          downloadedAt: _state.downloadedAt,
        );
        await _saveState();
      }
    }

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
  ///
  /// The audio streams into a `.part` file; if a previous attempt failed
  /// (network drop, app suspended) the next attempt resumes it with an HTTP
  /// Range request instead of starting the 234 MB over. Stalls time out, and
  /// [cancelDownload] aborts the transfer immediately.
  Future<void> startDownload() async {
    if (_state.isDownloading) return;
    if (_state.isDownloaded) return;

    _isCancelled = false;
    _state = const EssentialMixDownloadState(
      status: EssentialMixDownloadStatus.downloading,
      progress: 0.0,
    );
    _scheduleNotify(force: true);

    try {
      final audioDir = await _getAudioDirectory();
      final artworkDir = await _getArtworkDirectory();

      final audioPath = '${audioDir.path}/$_audioFileName';
      final artworkPath = '${artworkDir.path}/$_artworkFileName';

      // Download artwork first (small, quick)
      String? savedArtworkPath;
      try {
        await _downloadFile(
          track.artworkUrl,
          artworkPath,
          resumable: false,
          onProgress: (progress) {
            _state = _state.copyWith(progress: progress * 0.02); // 2% for artwork
            _scheduleNotify();
          },
        );
        savedArtworkPath = artworkPath;
      } on _EssentialMixCancelled {
        rethrow;
      } catch (e) {
        debugPrint('Artwork download failed (non-critical): $e');
      }

      if (_isCancelled) throw const _EssentialMixCancelled();

      // Download audio (main file)
      await _downloadFile(
        track.audioUrl,
        audioPath,
        onProgress: (progress) {
          _state = _state.copyWith(
            progress: 0.02 + (progress * 0.98), // 98% for audio
          );
          _scheduleNotify();
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
      _scheduleNotify(force: true);

      debugPrint('Essential Mix downloaded successfully');
    } catch (e) {
      if (_isCancelled || e is _EssentialMixCancelled) {
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
      _scheduleNotify(force: true);
      debugPrint('Essential Mix download failed: $e');
    } finally {
      _abortActive = null;
    }
  }

  /// Cancel ongoing download. Takes effect immediately, even mid-stall.
  void cancelDownload() {
    if (_state.isDownloading) {
      _isCancelled = true;
      _abortActive?.call();
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

  /// Download [url] to [savePath] through `savePath.part`, renamed into
  /// place only once the whole body arrived.
  ///
  /// With [resumable], a leftover `.part` from a failed attempt is continued
  /// via an HTTP Range request (and kept on failure for the next attempt);
  /// a cancel always deletes it. The request times out after
  /// [_connectTimeout] and a stalled body after [_idleTimeout].
  Future<void> _downloadFile(
    String url,
    String savePath, {
    bool resumable = true,
    void Function(double)? onProgress,
  }) async {
    final part = File('$savePath.part');
    final done = Completer<void>();
    _abortActive = () {
      if (!done.isCompleted) done.completeError(const _EssentialMixCancelled());
    };
    IOSink? sink;
    StreamSubscription<List<int>>? subscription;
    // Keep a resumable partial across failures; drop it on cancel/success.
    var keepPart = resumable;

    try {
      var existing = 0;
      if (resumable && await part.exists()) {
        existing = await part.length();
      } else if (await part.exists()) {
        await part.delete();
      }

      final request = http.Request('GET', Uri.parse(url));
      // Add User-Agent header to avoid 403 from archive.org
      request.headers['User-Agent'] = 'Nautune/5.7.0 (Music Player)';
      if (existing > 0) request.headers['Range'] = 'bytes=$existing-';

      final response = await Future.any([
        _httpClient.send(request).timeout(_connectTimeout),
        done.future.then<http.StreamedResponse>(
          (_) => throw const _EssentialMixCancelled(),
        ),
      ]);

      final bool append;
      if (response.statusCode == 206 && existing > 0) {
        append = true;
      } else if (response.statusCode == 200) {
        append = false;
        existing = 0;
      } else if (response.statusCode == 416 && existing > 0) {
        // Our partial is unusable (e.g. file changed upstream): start over.
        unawaited(response.stream.drain<void>().catchError((_) {}));
        await part.delete();
        throw HttpException('HTTP 416 (restarting)', uri: request.url);
      } else {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw HttpException('HTTP ${response.statusCode}', uri: request.url);
      }

      final bodyLength = response.contentLength ?? 0;
      final totalLength = bodyLength > 0 ? existing + bodyLength : 0;
      var receivedBytes = existing;

      final out = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      sink = out;

      subscription = response.stream.timeout(_idleTimeout).listen(
        (chunk) {
          out.add(chunk);
          receivedBytes += chunk.length;
          if (totalLength > 0 && onProgress != null) {
            onProgress(receivedBytes / totalLength);
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

      if (totalLength > 0 && receivedBytes != totalLength) {
        throw HttpException(
          'Incomplete download ($receivedBytes of $totalLength bytes)',
          uri: request.url,
        );
      }
      await part.rename(savePath);
      keepPart = false;
    } on _EssentialMixCancelled {
      keepPart = false;
      rethrow;
    } finally {
      _abortActive = null;
      await subscription?.cancel();
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!keepPart || _isCancelled) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
      if (!done.isCompleted) done.complete();
    }
  }

  /// Get the audio download directory.
  Future<Directory> _getAudioDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${docsDir.path}/essential/audio');

    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    await excludeFromBackup(audioDir.path);
    return audioDir;
  }

  /// Get the artwork download directory.
  Future<Directory> _getArtworkDirectory() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final artworkDir = Directory('${docsDir.path}/essential/artwork');

    if (!await artworkDir.exists()) {
      await artworkDir.create(recursive: true);
    }
    await excludeFromBackup(artworkDir.path);
    return artworkDir;
  }
}
