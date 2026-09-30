import 'dart:collection' show ListBase;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/chart_data.dart';
import '../utils/backup_exclusion.dart';

/// Service for caching generated rhythm game charts.
/// Stores charts as JSON files for fast loading on replay.
///
/// Every chart on disk is listed in a lightweight catalog (scores and note
/// count, no notes) used for listings and stats; only the most recently used
/// full charts stay in memory.
class ChartCacheService extends ChangeNotifier {
  static ChartCacheService? _instance;
  static ChartCacheService get instance => _instance ??= ChartCacheService._();

  ChartCacheService._();

  Directory? _cacheDir;

  /// Full charts (with notes), most recently used last.
  final Map<String, ChartData> _cache = {};

  /// Every chart on disk, without its notes (see [_summaryOf]).
  final Map<String, ChartData> _catalog = {};
  bool _initialized = false;
  Future<void>? _initFuture;
  static const int _maxMemoryCacheSize = 20;

  // Through the Fire and Flames - legendary unlock for perfect scores
  // Bundled in assets - no download needed!
  static const String _legendaryAssetPath = 'assets/fire/Through The Fire And Flames.mp3';
  static const String _legendaryTrackId = 'dragonforce_ttfaf';
  static const String _legendaryTrackName = 'Through the Fire and Flames';
  static const String _legendaryArtistName = 'DragonForce';

  bool _legendaryUnlocked = false;
  Future<bool>? _legendaryCopy;
  File? _legendaryTrackFile;

  /// Size of the legendary track when it was fully copied (null = unknown).
  int? _legendaryTrackBytes;

  /// Whether the service is initialized
  bool get isInitialized => _initialized;

  /// Initialize the cache service. Concurrent calls share one load; a failed
  /// load can be retried.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();

      _cacheDir = Directory('${appDir.path}/charts');

      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
      await excludeFromBackup(_cacheDir!.path);

      // Catalog every chart on disk (parsed off the UI isolate)
      await _loadCatalog();

      // Load legendary track unlock state
      await _loadLegendaryUnlockState();

