import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/waveform_data.dart';
import 'waveform_backends/just_waveform_backend.dart';
import '../utils/backup_exclusion.dart';

/// Waveform extraction service backed by the just_waveform package (iOS).
class WaveformService {
  static WaveformService? _instance;
  static WaveformService get instance => _instance ??= WaveformService._();

  WaveformService._();

  // Platform backend
  JustWaveformBackend? _justWaveformBackend;

  // In-memory LRU cache. 200 entries ≈ enough for a long listening session
  // without hammering disk I/O; bump higher for power users if needed.
  final _cache = _LRUCache<String, WaveformData>(maxSize: 200);

  // Extraction in progress tracking
  final Map<String, Completer<WaveformData?>> _extractionCompleters = {};

  // Stream controller to notify when waveforms are extracted
  final _waveformExtractedController = StreamController<String>.broadcast();

  /// Stream that emits track IDs when their waveforms are successfully extracted
  Stream<String> get onWaveformExtracted => _waveformExtractedController.stream;

  bool _initialized = false;

  /// Check if waveform extraction is available on this platform
  bool get isAvailable => Platform.isIOS;

  /// Initialize the service and platform backends
  Future<void> initialize() async {
    if (_initialized) return;

    if (Platform.isIOS) {
      _justWaveformBackend = JustWaveformBackend();
      debugPrint('WaveformService: Initialized with JustWaveform backend');
    }

    _initialized = true;
  }

  /// Get waveform path for a track
  Future<String> _getWaveformPath(String trackId) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final waveformDir = Directory('${docsDir.path}/waveforms');

    if (!await waveformDir.exists()) {
      await waveformDir.create(recursive: true);
      // A new directory (e.g. after "Clear waveforms") has no backup
      // exclusion yet, whatever was excluded earlier in this session.
      await excludeFromBackup(waveformDir.path, force: true);
    } else {
      await excludeFromBackup(waveformDir.path);
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

      _statsCache = null;

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
    _statsCache = null;

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
    _statsCache = null;

    final docsDir = await getApplicationDocumentsDirectory();
    final waveformDir = Directory('${docsDir.path}/waveforms');

    if (await waveformDir.exists()) {
      await waveformDir.delete(recursive: true);
      debugPrint('WaveformService: Cleared all waveforms');
    }
  }

  // Last directory scan for [getStorageStats]: ({fileCount, totalBytes}).
  // Cleared whenever this service adds or deletes a waveform file.
  ({int fileCount, int totalBytes})? _statsCache;
  DateTime _statsCacheAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<({int fileCount, int totalBytes})>? _statsScan;
  static const _statsCacheMaxAge = Duration(seconds: 30);

  /// Get storage statistics for waveforms. The directory scan is shared by
  /// concurrent callers and reused for a short while (screens rebuild often;
  /// every waveform file change here invalidates it).
  Future<Map<String, dynamic>> getStorageStats() async {
    var scan = _statsCache;
    if (scan == null ||
        DateTime.now().difference(_statsCacheAt) >= _statsCacheMaxAge) {
      final pending = _statsScan ??= _scanWaveformDir().whenComplete(() {
        _statsScan = null;
      });
      scan = await pending;
    }
    final totalBytes = scan.totalBytes;
    return {
      'fileCount': scan.fileCount,
      'totalBytes': totalBytes,
      'totalSizeMB': (totalBytes / (1024 * 1024)).toStringAsFixed(2),
      'cacheSize': _cache.length,
    };
  }

  Future<({int fileCount, int totalBytes})> _scanWaveformDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final waveformDir = Directory('${docsDir.path}/waveforms');

    final files = <File>[];
    if (await waveformDir.exists()) {
      await for (final entity in waveformDir.list()) {
        if (entity is File && entity.path.endsWith('.waveform')) {
          files.add(entity);
        }
      }
    }

    // Stat in parallel batches instead of one await per file.
    var totalBytes = 0;
    const batchSize = 64;
    for (var i = 0; i < files.length; i += batchSize) {
      final end = i + batchSize < files.length ? i + batchSize : files.length;
      final sizes = await Future.wait(files.sublist(i, end).map((f) async {
        try {
          return await f.length();
        } catch (_) {
          return 0; // deleted meanwhile
        }
      }));
      for (final size in sizes) {
        totalBytes += size;
      }
    }

    final result = (fileCount: files.length, totalBytes: totalBytes);
    _statsCache = result;
    _statsCacheAt = DateTime.now();
    return result;
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
