import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/waveform_data.dart';
import 'waveform_backends/just_waveform_backend.dart';
import 'waveform_backends/ffmpeg_waveform_backend.dart';

/// Unified waveform extraction service with platform-specific backends.
/// - iOS/macOS/Android: Uses just_waveform package
/// - Linux: Uses ffmpeg for PCM extraction
class WaveformService {
  static WaveformService? _instance;
  static WaveformService get instance => _instance ??= WaveformService._();

  WaveformService._();

  // Platform backends
  JustWaveformBackend? _justWaveformBackend;
  FFmpegWaveformBackend? _ffmpegBackend;

  // In-memory LRU cache
  final _cache = _LRUCache<String, WaveformData>(maxSize: 50);

  // Extraction in progress tracking
  final Map<String, Completer<WaveformData?>> _extractionCompleters = {};

  // Stream controller to notify when waveforms are extracted
  final _waveformExtractedController = StreamController<String>.broadcast();

  /// Stream that emits track IDs when their waveforms are successfully extracted
  Stream<String> get onWaveformExtracted => _waveformExtractedController.stream;

  bool _initialized = false;

  /// Check if waveform extraction is available on this platform
  bool get isAvailable =>
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      (Platform.isLinux && (_ffmpegBackend?.isAvailable ?? false));

  /// Initialize the service and platform backends
  Future<void> initialize() async {
    if (_initialized) return;

    if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
      _justWaveformBackend = JustWaveformBackend();
      debugPrint('WaveformService: Initialized with JustWaveform backend');
    } else if (Platform.isLinux) {
      _ffmpegBackend = FFmpegWaveformBackend();
      final available = await _ffmpegBackend!.initialize();
      if (available) {
        debugPrint('WaveformService: Initialized with FFmpeg backend');
      } else {
        debugPrint('WaveformService: FFmpeg not available on Linux');
      }
    }

