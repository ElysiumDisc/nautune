import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/chart_data.dart';

/// Service for caching generated rhythm game charts.
/// Stores charts as JSON files for fast loading on replay.
class ChartCacheService extends ChangeNotifier {
  static ChartCacheService? _instance;
  static ChartCacheService get instance => _instance ??= ChartCacheService._();

  ChartCacheService._();

  Directory? _cacheDir;
  final Map<String, ChartData> _cache = {};
  bool _initialized = false;

  // Through the Fire and Flames - legendary unlock for perfect scores
  // Bundled in assets - no download needed!
  static const String _legendaryAssetPath = 'assets/fire/Through The Fire And Flames.mp3';
  static const String _legendaryTrackId = 'dragonforce_ttfaf';
  static const String _legendaryTrackName = 'Through the Fire and Flames';
  static const String _legendaryArtistName = 'DragonForce';

  bool _legendaryUnlocked = false;
  bool _legendaryCopying = false;
  File? _legendaryTrackFile;

  /// Whether the service is initialized
  bool get isInitialized => _initialized;

  /// Initialize the cache service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      _cacheDir = Directory('${appDir.path}/charts');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      // Load existing charts into memory
      await _loadAllCharts();

      // Load legendary track unlock state
      await _loadLegendaryUnlockState();

