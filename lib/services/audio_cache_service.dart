import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../jellyfin/jellyfin_track.dart';
import 'connectivity_service.dart';
import 'playback_logic.dart';
import 'waveform_service.dart';

/// Service for pre-caching audio tracks for smoother playback.
/// Uses flutter_cache_manager for efficient file caching with automatic eviction.
class AudioCacheService {
  static AudioCacheService? _instance;
  static AudioCacheService get instance => _instance ??= AudioCacheService._();
  
  AudioCacheService._();
  
  CacheManager? _cacheManager;
  JsonCacheInfoRepository? _repo;
  Future<void>? _initFuture;
  final Set<String> _cachingInProgress = {};
  final Map<String, Completer<File?>> _cacheCompleters = {};

  // Cache configuration
  static const int _maxCacheSize = 500; // Max number of cached files
  static const Duration _stalePeriod = Duration(days: 7);
  static const String _cacheKey = 'nautune_audio_cache';

  /// Upper bound on the audio cache's size on disk. flutter_cache_manager
  /// only bounds the *number* of files (500), which for lossless audio can
  /// reach many GB; least-recently-used files are evicted past this.
  static const int _maxCacheBytes = 2 * 1024 * 1024 * 1024; // 2 GiB
  bool _trimming = false;
  DateTime? _lastTrim;

