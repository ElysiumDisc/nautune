import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/jellyfin_album.dart';

/// Service for pre-warming (pre-caching) images to improve perceived performance
class ImagePrewarmService {
  final JellyfinService _jellyfinService;
  final Set<String> _prewarmingUrls = {};

  /// LRU cache for prewarmed URLs with max size limit to prevent memory bloat
  static const int _maxPrewarmedSize = 500;
  final List<String> _prewarmedOrder = []; // Track insertion order for LRU
  final Set<String> _prewarmedUrls = {};
  final Map<String, Timer> _cleanupTimers = {}; // Tracked cleanup timers

  /// Whether image prewarming is enabled (disabled in offline mode).
  bool enabled = true;

  ImagePrewarmService({required JellyfinService jellyfinService})
      : _jellyfinService = jellyfinService;

  /// Pre-warm album art for a list of tracks (non-blocking)
  void prewarmTrackImages(List<JellyfinTrack> tracks) {
    for (final track in tracks) {
      _prewarmTrackImage(track);
    }
  }

  /// Pre-warm album art for a list of albums (non-blocking)
  void prewarmAlbumImages(List<JellyfinAlbum> albums) {
    for (final album in albums) {
      _prewarmAlbumImage(album);
    }
  }

  /// Pre-warm a single track's album art
  void _prewarmTrackImage(JellyfinTrack track) {
    String? imageTag = track.primaryImageTag ?? track.albumPrimaryImageTag ?? track.parentThumbImageTag;
    String? itemId = imageTag != null ? (track.albumId ?? track.id) : null;

    if (itemId == null || imageTag == null) return;

    _prewarmImage(itemId, imageTag);
  }

  /// Pre-warm a single album's art
  void _prewarmAlbumImage(JellyfinAlbum album) {
    final imageTag = album.primaryImageTag;
    if (imageTag == null) return;

    _prewarmImage(album.id, imageTag);
  }

  /// Pre-warm a single image by URL
  void _prewarmImage(String itemId, String imageTag) {
    if (!enabled) return;
    final imageUrl = _jellyfinService.buildImageUrl(
      itemId: itemId,
      tag: imageTag,
      maxWidth: 400,
    );

    // Skip if already prewarming or prewarmed
    if (_prewarmingUrls.contains(imageUrl) || _prewarmedUrls.contains(imageUrl)) {
      return;
    }

    _prewarmingUrls.add(imageUrl);

    try {
      final provider = CachedNetworkImageProvider(
        imageUrl,
        headers: _jellyfinService.imageHeaders(),
      );

      // Use resolve to trigger the image load into cache
      final stream = provider.resolve(const ImageConfiguration());

      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, synchronousCall) {
          _addToPrewarmedCache(imageUrl);
          _prewarmingUrls.remove(imageUrl);
          stream.removeListener(listener);
        },
        onError: (exception, stackTrace) {
          _prewarmingUrls.remove(imageUrl);
          stream.removeListener(listener);
          debugPrint('ImagePrewarm: Failed to prewarm: $exception');
        },
      );

      stream.addListener(listener);

      // Auto-cleanup after timeout (tracked timer to prevent leaks)
      _cleanupTimers[imageUrl]?.cancel();
      _cleanupTimers[imageUrl] = Timer(const Duration(seconds: 15), () {
        if (_prewarmingUrls.contains(imageUrl)) {
          _prewarmingUrls.remove(imageUrl);
          stream.removeListener(listener);
        }
        _cleanupTimers.remove(imageUrl);
      });
    } catch (e) {
      _prewarmingUrls.remove(imageUrl);
      debugPrint('ImagePrewarm: Error prewarming image: $e');
    }
  }

  /// Pre-warm images for the next N tracks in the queue
  void prewarmQueueImages(List<JellyfinTrack> queue, int currentIndex, {int count = 3}) {
    final startIndex = currentIndex + 1;
    final endIndex = (startIndex + count).clamp(0, queue.length);

    if (startIndex >= queue.length) return;

    final tracksToPrewarm = queue.sublist(startIndex, endIndex);
    prewarmTrackImages(tracksToPrewarm);

    debugPrint('ImagePrewarm: Prewarming ${tracksToPrewarm.length} upcoming queue images');
  }

  /// Add URL to prewarmed cache with LRU eviction
  void _addToPrewarmedCache(String url) {
    // If already in cache, move to end (most recently used)
    if (_prewarmedUrls.contains(url)) {
      _prewarmedOrder.remove(url);
      _prewarmedOrder.add(url);
      return;
    }

    // Evict oldest entries if at capacity
    while (_prewarmedUrls.length >= _maxPrewarmedSize && _prewarmedOrder.isNotEmpty) {
      final oldest = _prewarmedOrder.removeAt(0);
      _prewarmedUrls.remove(oldest);
    }

    // Add new entry
    _prewarmedUrls.add(url);
    _prewarmedOrder.add(url);
  }

  /// Clear the prewarmed cache tracking (doesn't clear actual image cache)
  void clearTracking() {
    _prewarmingUrls.clear();
    _prewarmedUrls.clear();
    _prewarmedOrder.clear();
    for (final timer in _cleanupTimers.values) {
      timer.cancel();
    }
    _cleanupTimers.clear();
  }

  /// Get stats about prewarming
  Map<String, int> get stats => {
    'prewarming': _prewarmingUrls.length,
    'prewarmed': _prewarmedUrls.length,
  };
}