      _initialized = true;
      debugPrint('🎮 ChartCache: Initialized with ${_cache.length} cached charts');
    } catch (e) {
      debugPrint('🎮 ChartCache: Init error - $e');
    }
  }

  /// Load all cached charts from disk
  Future<void> _loadAllCharts() async {
    if (_cacheDir == null) return;

    try {
      final files = await _cacheDir!.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final chart = ChartData.fromJson(json);
            _cache[chart.trackId] = chart;
          } catch (e) {
            debugPrint('🎮 ChartCache: Error loading ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('🎮 ChartCache: Error listing charts: $e');
    }
  }

  /// Check if a chart exists for a track
  bool hasChart(String trackId) => _cache.containsKey(trackId);

  /// Get a cached chart (null if not cached)
  ChartData? getChart(String trackId) => _cache[trackId];

  /// Get all cached charts
  List<ChartData> getAllCharts() {
    final charts = _cache.values.toList();
    // Sort by most recently played/generated
    charts.sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
    return charts;
  }

  /// Save a chart to cache
  Future<void> saveChart(ChartData chart) async {
    if (_cacheDir == null) await initialize();
    if (_cacheDir == null) return;

    try {
      final file = File('${_cacheDir!.path}/${chart.trackId}.json');
      final json = jsonEncode(chart.toJson());
      await file.writeAsString(json);
      _cache[chart.trackId] = chart;
      notifyListeners();
      debugPrint('🎮 ChartCache: Saved chart for ${chart.trackName}');
    } catch (e) {
      debugPrint('🎮 ChartCache: Error saving chart: $e');
    }
  }

  /// Update a chart's scores
  Future<void> updateScore(String trackId, int score, int maxMultiplier) async {
    final existing = _cache[trackId];
    if (existing == null) return;

    final updated = existing.copyWithScore(
      highScore: score > existing.highScore ? score : existing.highScore,
      maxMultiplier: maxMultiplier > existing.maxMultiplier
          ? maxMultiplier
          : existing.maxMultiplier,
      playCount: existing.playCount + 1,
    );

    await saveChart(updated);
  }

  /// Delete a chart from cache
  Future<void> deleteChart(String trackId) async {
    if (_cacheDir == null) return;

    try {
      final file = File('${_cacheDir!.path}/$trackId.json');
      if (await file.exists()) {
        await file.delete();
      }
      _cache.remove(trackId);
      notifyListeners();
      debugPrint('🎮 ChartCache: Deleted chart for $trackId');
    } catch (e) {
      debugPrint('🎮 ChartCache: Error deleting chart: $e');
    }
  }

  /// Delete all cached charts
  Future<void> clearAllCharts() async {
    if (_cacheDir == null) return;

    try {
      final files = await _cacheDir!.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.json')) {
          await entity.delete();
        }
      }
      _cache.clear();
      notifyListeners();
      debugPrint('🎮 ChartCache: Cleared all charts');
    } catch (e) {
      debugPrint('🎮 ChartCache: Error clearing charts: $e');
    }
  }

  /// Get total storage used by charts (in bytes)
  Future<int> getTotalStorageBytes() async {
    if (_cacheDir == null) return 0;

    try {
      int total = 0;
      final files = await _cacheDir!.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.json')) {
          final stat = await entity.stat();
          total += stat.size;
        }
      }
      return total;
    } catch (e) {
      return 0;
    }
  }

  /// Format storage size for display
  Future<String> getFormattedStorageSize() async {
    final bytes = await getTotalStorageBytes();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Get chart count
  int get chartCount => _cache.length;

  /// Get aggregate stats across all charts for profile display
  FretsOnFireStats getAggregateStats() {
    if (_cache.isEmpty) {
      return const FretsOnFireStats(
        totalSongsPlayed: 0,
        totalPlayCount: 0,
        totalNotesHit: 0,
        bestHighScore: 0,
        bestHighScoreTrack: null,
        bestHighScoreArtist: null,
        bestMaxMultiplier: 0,
      );
    }

    int totalPlays = 0;
    int bestScore = 0;
    String? bestScoreTrack;
    String? bestScoreArtist;
    int bestMultiplier = 0;
    int totalNotes = 0;

    for (final chart in _cache.values) {
      totalPlays += chart.playCount;
      totalNotes += chart.notes.length * chart.playCount;

      if (chart.highScore > bestScore) {
        bestScore = chart.highScore;
        bestScoreTrack = chart.trackName;
        bestScoreArtist = chart.artistName;
      }
      if (chart.maxMultiplier > bestMultiplier) {
        bestMultiplier = chart.maxMultiplier;
      }
    }

    return FretsOnFireStats(
      totalSongsPlayed: _cache.values.where((c) => c.playCount > 0).length,
      totalPlayCount: totalPlays,
      totalNotesHit: totalNotes,
      bestHighScore: bestScore,
      bestHighScoreTrack: bestScoreTrack,
      bestHighScoreArtist: bestScoreArtist,
      bestMaxMultiplier: bestMultiplier,
    );
  }

  /// Check if any games have been played
  bool get hasPlayedAnyGames => _cache.values.any((c) => c.playCount > 0);

  // ============================================================
  // LEGENDARY TRACK: Through the Fire and Flames
  // Unlocked by getting a PERFECT score (100% accuracy) on any song
  // ============================================================

  /// Whether the legendary track is unlocked
  bool get isLegendaryUnlocked => _legendaryUnlocked;

  /// Whether the legendary track is currently being copied from assets
  bool get isLegendaryCopying => _legendaryCopying;

  /// Whether the legendary track is ready to play (copied from assets)
  bool get isLegendaryReady => _legendaryTrackFile?.existsSync() ?? false;

  /// Get the legendary track file path (null if not downloaded)
  String? get legendaryTrackPath => _legendaryTrackFile?.path;

  /// Legendary track info
  String get legendaryTrackName => _legendaryTrackName;
  String get legendaryArtistName => _legendaryArtistName;
  String get legendaryTrackId => _legendaryTrackId;

  /// Unlock the legendary track (called when player gets a perfect score)
  Future<void> unlockLegendaryTrack() async {
    if (_legendaryUnlocked) return;

    _legendaryUnlocked = true;
    await _saveLegendaryUnlockState();
    notifyListeners();
    debugPrint('🔥🎸 LEGENDARY UNLOCKED: Through the Fire and Flames!');
  }

  /// Check if a score qualifies as perfect (100% accuracy, no misses)
  bool isPerfectScore(int perfectHits, int goodHits, int missedNotes, int totalNotes) {
    if (totalNotes == 0) return false;
    // Perfect = hit every note (perfect or good counts), no misses
    return missedNotes == 0 && (perfectHits + goodHits) == totalNotes;
  }

  /// Copy the legendary track from bundled assets to documents directory
  /// Can be called regardless of unlock state (for demo/offline mode)
  Future<bool> prepareLegendaryTrack() async {
    if (_legendaryCopying) return false;
    if (isLegendaryReady) return true;

    _legendaryCopying = true;
    notifyListeners();

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final legendaryDir = Directory('${appDir.path}/legendary');
      if (!await legendaryDir.exists()) {
        await legendaryDir.create(recursive: true);
      }

      final filePath = '${legendaryDir.path}/through_the_fire_and_flames.mp3';
      final file = File(filePath);

      debugPrint('🔥 Copying Through the Fire and Flames from assets...');

      // Copy from bundled assets to documents directory
      final byteData = await rootBundle.load(_legendaryAssetPath);
      final bytes = byteData.buffer.asUint8List();
      await file.writeAsBytes(bytes);

      _legendaryTrackFile = file;
      _legendaryCopying = false;
      notifyListeners();

      debugPrint('🔥🎸 Ready: Through the Fire and Flames (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
      return true;
    } catch (e) {
      debugPrint('🔥 Copy error: $e');
      _legendaryCopying = false;
      notifyListeners();
      return false;
    }
  }

  /// Load legendary unlock state from disk
  Future<void> _loadLegendaryUnlockState() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final stateFile = File('${appDir.path}/legendary/unlock_state.json');
      if (await stateFile.exists()) {
        final json = jsonDecode(await stateFile.readAsString());
        _legendaryUnlocked = json['unlocked'] == true;
      }

      // Check if track file exists
      final trackFile = File('${appDir.path}/legendary/through_the_fire_and_flames.mp3');
      if (await trackFile.exists()) {
        _legendaryTrackFile = trackFile;
      }

      debugPrint('🔥 Legendary state: unlocked=$_legendaryUnlocked, ready=$isLegendaryReady');
    } catch (e) {
      debugPrint('🔥 Error loading legendary state: $e');
    }
  }

  /// Save legendary unlock state to disk
  Future<void> _saveLegendaryUnlockState() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final legendaryDir = Directory('${appDir.path}/legendary');
      if (!await legendaryDir.exists()) {
        await legendaryDir.create(recursive: true);
      }

      final stateFile = File('${legendaryDir.path}/unlock_state.json');
      await stateFile.writeAsString(jsonEncode({'unlocked': _legendaryUnlocked}));
    } catch (e) {
      debugPrint('🔥 Error saving legendary state: $e');
    }
  }
}