      _initialized = true;
      debugPrint('🎮 ChartCache: Initialized with ${_catalog.length} cached charts');
    } catch (e) {
      debugPrint('🎮 ChartCache: Init error - $e');
      _initFuture = null;
    }
  }

  /// Build the catalog from the chart files on disk.
  Future<void> _loadCatalog() async {
    if (_cacheDir == null) return;

    try {
      final summaries = await compute(_readCatalog, _cacheDir!.path);
      for (final summary in summaries) {
        // Charts saved while loading are newer.
        _catalog.putIfAbsent(summary.trackId, () => summary);
      }
    } catch (e) {
      debugPrint('🎮 ChartCache: Error listing charts: $e');
    }
  }

  /// Keep [chart] in memory (most recently used) and in the catalog.
  void _remember(ChartData chart) {
    _cache.remove(chart.trackId);
    _cache[chart.trackId] = chart;
    while (_cache.length > _maxMemoryCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _catalog[chart.trackId] = _summaryOf(chart);
  }

  /// Check if a chart exists for a track
  bool hasChart(String trackId) => _catalog.containsKey(trackId) || _cache.containsKey(trackId);

  /// Get a full cached chart from memory (null if not loaded; see [loadChart])
  ChartData? getChart(String trackId) => _cache[trackId];

  File? _chartFile(String trackId) =>
      _cacheDir == null ? null : File('${_cacheDir!.path}/$trackId.json');

  /// Read a chart from disk regardless of its generator version.
  Future<ChartData?> _readChartFile(String trackId) async {
    final file = _chartFile(trackId);
    if (file == null || !await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ChartData.fromJson(json);
    } catch (e) {
      debugPrint('🎮 ChartCache: Error reading ${file.path}: $e');
      return null;
    }
  }

  /// Any stored chart for [trackId] (memory first, then disk), even one from
  /// an older generator version.
  Future<ChartData?> _findAnyChart(String trackId) async =>
      _cache[trackId] ?? await _readChartFile(trackId);

  /// A playable chart for [trackId]: checks memory, then disk (charts trimmed
  /// from memory are still on disk). Returns null when there is none or it
  /// was built by an older generator and should be regenerated.
  Future<ChartData?> loadChart(String trackId) async {
    if (_cacheDir == null) await initialize();
    final chart = await _findAnyChart(trackId);
    if (chart == null || !chart.isCurrentVersion) return null;
    _remember(chart);
    return chart;
  }

  /// Write [contents] to [file] atomically (temp file + rename), so a crash
  /// mid-write never leaves a truncated file behind.
  static Future<void> _writeAtomic(File file, List<int> contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(contents, flush: true);
    await tmp.rename(file.path);
  }

  /// Every cached chart, as catalog entries: scores and metadata, and
  /// `notes.length` only (their notes can't be read; use [loadChart]).
  List<ChartData> getAllCharts() {
    final charts = _catalog.values.toList();
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
      await _writeAtomic(file, utf8.encode(json));
      _remember(chart);
      notifyListeners();
      debugPrint('🎮 ChartCache: Saved chart for ${chart.trackName}');
    } catch (e) {
      debugPrint('🎮 ChartCache: Error saving chart: $e');
    }
  }

  /// Save a freshly generated chart, carrying over the scores of any chart
  /// it replaces (e.g. one from an older generator version).
  Future<void> saveGeneratedChart(ChartData chart) async {
    if (_cacheDir == null) await initialize();
    final previous = await _findAnyChart(chart.trackId);
    await saveChart(previous == null
        ? chart
        : chart.copyWithScore(
            highScore: previous.highScore,
            maxMultiplier: previous.maxMultiplier,
            playCount: previous.playCount,
            totalNotesHit: previous.totalNotesHit,
          ));
  }

  /// Record a finished play: counts the play and keeps the best score and
  /// multiplier. With [recordBest] false (e.g. a run that used the cheat)
  /// the best score and multiplier are left alone. Returns the updated chart
  /// (null if the chart is unknown).
  Future<ChartData?> updateScore(
    String trackId,
    int score,
    int maxMultiplier, {
    int notesHit = 0,
    bool recordBest = true,
  }) async {
    if (_cacheDir == null) await initialize();
    final existing = await _findAnyChart(trackId);
    if (existing == null) return null;

    final updated = existing.copyWithScore(
      highScore: recordBest && score > existing.highScore ? score : existing.highScore,
      maxMultiplier: recordBest && maxMultiplier > existing.maxMultiplier
          ? maxMultiplier
          : existing.maxMultiplier,
      playCount: existing.playCount + 1,
      totalNotesHit: existing.totalNotesHit + notesHit,
    );

    await saveChart(updated);
    return updated;
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
      _catalog.remove(trackId);
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
      _catalog.clear();
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
  int get chartCount => _catalog.length;

  /// Get aggregate stats across all charts for profile display
  FretsOnFireStats getAggregateStats() {
    if (_catalog.isEmpty) {
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

    for (final chart in _catalog.values) {
      totalPlays += chart.playCount;
      totalNotes += chart.totalNotesHit;

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
      totalSongsPlayed: _catalog.values.where((c) => c.playCount > 0).length,
      totalPlayCount: totalPlays,
      totalNotesHit: totalNotes,
      bestHighScore: bestScore,
      bestHighScoreTrack: bestScoreTrack,
      bestHighScoreArtist: bestScoreArtist,
      bestMaxMultiplier: bestMultiplier,
    );
  }

  /// Check if any games have been played
  bool get hasPlayedAnyGames => _catalog.values.any((c) => c.playCount > 0);

  // ============================================================
  // LEGENDARY TRACK: Through the Fire and Flames
  // Unlocked by getting a PERFECT score (100% accuracy) on any song
  // ============================================================

  /// Whether the legendary track is unlocked
  bool get isLegendaryUnlocked => _legendaryUnlocked;

  /// Whether the legendary track is currently being copied from assets
  bool get isLegendaryCopying => _legendaryCopy != null;

  /// Whether the legendary track is ready to play (fully copied from assets)
  bool get isLegendaryReady {
    final file = _legendaryTrackFile;
    if (file == null || !file.existsSync()) return false;
    final expected = _legendaryTrackBytes;
    return expected == null || file.lengthSync() == expected;
  }

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

  /// Check if a score qualifies as perfect (100% accuracy, no misses).
  /// [scorableNotes] excludes golden bonus notes, which are optional.
  bool isPerfectScore(int perfectHits, int goodHits, int missedNotes, int scorableNotes) {
    if (scorableNotes == 0) return false;
    // Perfect = hit every note (perfect or good counts), no misses
    return missedNotes == 0 && (perfectHits + goodHits) == scorableNotes;
  }

  /// Copy the legendary track from bundled assets to documents directory
  /// Can be called regardless of unlock state (for demo/offline mode).
  /// A call while a copy is running waits for that copy.
  Future<bool> prepareLegendaryTrack() {
    if (isLegendaryReady) return Future<bool>.value(true);
    final running = _legendaryCopy;
    if (running != null) return running;
    final copy = _legendaryCopy = _copyLegendaryTrack().whenComplete(() {
      _legendaryCopy = null;
      notifyListeners();
    });
    notifyListeners();
    return copy;
  }

  Future<bool> _copyLegendaryTrack() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();

      final legendaryDir = Directory('${appDir.path}/legendary');

      if (!await legendaryDir.exists()) {
        await legendaryDir.create(recursive: true);
      }
      await excludeFromBackup(legendaryDir.path);

      final filePath = '${legendaryDir.path}/through_the_fire_and_flames.mp3';
      final file = File(filePath);

      debugPrint('🔥 Copying Through the Fire and Flames from assets...');

      // Copy from bundled assets to documents directory
      final byteData = await rootBundle.load(_legendaryAssetPath);
      final bytes = byteData.buffer.asUint8List();
      await _writeAtomic(file, bytes);

      _legendaryTrackFile = file;
      _legendaryTrackBytes = bytes.length;
      await _saveLegendaryUnlockState();

      debugPrint('🔥🎸 Ready: Through the Fire and Flames (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
      return true;
    } catch (e) {
      debugPrint('🔥 Copy error: $e');
      return false;
    }
  }

  /// Load legendary unlock state from disk
  Future<void> _loadLegendaryUnlockState() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();

      final legendaryPath = '${appDir.path}/legendary';

      final stateFile = File('$legendaryPath/unlock_state.json');
      if (await stateFile.exists()) {
        final json = jsonDecode(await stateFile.readAsString());
        _legendaryUnlocked = json['unlocked'] == true;
        _legendaryTrackBytes = json['trackBytes'] as int?;
      }

      // Check if track file exists and is complete (a partial copy from an
      // interrupted write is discarded and re-copied on demand)
      final trackFile = File('$legendaryPath/through_the_fire_and_flames.mp3');
      if (await trackFile.exists()) {
        final expected = _legendaryTrackBytes;
        if (expected != null && await trackFile.length() != expected) {
          await trackFile.delete();
        } else {
          _legendaryTrackFile = trackFile;
        }
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
      await _writeAtomic(
        stateFile,
        utf8.encode(jsonEncode({
          'unlocked': _legendaryUnlocked,
          if (_legendaryTrackBytes != null) 'trackBytes': _legendaryTrackBytes,
        })),
      );
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

/// Catalog entry for [chart]: everything but the notes, whose count is kept.
ChartData _summaryOf(ChartData chart) => ChartData(
      version: chart.version,
      id: chart.id,
      trackId: chart.trackId,
      trackName: chart.trackName,
      artistName: chart.artistName,
      notes: _NoteCountOnly(chart.notes.length),
      bpm: chart.bpm,
      durationMs: chart.durationMs,
      generatedAt: chart.generatedAt,
      highScore: chart.highScore,
      maxMultiplier: chart.maxMultiplier,
      playCount: chart.playCount,
      totalNotesHit: chart.totalNotesHit,
    );

/// Isolate entry point: catalog entries for every chart file in [dirPath].
List<ChartData> _readCatalog(String dirPath) {
  final summaries = <ChartData>[];
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return summaries;
  for (final entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.json')) {
      try {
        final json = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
        summaries.add(_summaryOf(ChartData.fromJson(json)));
      } catch (e) {
        debugPrint('🎮 ChartCache: Error loading ${entity.path}: $e');
      }
    }
  }
  return summaries;
}

/// The notes of a catalog entry: only their number is known. Reading a note
/// is a bug (load the full chart instead), so it throws.
class _NoteCountOnly extends ListBase<ChartNote> {
  _NoteCountOnly(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Catalog chart entries are read-only');

  @override
  ChartNote operator [](int index) =>
      throw UnsupportedError('Catalog chart entries hold no notes; use loadChart');

  @override
  void operator []=(int index, ChartNote value) =>
      throw UnsupportedError('Catalog chart entries are read-only');
}