  /// Initialize the cache manager (idempotent; concurrent callers share one
  /// initialisation so two CacheManagers never open the same repository).
  Future<void> initialize() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    final repo = JsonCacheInfoRepository(databaseName: _cacheKey);
    _repo = repo;
    _cacheManager = CacheManager(
      Config(
        _cacheKey,
        stalePeriod: _stalePeriod,
        maxNrOfCacheObjects: _maxCacheSize,
        repo: repo,
        fileService: HttpFileService(),
      ),
    );
    debugPrint('🎵 AudioCacheService initialized');
  }

  /// Directory flutter_cache_manager stores this cache's files in.
  Future<String> _cacheDirPath() async {
    final tempDir = await getTemporaryDirectory();
    return path.join(tempDir.path, _cacheKey);
  }

  /// Get cached file path for a track, or null if not cached
  Future<File?> getCachedFile(String trackId) async {
    await initialize();
    if (_cacheManager == null) return null;

    try {
      // Try direct lookup first via CacheManager index
      final fileInfo = await _cacheManager!.getFileFromCache(trackId);
      if (fileInfo != null && await fileInfo.file.exists()) {
        return fileInfo.file;
      }

    } catch (e) {
      debugPrint('⚠️ Error checking cache for $trackId: $e');
    }
    return null;
  }
  
  /// Check if a track is cached
  Future<bool> isCached(String trackId) async {
    final file = await getCachedFile(trackId);
    return file != null;
  }
  
  /// Pre-cache a single track in the background
  /// Returns the cached file, or null if caching failed
  /// [streamUrl] is the URL to cache from — callers pass the URL playback
  /// would stream (universal endpoint at the user's quality), so the copy is
  /// something AVPlayer can open (non-native formats arrive as MP3, stored
  /// as .mp3 from the audio/mpeg Content-Type). Without it only a track's
  /// own `streamUrlOverride` is used: the raw-file endpoint
  /// (`/Items/{id}/Download`) needs the download permission, logs a
  /// "downloaded" activity entry, and may be a format AVPlayer can't decode.
  Future<File?> cacheTrack(JellyfinTrack track, {String? streamUrl}) async {
    await initialize();

    // Always use track.id as cache key for consistent lookup
    // This ensures getCachedFile(track.id) will find the file regardless of stream URL
    final trackId = track.id;

    // Already caching this track - wait for it
    if (_cachingInProgress.contains(trackId)) {
      return _cacheCompleters[trackId]?.future;
    }

    // Check if already cached
    final existing = await getCachedFile(trackId);
    if (existing != null) {
      debugPrint('✅ Track already cached: ${track.name}');
      return existing;
    }

    // Get the streaming URL
    final url = streamUrl ?? track.streamUrlOverride;
    if (url == null) {
      debugPrint('⚠️ No URL available for track: ${track.name}');
      return null;
    }

    // Start caching
    _cachingInProgress.add(trackId);
    final completer = Completer<File?>();
    _cacheCompleters[trackId] = completer;

    try {
      debugPrint('📥 Caching track: ${track.name}');
      final file = await _cacheManager!.getSingleFile(url, key: trackId);
      debugPrint('✅ Cached track: ${track.name}');
      unawaited(_trimToBudget(protect: {trackId}));

      // Extract waveform in background if not already exists
      if (WaveformService.instance.isAvailable) {
        final hasWaveform = await WaveformService.instance.hasWaveform(track.id);
        if (!hasWaveform) {
          unawaited(WaveformService.instance.extractWaveformInBackground(
            track.id,
            file.path,
          ));
        }
      }

      completer.complete(file);
      return file;
    } catch (e) {
      debugPrint('❌ Failed to cache track ${track.name}: $e');
      completer.complete(null);
      return null;
    } finally {
      _cachingInProgress.remove(trackId);
      _cacheCompleters.remove(trackId);
    }
  }
  
  /// Pre-cache multiple tracks in the background (e.g., album tracks)
  /// Caches tracks in order, starting from the specified index
  /// Uses a semaphore to allow 2 concurrent downloads for better performance
  Future<void> cacheAlbumTracks(
    List<JellyfinTrack> tracks, {
    int startIndex = 0,
    int? maxTracks,
    String? Function(JellyfinTrack track)? urlFor,
  }) async {
    if (tracks.isEmpty) return;

    final endIndex = maxTracks != null
        ? (startIndex + maxTracks).clamp(0, tracks.length)
        : tracks.length;

    final trackCount = endIndex - startIndex;
    debugPrint('🎵 Pre-caching $trackCount tracks starting from index $startIndex');

    // Allow 2 concurrent precache operations for better performance
    const maxConcurrent = 2;
    int activeCount = 0;
    int nextIndex = startIndex;
    final allDone = Completer<void>();

    void startNext() {
      while (activeCount < maxConcurrent && nextIndex < endIndex) {
        final trackIndex = nextIndex++;
        activeCount++;
        final track = tracks[trackIndex];
        _cacheTrackSilently(track, streamUrl: urlFor?.call(track)).whenComplete(() {
          activeCount--;
          if (nextIndex < endIndex) {
            startNext();
          } else if (activeCount == 0) {
            if (!allDone.isCompleted) allDone.complete();
          }
        });
      }
    }

    startNext();

    // If no tracks to cache, complete immediately
    if (trackCount == 0) return;

    await allDone.future;
  }

  /// Smart pre-cache of upcoming tracks, honouring the user's settings.
  ///
  /// [tracks] - the upcoming tracks to cache, already limited to the user's
  ///   pre-cache count (the caller skips downloaded tracks).
  /// [urlFor] - URL to cache each track from. Pass the URL playback would
  ///   stream (i.e. the user's streaming quality) so a pre-cached track costs
  ///   the same bandwidth as streaming it, instead of always pulling the
  ///   original (often lossless) file. Falls back to the original file.
  /// [wifiOnly] - if true, only cache when on Wi-Fi.
  /// At most [maxConcurrent] downloads run at once so pre-caching doesn't
  /// starve the stream that is playing.
  Future<void> smartPreCacheQueue({
    required List<JellyfinTrack> tracks,
    String? Function(JellyfinTrack track)? urlFor,
    required bool wifiOnly,
    ConnectivityService? connectivityService,
    int maxConcurrent = 2,
  }) async {
    if (tracks.isEmpty) return;

    // Check WiFi-only restriction
    if (wifiOnly) {
      final isWifi = await connectivityService?.isOnWifi() ?? false;
      if (!isWifi) {
        debugPrint('📦 Smart cache: Skipped (WiFi-only enabled, not on WiFi)');
        return;
      }
    }

    debugPrint('📦 Smart cache: Pre-caching ${tracks.length} upcoming tracks');

    var next = 0;
    Future<void> worker() async {
      while (next < tracks.length) {
        final track = tracks[next++];
        await _cacheTrackSilently(track, streamUrl: urlFor?.call(track));
      }
    }

    await Future.wait([
      for (var i = 0; i < maxConcurrent.clamp(1, tracks.length); i++) worker(),
    ]);
  }

  Future<void> _cacheTrackSilently(JellyfinTrack track, {String? streamUrl}) async {
    try {
      await cacheTrack(track, streamUrl: streamUrl);
    } catch (e) {
      // Silently ignore errors during background caching
    }
  }
  
  /// Remove a specific track from cache
  Future<void> removeFromCache(String trackId) async {
    if (_cacheManager == null) return;

    try {
      await _cacheManager!.removeFile(trackId);
      debugPrint('🗑️ Removed from cache: $trackId');
    } catch (e) {
      debugPrint('⚠️ Error removing from cache: $e');
    }
  }
  
  /// Clear all cached audio files
  Future<void> clearCache() async {
    int deletedCount = 0;
    int deletedBytes = 0;

    try {
      // Clear flutter_cache_manager's internal database
      if (_cacheManager != null) {
        await _cacheManager!.emptyCache();
      }
      // Also manually delete files from all cache directories
      final tempDir = await getTemporaryDirectory();
      final possibleDirs = [
        Directory(path.join(tempDir.path, _cacheKey)),
        Directory(path.join(tempDir.path, 'libCachedImageData')),
        Directory(path.join(tempDir.path, 'flutter_cache')),
      ];

      for (final dir in possibleDirs) {
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) {
              final fileName = path.basename(entity.path);
              // Skip database files
              if (!fileName.endsWith('.json') && !fileName.endsWith('.db')) {
                try {
                  final size = await entity.length();
                  await entity.delete();
                  deletedCount++;
                  deletedBytes += size;
                } catch (e) {
                  debugPrint('⚠️ Could not delete ${entity.path}: $e');
                }
              }
            }
          }
        }
      }

      // Clear in-progress tracking
      _cachingInProgress.clear();
      _cacheCompleters.clear();

      debugPrint('🗑️ Audio cache cleared: $deletedCount files, ${(deletedBytes / (1024 * 1024)).toStringAsFixed(2)} MB');
    } catch (e) {
      debugPrint('⚠️ Error clearing cache: $e');
    }
  }
  
  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    if (_cacheManager == null) {
      return {'initialized': false, 'fileCount': 0, 'totalSizeBytes': 0};
    }

    try {
      // flutter_cache_manager stores files in temp dir with cache key subfolder
      final tempDir = await getTemporaryDirectory();
      int fileCount = 0;
      int totalSize = 0;
      final List<String> cachedFiles = [];

      // Search for cache files in flutter_cache_manager's location
      // It stores files in: temp_dir/libCachedImageData (for images) and similar for audio
      // Also check the cache key folder
      final possibleDirs = [
        Directory(path.join(tempDir.path, _cacheKey)),
        Directory(path.join(tempDir.path, 'libCachedImageData')),
        Directory(path.join(tempDir.path, 'flutter_cache')),
      ];

      for (final dir in possibleDirs) {
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) {
              // Skip database files, only count audio files
              final fileName = path.basename(entity.path);
              if (!fileName.endsWith('.json') && !fileName.endsWith('.db')) {
                fileCount++;
                totalSize += await entity.length();
                cachedFiles.add(fileName);
              }
            }
          }
        }
      }

      return {
        'initialized': true,
        'fileCount': fileCount,
        'totalSizeBytes': totalSize,
        'totalSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
        'cachingInProgress': _cachingInProgress.length,
        'cachedFiles': cachedFiles,
      };
    } catch (e) {
      debugPrint('⚠️ Error getting cache stats: $e');
      return {'initialized': true, 'error': e.toString(), 'fileCount': 0, 'totalSizeBytes': 0};
    }
  }

  /// Get list of cached track IDs.
  ///
  /// Files on disk are named by flutter_cache_manager (random UUIDs), so the
  /// IDs come from the cache database, whose keys are track IDs.
  Future<List<String>> getCachedTrackIds() async {
    if (_cacheManager == null) {
      return [];
    }

    try {
      final objects = await _allCacheObjects();
      return {for (final o in objects) o.key}.toList();
    } catch (e) {
      debugPrint('⚠️ Error getting cached track IDs: $e');
      return [];
    }
  }

  Future<List<CacheObject>> _allCacheObjects() async {
    final repo = _repo;
    if (repo == null) return const [];
    // Idempotent: shares the connection CacheManager's store already opened.
    await repo.open();
    return repo.getAllObjects();
  }

  /// Evict least-recently-used files once the cache exceeds
  /// [_maxCacheBytes]. Throttled; never evicts keys in [protect].
  Future<void> _trimToBudget({Set<String> protect = const {}}) async {
    if (_trimming || _cacheManager == null) return;
    final last = _lastTrim;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _trimming = true;
    _lastTrim = DateTime.now();
    try {
      final dir = await _cacheDirPath();
      final entries = <CacheEntryInfo>[];
      for (final o in await _allCacheObjects()) {
        var bytes = o.length;
        if (bytes == null) {
          final file = File(path.join(dir, o.relativePath));
          bytes = await file.exists() ? await file.length() : 0;
        }
        entries.add(CacheEntryInfo(
          key: o.key,
          bytes: bytes,
          lastUsed: o.touched ?? DateTime.fromMillisecondsSinceEpoch(0),
        ));
      }
      final evict = cacheKeysToEvict(
        entries,
        maxBytes: _maxCacheBytes,
        protectedKeys: {...protect, ..._cachingInProgress},
      );
      for (final key in evict) {
        await _cacheManager?.removeFile(key);
      }
      if (evict.isNotEmpty) {
        debugPrint('🗑️ Audio cache over budget: evicted ${evict.length} files');
      }
    } catch (e) {
      debugPrint('⚠️ Audio cache trim failed: $e');
    } finally {
      _trimming = false;
    }
  }

  /// Dispose the cache manager
  Future<void> dispose() async {
    await _cacheManager?.dispose();
    _cacheManager = null;
    _repo = null;
    _initFuture = null;
    _cachingInProgress.clear();
    _cacheCompleters.clear();
  }
}