/// Aggregate stats for Frets on Fire across all charts
class FretsOnFireStats {
  final int totalSongsPlayed;
  final int totalPlayCount;
  final int totalNotesHit;
  final int bestHighScore;
  final String? bestHighScoreTrack;
  final String? bestHighScoreArtist;
  final int bestMaxMultiplier;

  const FretsOnFireStats({
    required this.totalSongsPlayed,
    required this.totalPlayCount,
    required this.totalNotesHit,
    required this.bestHighScore,
    this.bestHighScoreTrack,
    this.bestHighScoreArtist,
    required this.bestMaxMultiplier,
  });

  String get formattedHighScore {
    if (bestHighScore >= 1000000) {
      return '${(bestHighScore / 1000000).toStringAsFixed(1)}M';
    } else if (bestHighScore >= 1000) {
      return '${(bestHighScore / 1000).toStringAsFixed(1)}K';
    }
    return bestHighScore.toString();
  }

  String get formattedNotesHit {
    if (totalNotesHit >= 1000000) {
      return '${(totalNotesHit / 1000000).toStringAsFixed(1)}M';
    } else if (totalNotesHit >= 1000) {
      return '${(totalNotesHit / 1000).toStringAsFixed(1)}K';
    }
    return totalNotesHit.toString();
  }
}

/// Storage stats for a single chart
class ChartStorageStats {
  final String trackId;
  final String trackName;
  final String artistName;
  final int noteCount;
  final int highScore;
  final int maxMultiplier;
  final int playCount;
  final DateTime generatedAt;
  final int fileSizeBytes;

  const ChartStorageStats({
    required this.trackId,
    required this.trackName,
    required this.artistName,
    required this.noteCount,
    required this.highScore,
    required this.maxMultiplier,
    required this.playCount,
    required this.generatedAt,
    required this.fileSizeBytes,
  });

  String get formattedSize {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
  }

  String get formattedDate {
    return '${generatedAt.month}/${generatedAt.day}/${generatedAt.year}';
  }
}
