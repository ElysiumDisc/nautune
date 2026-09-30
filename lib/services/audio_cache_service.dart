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

  /// Cached copy of a track, or null if not cached.
  ///
  /// With [variant] (see [cacheVariantForUrl]) only a copy at that quality or
  /// better is returned, so a low-bitrate copy isn't replayed after the user
  /// raises streaming quality. Without it any copy is returned (offline
  /// playback, waveform and visualizer analysis), best quality first.
  Future<File?> getCachedFile(String trackId, {String? variant}) async {
    await initialize();
    if (_cacheManager == null) return null;

    try {
      final keys = variant != null
          ? cacheKeysForRequest(trackId, variant)
          : await _keysForTrack(trackId);
      for (final key in keys) {
        final fileInfo = await _cacheManager!.getFileFromCache(key);
        if (fileInfo != null && await fileInfo.file.exists()) {
          return fileInfo.file;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error checking cache for $trackId: $e');
    }
    return null;
  }

  /// Every cache key held for [trackId], original quality first.
  Future<List<String>> _keysForTrack(String trackId) async {
    final original = audioCacheKey(trackId, kOriginalCacheVariant);
    final keys = <String>[
      for (final o in await _allCacheObjects())
        if (trackIdFromCacheKey(o.key) == trackId) o.key,
    ];
    keys.sort((a, b) => (a == original ? 0 : 1) - (b == original ? 0 : 1));
    return keys;
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

    // Get the streaming URL
    final url = streamUrl ?? track.streamUrlOverride;
    if (url == null) {
      debugPrint('⚠️ No URL available for track: ${track.name}');
      return null;
    }

    // Keyed by track id + quality, so getCachedFile(id, variant: …) only
    // finds copies good enough for the quality the user streams at.
    final variant = cacheVariantForUrl(url);
    final key = audioCacheKey(track.id, variant);

    // Already caching this track - wait for it
    if (_cachingInProgress.contains(key)) {
      return _cacheCompleters[key]?.future;
    }

    // Check if already cached at this quality (or better)
    final existing = await getCachedFile(track.id, variant: variant);
    if (existing != null) {
      debugPrint('✅ Track already cached: ${track.name}');
      return existing;
    }

    // Start caching
    _cachingInProgress.add(key);
    final completer = Completer<File?>();
    _cacheCompleters[key] = completer;

    try {
      debugPrint('📥 Caching track: ${track.name} [$variant]');
      final file = await _cacheManager!.getSingleFile(url, key: key);
      debugPrint('✅ Cached track: ${track.name}');
      unawaited(_trimToBudget(protect: {key}));

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
      _cachingInProgress.remove(key);
      _cacheCompleters.remove(key);
    }
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
  
  /// Take over a file saved while streaming (stored under [key], see
  /// [audioCacheKey]) instead of downloading the track again.
  Future<void> adoptFile(String key, File file, String extension) async {
    await initialize();
    final manager = _cacheManager;
    if (manager == null) return;
    try {
      await manager.putFileStream(
        'nautune-stream://$key',
        file.openRead(),
        key: key,
        fileExtension: extension,
        maxAge: _stalePeriod,
      );
      unawaited(_trimToBudget(protect: {key}));
    } catch (e) {
      debugPrint('⚠️ Could not adopt streamed copy $key: $e');
    }
  }

  /// Remove every cached copy of a track
  Future<void> removeFromCache(String trackId) async {
    if (_cacheManager == null) return;

    try {
      for (final key in await _keysForTrack(trackId)) {
        await _cacheManager!.removeFile(key);
      }
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
      // Also delete files the database no longer tracks. Only the audio
      // cache's own folder: other caches (e.g. artwork in
      // libCachedImageData) are not ours to clear.
      final possibleDirs = [Directory(await _cacheDirPath())];

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
      int fileCount = 0;
      int totalSize = 0;
      final List<String> cachedFiles = [];

      // flutter_cache_manager keeps this cache's files in tmp/<cache key>
      // (artwork caches live elsewhere and are not counted).
      final possibleDirs = [Directory(await _cacheDirPath())];

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
  /// IDs come from the cache database, whose keys are `trackId@variant`.
  Future<List<String>> getCachedTrackIds() async {
    if (_cacheManager == null) {
      return [];
    }

    try {
      final objects = await _allCacheObjects();
      return {for (final o in objects) trackIdFromCacheKey(o.key)}.toList();
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
