import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../jellyfin/jellyfin_track.dart';

/// Service for pre-caching audio tracks for smoother playback.
/// Uses flutter_cache_manager for efficient file caching with automatic eviction.
class AudioCacheService {
  static AudioCacheService? _instance;
  static AudioCacheService get instance => _instance ??= AudioCacheService._();
  
  AudioCacheService._();
  
  CacheManager? _cacheManager;
  final Set<String> _cachingInProgress = {};
  final Map<String, Completer<File?>> _cacheCompleters = {};
  
  // Cache configuration
  static const int _maxCacheSize = 500; // Max number of cached files
  static const Duration _stalePeriod = Duration(days: 7);
  static const String _cacheKey = 'nautune_audio_cache';
  
  /// Initialize the cache manager
  Future<void> initialize() async {
    if (_cacheManager != null) return;
    
    final cacheDir = await _getCacheDirectory();
    _cacheManager = CacheManager(
      Config(
        _cacheKey,
        stalePeriod: _stalePeriod,
        maxNrOfCacheObjects: _maxCacheSize,
        repo: JsonCacheInfoRepository(databaseName: _cacheKey),
        fileService: HttpFileService(),
      ),
    );
    debugPrint('🎵 AudioCacheService initialized at: $cacheDir');
  }
  
  Future<String> _getCacheDirectory() async {
    final dir = await getTemporaryDirectory();
    return path.join(dir.path, 'audio_cache');
  }
  
  /// Get cached file path for a track, or null if not cached
  Future<File?> getCachedFile(String trackId) async {
    if (_cacheManager == null) return null;
    
    try {
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
  /// If [streamUrl] is provided, uses that URL instead of direct download URL
  /// (useful for caching transcoded streams to match playback quality)
  Future<File?> cacheTrack(JellyfinTrack track, {String? streamUrl}) async {
    if (_cacheManager == null) {
      await initialize();
    }

    // Use stream URL hash as cache key if provided (different quality = different cache)
    final trackId = streamUrl != null
        ? '${track.id}_${streamUrl.hashCode}'
        : track.id;

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
    final url = streamUrl ?? track.directDownloadUrl();
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
  Future<void> cacheAlbumTracks(
    List<JellyfinTrack> tracks, {
    int startIndex = 0,
    int? maxTracks,
  }) async {
    if (tracks.isEmpty) return;
    
    final endIndex = maxTracks != null 
        ? (startIndex + maxTracks).clamp(0, tracks.length)
        : tracks.length;
    
    debugPrint('🎵 Pre-caching ${endIndex - startIndex} tracks starting from index $startIndex');
    
    // Cache tracks sequentially to avoid overwhelming the network
    for (int i = startIndex; i < endIndex; i++) {
      // Don't await - let it cache in background
      unawaited(_cacheTrackSilently(tracks[i]));
      // Small delay between requests to be gentle on the server
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }
  
  Future<void> _cacheTrackSilently(JellyfinTrack track) async {
    try {
      await cacheTrack(track);
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
    if (_cacheManager == null) return;
    
    try {
      await _cacheManager!.emptyCache();
      debugPrint('🗑️ Audio cache cleared');
    } catch (e) {
      debugPrint('⚠️ Error clearing cache: $e');
    }
  }
  
  /// Get cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    if (_cacheManager == null) {
      return {'initialized': false};
    }
    
    try {
      final cacheDir = await _getCacheDirectory();
      final dir = Directory(cacheDir);
      int fileCount = 0;
      int totalSize = 0;
      
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            fileCount++;
            totalSize += await entity.length();
          }
        }
      }
      
      return {
        'initialized': true,
        'fileCount': fileCount,
        'totalSizeBytes': totalSize,
        'totalSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
        'cachingInProgress': _cachingInProgress.length,
      };
    } catch (e) {
      return {'initialized': true, 'error': e.toString()};
    }
  }
  
  /// Dispose the cache manager
  Future<void> dispose() async {
    await _cacheManager?.dispose();
    _cacheManager = null;
    _cachingInProgress.clear();
    _cacheCompleters.clear();
  }
}
