import 'dart:ui' show Color;

/// Shared palette cache to avoid duplicating color extraction across screens.
/// All screens (FullPlayer, MiniPlayer, AlbumDetail, ArtistDetail) share this
/// single cache, reducing memory usage by ~4x and avoiding redundant extraction.
class PaletteCacheService {
  PaletteCacheService._();
  static final PaletteCacheService instance = PaletteCacheService._();

  static const int maxCacheSize = 50;

  final Map<String, List<Color>> _cache = {};
  final List<String> _order = [];

  /// Get cached palette for [key], or null if not cached.
  List<Color>? get(String key) => _cache[key];

  /// Store palette for [key] with FIFO eviction.
  void put(String key, List<Color> colors) {
    if (_cache.containsKey(key)) return;
    if (_cache.length >= maxCacheSize && _order.isNotEmpty) {
      final oldest = _order.removeAt(0);
      _cache.remove(oldest);
    }
    _cache[key] = colors;
    _order.add(key);
  }

  /// Check if a key is cached.
  bool containsKey(String key) => _cache.containsKey(key);
}
