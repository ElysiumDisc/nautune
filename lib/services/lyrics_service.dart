import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';

/// Represents a single line of lyrics with optional timing
class LyricLine {
  final String text;
  final int? startTicks; // In Jellyfin ticks (100ns units)
  final int? endTicks;

  LyricLine({
    required this.text,
    this.startTicks,
    this.endTicks,
  });

  bool get isSynced => startTicks != null;

  Map<String, dynamic> toJson() => {
    'text': text,
    'startTicks': startTicks,
    'endTicks': endTicks,
  };

  factory LyricLine.fromJson(Map<String, dynamic> json) => LyricLine(
    text: json['text'] as String,
    startTicks: json['startTicks'] as int?,
    endTicks: json['endTicks'] as int?,
  );
}

/// Result of a lyrics fetch operation
class LyricsResult {
  final List<LyricLine> lines;
  final String source; // 'jellyfin', 'lrclib', 'lyricsovh', 'cache'
  final bool isSynced;

  LyricsResult({
    required this.lines,
    required this.source,
  }) : isSynced = lines.any((l) => l.isSynced);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'lines': lines.map((l) => l.toJson()).toList(),
    'source': source,
  };

  factory LyricsResult.fromJson(Map<String, dynamic> json) => LyricsResult(
    lines: (json['lines'] as List<dynamic>)
        .map((l) => LyricLine.fromJson(Map<String, dynamic>.from(l as Map)))
        .toList(),
    source: json['source'] as String,
  );
}

/// Cached lyrics entry
class _CachedLyrics {
  final LyricsResult? result; // null means "no lyrics found"
  final DateTime cachedAt;

  _CachedLyrics({
    this.result,
    required this.cachedAt,
  });

  bool get isExpired {
    final age = DateTime.now().difference(cachedAt);
    // Cache for 30 days if lyrics found, 3 days if not (lyrics rarely change)
    final maxAge = result != null ? const Duration(days: 30) : const Duration(days: 3);
    return age > maxAge;
  }

  Map<String, dynamic> toJson() => {
    'result': result?.toJson(),
    'cachedAt': cachedAt.toIso8601String(),
  };

  factory _CachedLyrics.fromJson(Map<String, dynamic> json) => _CachedLyrics(
    result: json['result'] != null
        ? LyricsResult.fromJson(Map<String, dynamic>.from(json['result'] as Map))
        : null,
    cachedAt: DateTime.parse(json['cachedAt'] as String),
  );
}

/// Service for fetching lyrics from multiple sources with caching
class LyricsService {
  static const _boxName = 'nautune_lyrics';
  static const _lrclibBaseUrl = 'https://lrclib.net/api';
  static const _lyricsOvhBaseUrl = 'https://api.lyrics.ovh/v1';

  final JellyfinService _jellyfinService;
  Box? _box;
  bool _initialized = false;
  bool _isOffline = false;

  // In-flight requests to prevent duplicate fetches
  final Map<String, Completer<LyricsResult?>> _pendingRequests = {};

  LyricsService({required JellyfinService jellyfinService})
      : _jellyfinService = jellyfinService;

  /// Update offline state so cached lyrics are returned even if expired
  void setOffline(bool offline) {
    _isOffline = offline;
  }

