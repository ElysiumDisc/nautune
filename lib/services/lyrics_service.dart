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

/// Outcome of one lyrics source: lyrics found, a definitive "this source
/// has none", or an error (network, 5xx, …) that says nothing about the
/// track and must not be cached as "no lyrics".
enum LyricsLookup { found, notFound, error }

/// Whether a lookup chain that found nothing may be cached as "no lyrics":
/// only when every source answered definitively.
@visibleForTesting
bool canCacheNoLyrics(Iterable<LyricsLookup> outcomes) =>
    outcomes.every((o) => o == LyricsLookup.notFound);

/// Parses LRC lyrics ("[00:12.34] Lyrics line") into timed lines, sorted by
/// time. Handles `[mm:ss]`, `[mm:ss.x]`…`[mm:ss.xxx]` and 3-digit minutes,
/// and lines with several timestamps (`[00:10.00][01:10.00]Chorus`, one line
/// each). Empty timed lines are kept: they mark instrumental breaks, so the
/// previous line doesn't stay highlighted through them. Returns no lines
/// when nothing has text.
@visibleForTesting
List<LyricLine> parseLrcLyrics(String lrcContent) {
  final lines = <LyricLine>[];
  final stamp = RegExp(r'^\s*\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

  for (var rest in lrcContent.split('\n')) {
    final startsMs = <int>[];
    for (var match = stamp.firstMatch(rest);
        match != null;
        match = stamp.firstMatch(rest)) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      // 1 digit = tenths, 2 = centiseconds, 3 = milliseconds.
      final millis = fraction == null
          ? 0
          : int.parse(fraction.padRight(3, '0'));
      startsMs.add((minutes * 60 + seconds) * 1000 + millis);
      rest = rest.substring(match.end);
    }
    if (startsMs.isEmpty) continue; // metadata ([ar:…]) or untimed text
    final text = rest.trim();
    for (final ms in startsMs) {
      // Jellyfin ticks (100ns units): 1ms = 10,000 ticks.
      lines.add(LyricLine(text: text, startTicks: ms * 10000));
    }
  }

  if (!lines.any((l) => l.text.isNotEmpty)) return const [];
  lines.sort((a, b) => a.startTicks!.compareTo(b.startTicks!));
  // Leading empty lines add nothing before the first words.
  while (lines.isNotEmpty && lines.first.text.isEmpty) {
    lines.removeAt(0);
  }
  return lines;
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
  final bool Function()? _isOfflineProvider;
  Box? _box;
  bool _initialized = false;
  bool _offlineFlag = false;

  // In-flight requests to prevent duplicate fetches
  final Map<String, Completer<LyricsResult?>> _pendingRequests = {};

  /// [isOffline], when given, is consulted on every lookup (preferred over
  /// [setOffline], which instances created outside the audio service never
  /// receive).
  LyricsService({
    required JellyfinService jellyfinService,
    bool Function()? isOffline,
  })  : _jellyfinService = jellyfinService,
        _isOfflineProvider = isOffline;

  bool get _isOffline => _offlineFlag || (_isOfflineProvider?.call() ?? false);

  /// Update offline state: cached lyrics (even expired) are returned and no
  /// network lookups are made.
  void setOffline(bool offline) {
    _offlineFlag = offline;
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

    // Offline: no network lookups (offline mode silences all traffic), and
    // nothing is cached — a miss here says nothing about the track.
    if (_isOffline) return null;

    final outcomes = <LyricsLookup>[];

    // 2. Jellyfin (embedded / sidecar lyrics), 3. LRCLIB (synced),
    // 4. lyrics.ovh (plain text).
    for (final source in <Future<(LyricsLookup, LyricsResult?)> Function(JellyfinTrack)>[
      _fetchFromJellyfin,
      _fetchFromLrclib,
      _fetchFromLyricsOvh,
    ]) {
      final (outcome, result) = await source(track);
      if (outcome == LyricsLookup.found && result != null && result.isNotEmpty) {
        _saveToCache(cacheKey, result);
        return result;
      }
      outcomes.add(outcome);
    }

    // 5. Cache "no lyrics found" only when every source said so; after a
    // network/server error, keep whatever we had (even expired) and retry
    // next time.
    if (canCacheNoLyrics(outcomes)) {
      debugPrint('LyricsService: No lyrics found for "${track.name}"');
      _saveToCache(cacheKey, null);
      return null;
    }
    debugPrint('LyricsService: Lookup failed for "${track.name}" (not cached)');
    return cached?.result;
  }

  /// Fetch lyrics from Jellyfin server
  Future<(LyricsLookup, LyricsResult?)> _fetchFromJellyfin(JellyfinTrack track) async {
    try {
      final response = await _jellyfinService.getLyrics(track.id);
      if (response == null || response['Lyrics'] is! List) {
        return (LyricsLookup.notFound, null);
      }

      final rawLyrics = response['Lyrics'] as List<dynamic>;
      final lines = rawLyrics
          .whereType<Map>()
          .map((map) {
            final start = map['Start'];
            return LyricLine(
              text: map['Text'] is String ? map['Text'] as String : '',
              startTicks: start is num ? start.toInt() : null,
            );
          })
          // Empty synced lines mark instrumental breaks (shown as ♫).
          .where((l) => l.text.isNotEmpty || l.isSynced)
          .toList();

      if (!lines.any((l) => l.text.isNotEmpty)) {
        return (LyricsLookup.notFound, null);
      }

      return (LyricsLookup.found, LyricsResult(lines: lines, source: 'jellyfin'));
    } catch (e) {
      debugPrint('LyricsService: Jellyfin fetch failed: ${e.runtimeType}');
      return (LyricsLookup.error, null);
    }
  }

  /// Fetch lyrics from LRCLIB (returns synchronized LRC format)
  Future<(LyricsLookup, LyricsResult?)> _fetchFromLrclib(JellyfinTrack track) async {
    try {
      final artist = _normalizeArtist(track.artists.firstOrNull ?? '');
      final title = track.name;
      final album = track.album ?? '';
      final durationSeconds = track.duration?.inSeconds;

      if (artist.isEmpty || title.isEmpty) return (LyricsLookup.notFound, null);

      final uri = Uri.parse('$_lrclibBaseUrl/get').replace(queryParameters: {
        'artist_name': artist,
        'track_name': title,
        if (album.isNotEmpty) 'album_name': album,
        if (durationSeconds != null) 'duration': durationSeconds.toString(),
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 404) return (LyricsLookup.notFound, null);
      if (response.statusCode != 200) return (LyricsLookup.error, null);

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Prefer synced lyrics, fall back to plain
      final syncedLyrics = data['syncedLyrics'] as String?;
      final plainLyrics = data['plainLyrics'] as String?;

      if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
        final lines = _parseLrcFormat(syncedLyrics);
        if (lines.isNotEmpty) {
          return (LyricsLookup.found, LyricsResult(lines: lines, source: 'lrclib'));
        }
      }

      if (plainLyrics != null && plainLyrics.isNotEmpty) {
        final lines = plainLyrics
            .split('\n')
            .map((text) => LyricLine(text: text.trim()))
            .where((l) => l.text.isNotEmpty)
            .toList();
        if (lines.isNotEmpty) {
          return (LyricsLookup.found, LyricsResult(lines: lines, source: 'lrclib'));
        }
      }

      return (LyricsLookup.notFound, null);
    } catch (e) {
      debugPrint('LyricsService: LRCLIB fetch failed: ${e.runtimeType}');
      return (LyricsLookup.error, null);
    }
  }

  /// Fetch lyrics from lyrics.ovh (plain text only)
  Future<(LyricsLookup, LyricsResult?)> _fetchFromLyricsOvh(JellyfinTrack track) async {
    try {
      final artist = _normalizeArtist(track.artists.firstOrNull ?? '');
      final title = track.name;

      if (artist.isEmpty || title.isEmpty) return (LyricsLookup.notFound, null);

      // URL encode the artist and title
      final encodedArtist = Uri.encodeComponent(artist);
      final encodedTitle = Uri.encodeComponent(title);

      final uri = Uri.parse('$_lyricsOvhBaseUrl/$encodedArtist/$encodedTitle');

      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 404) return (LyricsLookup.notFound, null);
      if (response.statusCode != 200) return (LyricsLookup.error, null);

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final lyrics = data['lyrics'] as String?;

      if (lyrics == null || lyrics.isEmpty) return (LyricsLookup.notFound, null);

      final lines = lyrics
          .split('\n')
          .map((text) => LyricLine(text: text.trim()))
          .where((l) => l.text.isNotEmpty)
          .toList();

      if (lines.isEmpty) return (LyricsLookup.notFound, null);

      return (LyricsLookup.found, LyricsResult(lines: lines, source: 'lyricsovh'));
    } catch (e) {
      debugPrint('LyricsService: lyrics.ovh fetch failed: ${e.runtimeType}');
      return (LyricsLookup.error, null);
    }
  }

  List<LyricLine> _parseLrcFormat(String lrcContent) =>
      parseLrcLyrics(lrcContent);

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