    _initialized = true;
  }

  /// Get waveform path for a track
  Future<String> _getWaveformPath(String trackId) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory waveformDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      waveformDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}waveforms',
      );
    } else {
      // iOS/Android: Use app documents directory
      waveformDir = Directory('${docsDir.path}/waveforms');
    }

    if (!await waveformDir.exists()) {
      await waveformDir.create(recursive: true);
    }

    return '${waveformDir.path}${Platform.pathSeparator}$trackId.waveform';
  }

  /// Get waveform data for a track (from cache or disk)
  Future<WaveformData?> getWaveform(String trackId) async {
    if (!_initialized) await initialize();

    // Check memory cache first
    final cached = _cache.get(trackId);
    if (cached != null) return cached;

    // Load from disk
    final path = await _getWaveformPath(trackId);
    WaveformData? data;

    if (_justWaveformBackend != null) {
      data = await _justWaveformBackend!.load(path);
    } else if (_ffmpegBackend != null) {
      data = await _ffmpegBackend!.load(path);
    }

    if (data != null && data.amplitudes.isNotEmpty) {
      _cache.put(trackId, data);
    }

    return data;
  }

  /// Check if a valid waveform exists for a track
  Future<bool> hasWaveform(String trackId) async {
    // Check memory cache first
    if (_cache.containsKey(trackId)) return true;

    // Try to load from disk and validate it's a valid version
    final data = await getWaveform(trackId);
    return data != null && data.amplitudes.isNotEmpty;
  }

  /// Extract waveform from audio file and save.
  /// Returns a stream of progress (0.0 - 1.0).
  Stream<double> extractWaveform(String trackId, String audioPath) async* {
    if (!_initialized) await initialize();
    if (!isAvailable) {
      debugPrint('WaveformService: No backend available');
      return;
    }

    // Check if already extracting
    if (_extractionCompleters.containsKey(trackId)) {
      debugPrint('WaveformService: Extraction already in progress for $trackId');
      return;
    }

    // Check if already exists and is valid
    if (await hasWaveform(trackId)) {
      debugPrint('WaveformService: Waveform already exists for $trackId');
      yield 1.0;
      return;
    }

    final completer = Completer<WaveformData?>();
    _extractionCompleters[trackId] = completer;

    try {
      final outputPath = await _getWaveformPath(trackId);

      // Delete old invalid waveform file if it exists
      final oldFile = File(outputPath);
      if (await oldFile.exists()) {
        await oldFile.delete();
        debugPrint('WaveformService: Deleted old invalid waveform for $trackId');
      }

      Stream<double> progressStream;
      if (_justWaveformBackend != null && _justWaveformBackend!.isAvailable) {
        progressStream = _justWaveformBackend!.extract(audioPath, outputPath);
      } else if (_ffmpegBackend != null && _ffmpegBackend!.isAvailable) {
        progressStream = _ffmpegBackend!.extract(audioPath, outputPath);
      } else {
        debugPrint('WaveformService: No backend available for extraction');
        return;
      }

      await for (final progress in progressStream) {
        yield progress;
      }

      // Load the extracted waveform into cache
      final data = await getWaveform(trackId);
      completer.complete(data);

      // Notify listeners that waveform is now available
      if (data != null && data.amplitudes.isNotEmpty) {
        _waveformExtractedController.add(trackId);
      }

      debugPrint('WaveformService: Extraction complete for $trackId');
    } catch (e) {
      debugPrint('WaveformService: Extraction failed for $trackId: $e');
      completer.complete(null);
    } finally {
      _extractionCompleters.remove(trackId);
    }
  }

  /// Extract waveform in background (fire and forget)
  Future<void> extractWaveformInBackground(String trackId, String audioPath) async {
    if (!isAvailable) return;
    if (await hasWaveform(trackId)) return;

    // Listen to the stream to drive extraction, but don't block
    unawaited(
      extractWaveform(trackId, audioPath).drain<void>().catchError((e) {
        debugPrint('WaveformService: Background extraction failed: $e');
      }),
    );
  }

  /// Delete waveform for a track
  Future<void> deleteWaveform(String trackId) async {
    _cache.remove(trackId);

    final path = await _getWaveformPath(trackId);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      debugPrint('WaveformService: Deleted waveform for $trackId');
    }
  }

  /// Clear all cached waveforms (memory and disk)
  Future<void> clearAllWaveforms() async {
    _cache.clear();

    final docsDir = await getApplicationDocumentsDirectory();
    final Directory waveformDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      waveformDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}waveforms',
      );
    } else {
      waveformDir = Directory('${docsDir.path}/waveforms');
    }

    if (await waveformDir.exists()) {
      await waveformDir.delete(recursive: true);
      debugPrint('WaveformService: Cleared all waveforms');
    }
  }

  /// Get storage statistics for waveforms
  Future<Map<String, dynamic>> getStorageStats() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final Directory waveformDir;

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      waveformDir = Directory(
        '${docsDir.path}${Platform.pathSeparator}nautune${Platform.pathSeparator}waveforms',
      );
    } else {
      waveformDir = Directory('${docsDir.path}/waveforms');
    }

    int fileCount = 0;
    int totalBytes = 0;

    if (await waveformDir.exists()) {
      await for (final entity in waveformDir.list()) {
        if (entity is File && entity.path.endsWith('.waveform')) {
          fileCount++;
          totalBytes += await entity.length();
        }
      }
    }

    return {
      'fileCount': fileCount,
      'totalBytes': totalBytes,
      'totalSizeMB': (totalBytes / (1024 * 1024)).toStringAsFixed(2),
      'cacheSize': _cache.length,
    };
  }
}

/// Simple LRU cache implementation
class _LRUCache<K, V> {
  final int maxSize;
  final _map = <K, V>{};

  _LRUCache({required this.maxSize});

  V? get(K key) {
    final value = _map.remove(key);
    if (value != null) {
      _map[key] = value; // Move to end (most recently used)
    }
    return value;
  }

  void put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > maxSize) {
      _map.remove(_map.keys.first); // Remove least recently used
    }
  }

  bool containsKey(K key) => _map.containsKey(key);

  void remove(K key) => _map.remove(key);

  void clear() => _map.clear();

  int get length => _map.length;
}