  /// Initialize the service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _box = await Hive.openBox(_boxName);
      _initialized = true;
      debugPrint('LyricsService: Initialized');
    } catch (e) {
      debugPrint('LyricsService: Failed to initialize: $e');
    }
  }

  /// Get lyrics for a track, using cache and fallback chain
  Future<LyricsResult?> getLyrics(JellyfinTrack track) async {
    await initialize();

    final cacheKey = _getCacheKey(track);

    // Check if there's already a pending request for this track
    if (_pendingRequests.containsKey(cacheKey)) {
      return _pendingRequests[cacheKey]!.future;
    }

    final completer = Completer<LyricsResult?>();
    _pendingRequests[cacheKey] = completer;

    try {
      final result = await _fetchLyricsWithFallback(track, cacheKey);
      completer.complete(result);
      return result;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _pendingRequests.remove(cacheKey);
    }
  }

  Future<LyricsResult?> _fetchLyricsWithFallback(JellyfinTrack track, String cacheKey) async {
    // 1. Check cache first (accept expired cache when offline)
    final cached = _getFromCache(cacheKey);
    if (cached != null && (!cached.isExpired || _isOffline)) {
      debugPrint('LyricsService: Cache hit for "${track.name}"${_isOffline && cached.isExpired ? ' (expired, offline fallback)' : ''}');
      return cached.result;
    }

    // 2. Try Jellyfin API (server may have embedded lyrics)
    debugPrint('LyricsService: Trying Jellyfin for "${track.name}"');
    var result = await _fetchFromJellyfin(track);
    if (result != null && result.isNotEmpty) {
      _saveToCache(cacheKey, result);
      return result;
    }

    // 3. Try LRCLIB (synchronized lyrics)
    debugPrint('LyricsService: Trying LRCLIB for "${track.name}"');
    result = await _fetchFromLrclib(track);
    if (result != null && result.isNotEmpty) {
      _saveToCache(cacheKey, result);
      return result;
    }

    // 4. Try lyrics.ovh (plain text fallback)
    debugPrint('LyricsService: Trying lyrics.ovh for "${track.name}"');
    result = await _fetchFromLyricsOvh(track);
    if (result != null && result.isNotEmpty) {
      _saveToCache(cacheKey, result);
      return result;
    }

    // 5. Cache "no lyrics found" to avoid repeated lookups
    debugPrint('LyricsService: No lyrics found for "${track.name}"');
    _saveToCache(cacheKey, null);
    return null;
  }

  /// Fetch lyrics from Jellyfin server
  Future<LyricsResult?> _fetchFromJellyfin(JellyfinTrack track) async {
    try {
      final response = await _jellyfinService.getLyrics(track.id);
      if (response == null || response['Lyrics'] == null) {
        return null;
      }

      final rawLyrics = response['Lyrics'] as List<dynamic>;
      if (rawLyrics.isEmpty) return null;

      final lines = rawLyrics.map((item) {
        final map = item as Map<String, dynamic>;
        return LyricLine(
          text: map['Text'] as String? ?? '',
          startTicks: map['Start'] as int?,
        );
      }).where((l) => l.text.isNotEmpty).toList();

      if (lines.isEmpty) return null;

      return LyricsResult(lines: lines, source: 'jellyfin');
    } catch (e) {
      debugPrint('LyricsService: Jellyfin fetch failed: $e');
      return null;
    }
  }

  /// Fetch lyrics from LRCLIB (returns synchronized LRC format)
  Future<LyricsResult?> _fetchFromLrclib(JellyfinTrack track) async {
    try {
      final artist = _normalizeArtist(track.artists.firstOrNull ?? '');
      final title = track.name;
      final album = track.album ?? '';
      final durationSeconds = track.duration?.inSeconds;

      if (artist.isEmpty || title.isEmpty) return null;

      final uri = Uri.parse('$_lrclibBaseUrl/get').replace(queryParameters: {
        'artist_name': artist,
        'track_name': title,
        if (album.isNotEmpty) 'album_name': album,
        if (durationSeconds != null) 'duration': durationSeconds.toString(),
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Prefer synced lyrics, fall back to plain
      final syncedLyrics = data['syncedLyrics'] as String?;
      final plainLyrics = data['plainLyrics'] as String?;

      if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
        final lines = _parseLrcFormat(syncedLyrics);
        if (lines.isNotEmpty) {
          return LyricsResult(lines: lines, source: 'lrclib');
        }
      }

      if (plainLyrics != null && plainLyrics.isNotEmpty) {
        final lines = plainLyrics
            .split('\n')
            .map((text) => LyricLine(text: text.trim()))
            .where((l) => l.text.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          return LyricsResult(lines: lines, source: 'lrclib');
        }
      }

      return null;
    } catch (e) {
      debugPrint('LyricsService: LRCLIB fetch failed: $e');
      return null;
    }
  }

  /// Fetch lyrics from lyrics.ovh (plain text only)
  Future<LyricsResult?> _fetchFromLyricsOvh(JellyfinTrack track) async {
    try {
      final artist = _normalizeArtist(track.artists.firstOrNull ?? '');
      final title = track.name;

      if (artist.isEmpty || title.isEmpty) return null;

      // URL encode the artist and title
      final encodedArtist = Uri.encodeComponent(artist);
      final encodedTitle = Uri.encodeComponent(title);

      final uri = Uri.parse('$_lyricsOvhBaseUrl/$encodedArtist/$encodedTitle');

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final lyrics = data['lyrics'] as String?;

      if (lyrics == null || lyrics.isEmpty) return null;

      final lines = lyrics
          .split('\n')
          .map((text) => LyricLine(text: text.trim()))
          .where((l) => l.text.isNotEmpty)
          .toList();

      if (lines.isEmpty) return null;

      return LyricsResult(lines: lines, source: 'lyricsovh');
    } catch (e) {
      debugPrint('LyricsService: lyrics.ovh fetch failed: $e');
      return null;
    }
  }

  /// Parse LRC format lyrics (e.g., "[00:12.34] Lyrics line")
  List<LyricLine> _parseLrcFormat(String lrcContent) {
    final lines = <LyricLine>[];
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final line in lrcContent.split('\n')) {
      final match = regex.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final millisStr = match.group(3)!;
        // Handle both 2-digit (centiseconds) and 3-digit (milliseconds) formats
        final millis = millisStr.length == 2
            ? int.parse(millisStr) * 10
            : int.parse(millisStr);
        final text = match.group(4)?.trim() ?? '';

        if (text.isNotEmpty) {
          // Convert to Jellyfin ticks (100ns units)
          // 1ms = 10,000 ticks
          final totalMs = (minutes * 60 + seconds) * 1000 + millis;
          final ticks = totalMs * 10000;

          lines.add(LyricLine(
            text: text,
            startTicks: ticks,
          ));
        }
      }
    }

    return lines;
  }

  /// Normalize artist name for better matching
  String _normalizeArtist(String artist) {
    // Remove common suffixes like "feat.", "ft.", "featuring", etc.
    var normalized = artist
        .replaceAll(RegExp(r'\s*(feat\.?|ft\.?|featuring)\s+.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\(.*\)'), '') // Remove parentheticals
        .replaceAll(RegExp(r'\s*\[.*\]'), '') // Remove brackets
        .trim();

    return normalized.isNotEmpty ? normalized : artist;
  }

  /// Generate cache key for a track
  String _getCacheKey(JellyfinTrack track) {
    // Use track ID as primary key, but also include artist/title for external lookups
    return 'lyrics_${track.id}';
  }

  /// Get cached lyrics
  _CachedLyrics? _getFromCache(String key) {
    if (_box == null) return null;

    try {
      final raw = _box!.get(key);
      if (raw == null) return null;

      final Map<String, dynamic> json;
      if (raw is String) {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } else if (raw is Map) {
        json = Map<String, dynamic>.from(raw);
      } else {
        return null;
      }

      return _CachedLyrics.fromJson(json);
    } catch (e) {
      debugPrint('LyricsService: Cache read error: $e');
      return null;
    }
  }

  /// Save lyrics to cache
  Future<void> _saveToCache(String key, LyricsResult? result) async {
    if (_box == null) return;

    try {
      final cached = _CachedLyrics(
        result: result,
        cachedAt: DateTime.now(),
      );
      await _box!.put(key, jsonEncode(cached.toJson()));
    } catch (e) {
      debugPrint('LyricsService: Cache write error: $e');
    }
  }

  /// Force refresh lyrics for a track (ignores cache)
  Future<LyricsResult?> refreshLyrics(JellyfinTrack track) async {
    await initialize();

    final cacheKey = _getCacheKey(track);

    // Clear cache for this track
    await _box?.delete(cacheKey);

    // Fetch fresh
    return _fetchLyricsWithFallback(track, cacheKey);
  }

  /// Pre-fetch lyrics for a track (non-blocking)
  void prefetchLyrics(JellyfinTrack track) {
    getLyrics(track).catchError((e) {
      debugPrint('LyricsService: Prefetch failed for "${track.name}": $e');
      return null;
    });
  }

  /// Clear all cached lyrics
  Future<void> clearCache() async {
    await _box?.clear();
    debugPrint('LyricsService: Cache cleared');
  }
}
