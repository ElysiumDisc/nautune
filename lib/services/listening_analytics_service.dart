import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_track.dart';

/// Represents a single play event recorded locally
class PlayEvent {
  final String trackId;
  final String trackName;
  final String? albumId;
  final String? albumName;
  final List<String> artists;
  final List<String> genres;
  final DateTime timestamp;
  final int durationMs;
  final bool synced; // Whether this play has been synced to server
  final String? eventId; // Unique ID for deduplication

  PlayEvent({
    required this.trackId,
    required this.trackName,
    this.albumId,
    this.albumName,
    required this.artists,
    required this.genres,
    required this.timestamp,
    required this.durationMs,
    this.synced = false,
    String? eventId,
  }) : eventId = eventId ?? '${trackId}_${timestamp.millisecondsSinceEpoch}';

  /// Create a copy with updated sync status
  PlayEvent copyWith({bool? synced}) => PlayEvent(
    trackId: trackId,
    trackName: trackName,
    albumId: albumId,
    albumName: albumName,
    artists: artists,
    genres: genres,
    timestamp: timestamp,
    durationMs: durationMs,
    synced: synced ?? this.synced,
    eventId: eventId,
  );

  Map<String, dynamic> toJson() => {
    'trackId': trackId,
    'trackName': trackName,
    'albumId': albumId,
    'albumName': albumName,
    'artists': artists,
    'genres': genres,
    'timestamp': timestamp.toIso8601String(),
    'durationMs': durationMs,
    'synced': synced,
    'eventId': eventId,
  };

  factory PlayEvent.fromJson(Map<String, dynamic> json) => PlayEvent(
    trackId: json['trackId'] as String,
    trackName: json['trackName'] as String,
    albumId: json['albumId'] as String?,
    albumName: json['albumName'] as String?,
    artists: (json['artists'] as List<dynamic>?)?.cast<String>() ?? [],
    genres: (json['genres'] as List<dynamic>?)?.cast<String>() ?? [],
    timestamp: DateTime.parse(json['timestamp'] as String),
    durationMs: json['durationMs'] as int? ?? 0,
    synced: json['synced'] as bool? ?? false,
    eventId: json['eventId'] as String?,
  );
}

/// Listening streak information
class ListeningStreak {
  final int currentStreak;
  final int longestStreak;
  final DateTime? lastListeningDate;
  final bool listenedToday;

  ListeningStreak({
    required this.currentStreak,
    required this.longestStreak,
    this.lastListeningDate,
    required this.listenedToday,
  });
}

/// Comparison between two time periods
class PeriodComparison {
  final int currentPeriodPlays;
  final int previousPeriodPlays;
  final Duration currentPeriodTime;
  final Duration previousPeriodTime;
  final int currentPeriodUniqueTracks;
  final int previousPeriodUniqueTracks;

  PeriodComparison({
    required this.currentPeriodPlays,
    required this.previousPeriodPlays,
    required this.currentPeriodTime,
    required this.previousPeriodTime,
    required this.currentPeriodUniqueTracks,
    required this.previousPeriodUniqueTracks,
  });

  /// Percentage change in plays (-100 to +infinity)
  double get playsChangePercent {
    if (previousPeriodPlays == 0) return currentPeriodPlays > 0 ? 100 : 0;
    return ((currentPeriodPlays - previousPeriodPlays) / previousPeriodPlays) * 100;
  }

  /// Percentage change in listening time
  double get timeChangePercent {
    if (previousPeriodTime.inSeconds == 0) {
      return currentPeriodTime.inSeconds > 0 ? 100 : 0;
    }
    return ((currentPeriodTime.inSeconds - previousPeriodTime.inSeconds) /
            previousPeriodTime.inSeconds) * 100;
  }
}

/// Heatmap data for listening activity
class ListeningHeatmap {
  /// Map of (dayOfWeek 0-6, hourOfDay 0-23) -> play count
  final Map<int, Map<int, int>> data;
  final int maxCount;

  ListeningHeatmap({required this.data, required this.maxCount});

  /// Get intensity (0.0-1.0) for a specific day/hour cell
  double getIntensity(int dayOfWeek, int hourOfDay) {
    if (maxCount == 0) return 0;
    final count = data[dayOfWeek]?[hourOfDay] ?? 0;
    return count / maxCount;
  }

  /// Get the raw count for a specific day/hour cell
  int getCount(int dayOfWeek, int hourOfDay) {
    return data[dayOfWeek]?[hourOfDay] ?? 0;
  }
}

/// Relax Mode usage statistics
class RelaxModeStats {
  final int totalSessionsMs;
  final int rainUsageMs;
  final int thunderUsageMs;
  final int campfireUsageMs;
  final int waveUsageMs;
  final int loonUsageMs;

  RelaxModeStats({
    this.totalSessionsMs = 0,
    this.rainUsageMs = 0,
    this.thunderUsageMs = 0,
    this.campfireUsageMs = 0,
    this.waveUsageMs = 0,
    this.loonUsageMs = 0,
  });

  Duration get totalTime => Duration(milliseconds: totalSessionsMs);

  /// Get total sound usage for percentage calculations
  int get _totalSoundUsage => rainUsageMs + thunderUsageMs + campfireUsageMs + waveUsageMs + loonUsageMs;

  /// Get percentage of usage for each sound (0-100)
  double get rainPercent {
    if (_totalSoundUsage == 0) return 0;
    return (rainUsageMs / _totalSoundUsage) * 100;
  }

  double get thunderPercent {
    if (_totalSoundUsage == 0) return 0;
    return (thunderUsageMs / _totalSoundUsage) * 100;
  }

  double get campfirePercent {
    if (_totalSoundUsage == 0) return 0;
    return (campfireUsageMs / _totalSoundUsage) * 100;
  }

  double get wavePercent {
    if (_totalSoundUsage == 0) return 0;
    return (waveUsageMs / _totalSoundUsage) * 100;
  }

  double get loonPercent {
    if (_totalSoundUsage == 0) return 0;
    return (loonUsageMs / _totalSoundUsage) * 100;
  }

  /// Get the favorite sound name
  String? get favoriteSoundName {
    if (_totalSoundUsage == 0) return null;
    final usages = {
      'Rain': rainUsageMs,
      'Thunder': thunderUsageMs,
      'Campfire': campfireUsageMs,
      'Waves': waveUsageMs,
      'Loon': loonUsageMs,
    };
    return usages.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  Map<String, dynamic> toJson() => {
    'totalSessionsMs': totalSessionsMs,
    'rainUsageMs': rainUsageMs,
    'thunderUsageMs': thunderUsageMs,
    'campfireUsageMs': campfireUsageMs,
    'waveUsageMs': waveUsageMs,
    'loonUsageMs': loonUsageMs,
  };

  factory RelaxModeStats.fromJson(Map<String, dynamic> json) => RelaxModeStats(
    totalSessionsMs: json['totalSessionsMs'] as int? ?? 0,
    rainUsageMs: json['rainUsageMs'] as int? ?? 0,
    thunderUsageMs: json['thunderUsageMs'] as int? ?? 0,
    campfireUsageMs: json['campfireUsageMs'] as int? ?? 0,
    waveUsageMs: json['waveUsageMs'] as int? ?? 0,
    loonUsageMs: json['loonUsageMs'] as int? ?? 0,
  );

  RelaxModeStats copyWith({
    int? totalSessionsMs,
    int? rainUsageMs,
    int? thunderUsageMs,
    int? campfireUsageMs,
    int? waveUsageMs,
    int? loonUsageMs,
  }) => RelaxModeStats(
    totalSessionsMs: totalSessionsMs ?? this.totalSessionsMs,
    rainUsageMs: rainUsageMs ?? this.rainUsageMs,
    thunderUsageMs: thunderUsageMs ?? this.thunderUsageMs,
    campfireUsageMs: campfireUsageMs ?? this.campfireUsageMs,
    waveUsageMs: waveUsageMs ?? this.waveUsageMs,
    loonUsageMs: loonUsageMs ?? this.loonUsageMs,
  );
}

/// Service for recording and querying local listening analytics
class ListeningAnalyticsService extends ChangeNotifier {
  static const _boxName = 'nautune_analytics';
  static const _eventsKey = 'play_events';
  static const _streakKey = 'streak_data';
  static const _relaxModeKey = 'relax_mode_stats';
  static const _pianoStatsKey = 'piano_stats';

  // Legacy Hive keys from the retired milestone/badge system. Kept here only
  // so initialize() can best-effort delete them from existing installs.
  static const _legacyDiscoveryKeys = <String>[
    'network_discovered',
    'essential_mix_discovered',
    'frets_on_fire_discovered',
    'piano_discovered',
    'healing_frequencies_discovered',
  ];

  Box? _box;
  List<PlayEvent> _events = [];
  RelaxModeStats _relaxModeStats = RelaxModeStats();
  int _pianoTotalNotes = 0;
  int _pianoTotalSessionMs = 0;
  bool _initialized = false;

  /// Singleton instance
  static final ListeningAnalyticsService _instance = ListeningAnalyticsService._internal();
  factory ListeningAnalyticsService() => _instance;
  ListeningAnalyticsService._internal();

  bool get isInitialized => _initialized;

  /// Check if a track ID belongs to an easter egg (not a real Jellyfin track)
  bool _isEasterEggTrack(String trackId) {
    return trackId.startsWith('essential-mix') ||
        trackId.startsWith('network-') ||
        trackId.startsWith('relax-');
  }

  /// Initialize the service and load existing data
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _box = await Hive.openBox(_boxName);
      await _loadEvents();
      await _loadRelaxModeStats();
      await _loadPianoStats();
      await _cleanupLegacyDiscoveryKeys();
      _initialized = true;
      debugPrint('ListeningAnalyticsService: Initialized with ${_events.length} events');
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Failed to initialize: $e');
    }
  }

  /// Save all analytics data to persistent storage
  /// Call this when the app is pausing to ensure data isn't lost
  Future<void> saveAnalytics() async {
    if (!_initialized) return;
    try {
      await Future.wait([
        _saveEvents(),
        _saveRelaxModeStats(),
        _savePianoStats(),
      ]);
      debugPrint('ListeningAnalyticsService: Analytics saved');
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Error saving analytics: $e');
    }
  }

  Future<void> _loadRelaxModeStats() async {
    final raw = _box?.get(_relaxModeKey);
    if (raw == null) {
      _relaxModeStats = RelaxModeStats();
      return;
    }
    try {
      if (raw is String) {
        _relaxModeStats = RelaxModeStats.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
      } else if (raw is Map) {
        _relaxModeStats = RelaxModeStats.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Error loading relax mode stats: $e');
      _relaxModeStats = RelaxModeStats();
    }
  }

  Future<void> _saveRelaxModeStats() async {
    if (_box == null) return;
    await _box!.put(_relaxModeKey, jsonEncode(_relaxModeStats.toJson()));
  }

  /// Get Relax Mode statistics
  RelaxModeStats getRelaxModeStats() => _relaxModeStats;

  /// Record Relax Mode session usage
  /// Call this when exiting Relax Mode with the duration and slider usage
  Future<void> recordRelaxModeSession({
    required Duration sessionDuration,
    required Duration rainUsage,
    required Duration thunderUsage,
    required Duration campfireUsage,
    Duration waveUsage = Duration.zero,
    Duration loonUsage = Duration.zero,
  }) async {
    if (!_initialized) return;

    _relaxModeStats = RelaxModeStats(
      totalSessionsMs: _relaxModeStats.totalSessionsMs + sessionDuration.inMilliseconds,
      rainUsageMs: _relaxModeStats.rainUsageMs + rainUsage.inMilliseconds,
      thunderUsageMs: _relaxModeStats.thunderUsageMs + thunderUsage.inMilliseconds,
      campfireUsageMs: _relaxModeStats.campfireUsageMs + campfireUsage.inMilliseconds,
      waveUsageMs: _relaxModeStats.waveUsageMs + waveUsage.inMilliseconds,
      loonUsageMs: _relaxModeStats.loonUsageMs + loonUsage.inMilliseconds,
    );

    await _saveRelaxModeStats();
    notifyListeners();
    debugPrint('ListeningAnalyticsService: Recorded Relax Mode session (${sessionDuration.inMinutes}m)');
  }

  // Best-effort cleanup of Hive keys left over from the retired milestone /
  // discovery system. Runs once per init; no-op on fresh installs.
  Future<void> _cleanupLegacyDiscoveryKeys() async {
    final box = _box;
    if (box == null) return;
    for (final key in _legacyDiscoveryKeys) {
      try {
        if (box.containsKey(key)) {
          await box.delete(key);
        }
      } catch (_) {
        // Ignore — stale key cleanup is non-critical.
      }
    }
  }

  // Piano stats tracking (notes played, session time). The milestone-era
  // `_pianoDiscovered` boolean was retired in v8.9.5.
  Future<void> _loadPianoStats() async {
    final raw = _box?.get(_pianoStatsKey);
    if (raw != null) {
      try {
        final Map<String, dynamic> json;
        if (raw is String) {
          json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } else if (raw is Map) {
          json = Map<String, dynamic>.from(raw);
        } else {
          return;
        }
        _pianoTotalNotes = json['totalNotes'] as int? ?? 0;
        _pianoTotalSessionMs = json['totalSessionMs'] as int? ?? 0;
      } catch (e) {
        debugPrint('ListeningAnalyticsService: Error loading piano stats: $e');
      }
    }
  }

  Future<void> _savePianoStats() async {
    if (_box == null) return;
    await _box!.put(_pianoStatsKey, jsonEncode({
      'totalNotes': _pianoTotalNotes,
      'totalSessionMs': _pianoTotalSessionMs,
    }));
  }

  /// Get piano total notes played
  int get pianoTotalNotes => _pianoTotalNotes;

  /// Get piano total session time
  Duration get pianoTotalSessionTime => Duration(milliseconds: _pianoTotalSessionMs);

  /// Record a piano session
  Future<void> recordPianoSession({
    required int notesPlayed,
    required Duration sessionDuration,
  }) async {
    if (!_initialized) return;
    _pianoTotalNotes += notesPlayed;
    _pianoTotalSessionMs += sessionDuration.inMilliseconds;
    await _savePianoStats();
    notifyListeners();
    debugPrint('ListeningAnalyticsService: Recorded piano session ($notesPlayed notes, ${sessionDuration.inSeconds}s)');
  }

  Future<void> _loadEvents() async {
    final raw = _box?.get(_eventsKey);
    if (raw == null) {
      _events = [];
      return;
    }

    try {
      final List<dynamic> jsonList;
      if (raw is String) {
        jsonList = jsonDecode(raw) as List<dynamic>;
      } else if (raw is List) {
        jsonList = raw;
      } else {
        _events = [];
        return;
      }

      // Decode per-event so one malformed row can't wipe the whole history.
      _events = [];
      for (final raw in jsonList) {
        try {
          _events.add(
            PlayEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
          );
        } catch (e) {
          debugPrint('ListeningAnalyticsService: skipping bad event: $e');
        }
      }

      // Sort by timestamp descending (most recent first)
      _events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Error loading events: $e');
      _events = [];
    }
  }

  Future<void> _saveEvents() async {
    if (_box == null) return;

    // Keep last 365 days of events for streak / period-comparison / top-content
    // stats on the Profile dashboard. Two-year retention was previously kept
    // for the retired "Your Rewind" yearly report; trimmed in v8.9.5.
    final cutoff = DateTime.now().subtract(const Duration(days: 365));
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));

    final jsonList = _events.map((e) => e.toJson()).toList();
    await _box!.put(_eventsKey, jsonEncode(jsonList));
  }

  /// Record a play event for a track with actual listening duration
  /// [actualDurationMs] - The actual time listened in milliseconds (not full track length)
  /// [playStartTime] - When the track started playing (for accurate timestamp)
  Future<void> recordPlay(
    JellyfinTrack track, {
    int? actualDurationMs,
    DateTime? playStartTime,
  }) async {
    if (!_initialized) {
      debugPrint('ListeningAnalyticsService: Not initialized, skipping record');
      return;
    }

    // Use actual duration if provided, otherwise fall back to track duration
    final durationMs = actualDurationMs ??
        (track.runTimeTicks != null ? track.runTimeTicks! ~/ 10000 : 0);

    // Don't record plays shorter than 10 seconds (likely accidental skips)
    if (durationMs < 10000) {
      debugPrint('ListeningAnalyticsService: Skipping short play (<10s) for "${track.name}"');
      return;
    }

    final event = PlayEvent(
      trackId: track.id,
      trackName: track.name,
      albumId: track.albumId,
      albumName: track.album,
      artists: track.artists,
      genres: track.genres ?? [],
      timestamp: playStartTime ?? DateTime.now(),
      durationMs: durationMs,
    );

    _events.insert(0, event); // Add to front (most recent)

    // Save asynchronously
    unawaited(_saveEvents());

    final minutes = durationMs ~/ 60000;
    final seconds = (durationMs % 60000) ~/ 1000;
    debugPrint('ListeningAnalyticsService: Recorded ${minutes}m ${seconds}s for "${track.name}"');
  }

  /// Get play counts by hour of day (0-23) for the given date range
  Map<int, int> getPlaysByHourOfDay({DateTime? since}) {
    final cutoff = since ?? DateTime.now().subtract(const Duration(days: 30));
    final counts = <int, int>{};

    for (int i = 0; i < 24; i++) {
      counts[i] = 0;
    }

    for (final event in _events) {
      if (event.timestamp.isAfter(cutoff)) {
        final hour = event.timestamp.hour;
        counts[hour] = (counts[hour] ?? 0) + 1;
      }
    }

    return counts;
  }

  /// Get play counts by day of week (0=Monday, 6=Sunday) for the given date range
  Map<int, int> getPlaysByDayOfWeek({DateTime? since}) {
    final cutoff = since ?? DateTime.now().subtract(const Duration(days: 30));
    final counts = <int, int>{};

    for (int i = 0; i < 7; i++) {
      counts[i] = 0;
    }

    for (final event in _events) {
      if (event.timestamp.isAfter(cutoff)) {
        // DateTime.weekday is 1-7 (Monday-Sunday), convert to 0-6
        final day = event.timestamp.weekday - 1;
        counts[day] = (counts[day] ?? 0) + 1;
      }
    }

    return counts;
  }

  /// Get a heatmap of listening activity (day of week x hour of day)
  ListeningHeatmap getListeningHeatmap({DateTime? since}) {
    final cutoff = since ?? DateTime.now().subtract(const Duration(days: 30));
    final data = <int, Map<int, int>>{};
    int maxCount = 0;

    // Initialize all cells to 0
    for (int day = 0; day < 7; day++) {
      data[day] = {};
      for (int hour = 0; hour < 24; hour++) {
        data[day]![hour] = 0;
      }
    }

    // Count events
    for (final event in _events) {
      if (event.timestamp.isAfter(cutoff)) {
        final day = event.timestamp.weekday - 1; // 0-6
        final hour = event.timestamp.hour; // 0-23
        data[day]![hour] = (data[day]![hour] ?? 0) + 1;
        if (data[day]![hour]! > maxCount) {
          maxCount = data[day]![hour]!;
        }
      }
    }

    return ListeningHeatmap(data: data, maxCount: maxCount);
  }

  /// Get listening streak information
  ListeningStreak getStreakInfo() {
    if (_events.isEmpty) {
      return ListeningStreak(
        currentStreak: 0,
        longestStreak: 0,
        listenedToday: false,
      );
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    // Get unique days with listening activity
    final listeningDays = <DateTime>{};
    for (final event in _events) {
      final day = DateTime(event.timestamp.year, event.timestamp.month, event.timestamp.day);
      listeningDays.add(day);
    }

    final sortedDays = listeningDays.toList()..sort((a, b) => b.compareTo(a));

    final listenedToday = sortedDays.isNotEmpty && sortedDays.first == today;

    // Calculate current streak
    int currentStreak = 0;
    DateTime checkDate = listenedToday ? today : yesterday;

    for (final day in sortedDays) {
      if (day == checkDate) {
        currentStreak++;
        checkDate = checkDate.subtract(const Duration(days: 1));
      } else if (day.isBefore(checkDate)) {
        break;
      }
    }

    // If we didn't listen today or yesterday, streak is broken
    if (!listenedToday && (sortedDays.isEmpty || sortedDays.first != yesterday)) {
      currentStreak = 0;
    }

    // Calculate longest streak
    int longestStreak = 0;
    int tempStreak = 0;
    DateTime? prevDay;

    for (final day in sortedDays.reversed) {
      if (prevDay == null) {
        tempStreak = 1;
      } else {
        final diff = day.difference(prevDay).inDays;
        if (diff == 1) {
          tempStreak++;
        } else {
          if (tempStreak > longestStreak) {
            longestStreak = tempStreak;
          }
          tempStreak = 1;
        }
      }
      prevDay = day;
    }
    if (tempStreak > longestStreak) {
      longestStreak = tempStreak;
    }

    return ListeningStreak(
      currentStreak: currentStreak,
      longestStreak: longestStreak,
      lastListeningDate: sortedDays.isNotEmpty ? sortedDays.first : null,
      listenedToday: listenedToday,
    );
  }

  /// Compare this week vs last week
  PeriodComparison getWeekOverWeekComparison() {
    final now = DateTime.now();
    final startOfThisWeek = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final startOfLastWeek = startOfThisWeek.subtract(const Duration(days: 7));

    return _comparePeriods(
      currentStart: startOfThisWeek,
      currentEnd: now,
      previousStart: startOfLastWeek,
      previousEnd: startOfThisWeek,
    );
  }

  /// Compare this month vs last month
  PeriodComparison getMonthOverMonthComparison() {
    final now = DateTime.now();
    final startOfThisMonth = DateTime(now.year, now.month, 1);
    final startOfLastMonth = DateTime(now.year, now.month - 1, 1);

    return _comparePeriods(
      currentStart: startOfThisMonth,
      currentEnd: now,
      previousStart: startOfLastMonth,
      previousEnd: startOfThisMonth,
    );
  }

  /// Compare this year vs last year
  PeriodComparison getYearOverYearComparison() {
    final now = DateTime.now();
    final startOfThisYear = DateTime(now.year, 1, 1);
    final startOfLastYear = DateTime(now.year - 1, 1, 1);
    final endOfLastYear = DateTime(now.year, 1, 1);

    return _comparePeriods(
      currentStart: startOfThisYear,
      currentEnd: now,
      previousStart: startOfLastYear,
      previousEnd: endOfLastYear,
    );
  }

  PeriodComparison _comparePeriods({
    required DateTime currentStart,
    required DateTime currentEnd,
    required DateTime previousStart,
    required DateTime previousEnd,
  }) {
    int currentPlays = 0;
    int previousPlays = 0;
    int currentTimeMs = 0;
    int previousTimeMs = 0;
    final currentTracks = <String>{};
    final previousTracks = <String>{};

    for (final event in _events) {
      final ts = event.timestamp;
      // Use inclusive comparison: start <= timestamp <= end
      // This ensures events at exactly midnight or exactly now are counted
      if (!ts.isBefore(currentStart) && !ts.isAfter(currentEnd)) {
        currentPlays++;
        currentTimeMs += event.durationMs;
        currentTracks.add(event.trackId);
      } else if (!ts.isBefore(previousStart) && ts.isBefore(previousEnd)) {
        // Previous period: start <= timestamp < end (exclusive end to avoid overlap)
        previousPlays++;
        previousTimeMs += event.durationMs;
        previousTracks.add(event.trackId);
      }
    }

    return PeriodComparison(
      currentPeriodPlays: currentPlays,
      previousPeriodPlays: previousPlays,
      currentPeriodTime: Duration(milliseconds: currentTimeMs),
      previousPeriodTime: Duration(milliseconds: previousTimeMs),
      currentPeriodUniqueTracks: currentTracks.length,
      previousPeriodUniqueTracks: previousTracks.length,
    );
  }

  /// Get total plays in the given date range
  int getTotalPlays({DateTime? since}) {
    final cutoff = since ?? DateTime(2000);
    return _events.where((e) => e.timestamp.isAfter(cutoff)).length;
  }

  /// Get total listening time in the given date range
  Duration getTotalListeningTime({DateTime? since}) {
    final cutoff = since ?? DateTime(2000);
    int totalMs = 0;
    for (final event in _events) {
      if (event.timestamp.isAfter(cutoff)) {
        totalMs += event.durationMs;
      }
    }
    return Duration(milliseconds: totalMs);
  }

  /// Get the most active listening hour (0-23)
  int? getPeakListeningHour({DateTime? since}) {
    final hourCounts = getPlaysByHourOfDay(since: since);
    if (hourCounts.isEmpty) return null;

    int maxHour = 0;
    int maxCount = 0;
    hourCounts.forEach((hour, count) {
      if (count > maxCount) {
        maxCount = count;
        maxHour = hour;
      }
    });

    return maxCount > 0 ? maxHour : null;
  }

  /// Get the most active day of the week (0=Monday, 6=Sunday)
  int? getPeakDayOfWeek({DateTime? since}) {
    final dayCounts = getPlaysByDayOfWeek(since: since);
    if (dayCounts.isEmpty) return null;

    int maxDay = 0;
    int maxCount = 0;
    dayCounts.forEach((day, count) {
      if (count > maxCount) {
        maxCount = count;
        maxDay = day;
      }
    });

    return maxCount > 0 ? maxDay : null;
  }

  /// Get play counts for each of the last [days] days, ordered chronologically.
  /// Index 0 = oldest day, last index = today.
  List<int> getDailyPlayCounts({int days = 28}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final counts = List<int>.filled(days, 0);

    for (final event in _events) {
      final eventDay = DateTime(
          event.timestamp.year, event.timestamp.month, event.timestamp.day);
      final daysAgo = today.difference(eventDay).inDays;
      if (daysAgo >= 0 && daysAgo < days) {
        counts[days - 1 - daysAgo]++;
      }
    }
    return counts;
  }

  /// Get the day name for a day index (0=Monday, 6=Sunday)
  static String getDayName(int dayIndex) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[dayIndex.clamp(0, 6)];
  }

  /// Get the short day name for a day index (0=Monday, 6=Sunday)
  static String getShortDayName(int dayIndex) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[dayIndex.clamp(0, 6)];
  }

  /// Get count of marathon sessions (2+ hour listening sessions)
  int getMarathonSessionCount({DateTime? since}) {
    final cutoff = since ?? DateTime(2000);
    final relevantEvents = _events
        .where((e) => e.timestamp.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (relevantEvents.isEmpty) return 0;

    int marathonSessions = 0;
    DateTime? lastEventTime;
    int sessionDurationMs = 0;

    for (final event in relevantEvents) {
      if (lastEventTime == null) {
        sessionDurationMs = event.durationMs;
      } else {
        final gap = event.timestamp.difference(lastEventTime);
        if (gap.inMinutes > 30) {
          // Session ended, check if it was a marathon (> 2 hours)
          if (sessionDurationMs >= 2 * 60 * 60 * 1000) {
            marathonSessions++;
          }
          sessionDurationMs = event.durationMs;
        } else {
          sessionDurationMs += event.durationMs;
        }
      }
      lastEventTime = event.timestamp;
    }
    // Check the last session
    if (sessionDurationMs >= 2 * 60 * 60 * 1000) {
      marathonSessions++;
    }

    return marathonSessions;
  }

  /// Get recent play events
  List<PlayEvent> getRecentEvents({int limit = 50}) {
    return _events.take(limit).toList();
  }

  /// Get play events from the same day in previous months/years (On This Day)
  /// Returns events from:
  /// - Same day of the month in any previous month (e.g., Jan 15th shows Dec 15th, Nov 15th, etc.)
  /// - Prioritizes more recent events
  List<PlayEvent> getOnThisDayEvents() {
    final now = DateTime.now();
    final today = now.day;

    // Find events from the same day of the month in any previous month
    final matchingEvents = _events.where((event) {
      // Must be from a previous date (not today)
      final eventDate = DateTime(event.timestamp.year, event.timestamp.month, event.timestamp.day);
      final todayDate = DateTime(now.year, now.month, now.day);
      if (!eventDate.isBefore(todayDate)) return false;

      // Match the same day of month
      return event.timestamp.day == today;
    }).toList();

    // Sort by date descending (most recent first) and return unique tracks
    matchingEvents.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    // Deduplicate by trackId, keeping the most recent occurrence
    final seenTracks = <String>{};
    return matchingEvents.where((event) {
      if (seenTracks.contains(event.trackId)) return false;
      seenTracks.add(event.trackId);
      return true;
    }).toList();
  }


  /// Calculate average session length
  /// Groups plays into sessions (gap > 30 min = new session)
  Duration? getAverageSessionLength({DateTime? since}) {
    final cutoff = since ?? DateTime.now().subtract(const Duration(days: 30));
    final relevantEvents = _events
        .where((e) => e.timestamp.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp)); // Sort chronologically

    if (relevantEvents.isEmpty) return null;

    final sessions = <Duration>[];
    DateTime? lastEventTime;
    int sessionDurationMs = 0;

    for (final event in relevantEvents) {
      if (lastEventTime == null) {
        // First event starts a new session
        sessionDurationMs = event.durationMs;
      } else {
        final gap = event.timestamp.difference(lastEventTime);
        if (gap.inMinutes > 30) {
          // Gap > 30 minutes, end previous session and start new one
          if (sessionDurationMs > 0) {
            sessions.add(Duration(milliseconds: sessionDurationMs));
          }
          sessionDurationMs = event.durationMs;
        } else {
          // Continue current session
          sessionDurationMs += event.durationMs;
        }
      }
      lastEventTime = event.timestamp;
    }

    // Don't forget the last session
    if (sessionDurationMs > 0) {
      sessions.add(Duration(milliseconds: sessionDurationMs));
    }

    if (sessions.isEmpty) return null;

    final totalMs = sessions.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return Duration(milliseconds: totalMs ~/ sessions.length);
  }

  /// Calculate discovery rate (unique tracks / total plays as percentage)
  /// Higher percentage = more exploration, lower = more replay
  double getDiscoveryRate({DateTime? since}) {
    final cutoff = since ?? DateTime.now().subtract(const Duration(days: 30));
    final relevantEvents = _events.where((e) => e.timestamp.isAfter(cutoff)).toList();

    if (relevantEvents.isEmpty) return 0.0;

    final uniqueTracks = <String>{};
    for (final event in relevantEvents) {
      uniqueTracks.add(event.trackId);
    }

    // Discovery rate = unique tracks / total plays * 100
    return (uniqueTracks.length / relevantEvents.length) * 100;
  }

  /// Get discovery rate label based on percentage
  String getDiscoveryLabel(double rate) {
    if (rate >= 80) return 'Pioneer';
    if (rate >= 60) return 'Explorer';
    if (rate >= 40) return 'Adventurer';
    if (rate >= 20) return 'Curator';
    return 'Loyalist';
  }

  /// Clear all analytics data
  Future<void> clearAll() async {
    _events.clear();
    await _box?.delete(_eventsKey);
    await _box?.delete(_streakKey);
    debugPrint('ListeningAnalyticsService: Cleared all data');
  }

  /// Export ALL analytics data as JSON string for backup.
  /// Includes: play events, relax mode stats, piano stats.
  /// Network channel stats should be exported separately via NetworkDownloadService.
  String exportAllStatsAsJson() {
    return jsonEncode({
      'nautune_stats_backup': true,
      'version': 2,
      'exported_at': DateTime.now().toIso8601String(),
      'play_events': _events.map((e) => e.toJson()).toList(),
      'relax_mode_stats': _relaxModeStats.toJson(),
      'piano_total_notes': _pianoTotalNotes,
      'piano_total_session_ms': _pianoTotalSessionMs,
    });
  }

  /// Import ALL analytics data from JSON string.
  /// Merges with existing data (doesn't overwrite unless events are duplicates).
  /// Returns number of events imported.
  Future<int> importAllStatsFromJson(String jsonString) async {
    if (!_initialized) {
      debugPrint('ListeningAnalyticsService: Not initialized, cannot import');
      return 0;
    }

    try {
      final decoded = jsonString.trim();
      if (!decoded.startsWith('{')) return 0;

      final jsonData = jsonDecode(decoded) as Map<String, dynamic>;

      // Verify it's a Nautune backup
      if (jsonData['nautune_stats_backup'] != true) {
        debugPrint('ListeningAnalyticsService: Invalid backup format');
        return 0;
      }

      int importedCount = 0;

      // Import play events
      final eventsJson = jsonData['play_events'] as List<dynamic>?;
      if (eventsJson != null) {
        final existingEventIds = _events.map((e) => e.eventId).toSet();

        for (final eventJson in eventsJson) {
          try {
            final event = PlayEvent.fromJson(
              Map<String, dynamic>.from(eventJson as Map),
            );
            // Only add if not a duplicate (by eventId)
            if (!existingEventIds.contains(event.eventId)) {
              _events.add(event);
              existingEventIds.add(event.eventId);
              importedCount++;
            }
          } catch (e) {
            debugPrint('ListeningAnalyticsService: Error importing event: $e');
          }
        }

        // Sort by timestamp descending
        _events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      }

      // Import relax mode stats (merge - keep higher values)
      final relaxJson = jsonData['relax_mode_stats'] as Map<String, dynamic>?;
      if (relaxJson != null) {
        final importedRelax = RelaxModeStats.fromJson(relaxJson);
        _relaxModeStats = RelaxModeStats(
          totalSessionsMs: _relaxModeStats.totalSessionsMs > importedRelax.totalSessionsMs
              ? _relaxModeStats.totalSessionsMs
              : importedRelax.totalSessionsMs,
          rainUsageMs: _relaxModeStats.rainUsageMs > importedRelax.rainUsageMs
              ? _relaxModeStats.rainUsageMs
              : importedRelax.rainUsageMs,
          thunderUsageMs: _relaxModeStats.thunderUsageMs > importedRelax.thunderUsageMs
              ? _relaxModeStats.thunderUsageMs
              : importedRelax.thunderUsageMs,
          campfireUsageMs: _relaxModeStats.campfireUsageMs > importedRelax.campfireUsageMs
              ? _relaxModeStats.campfireUsageMs
              : importedRelax.campfireUsageMs,
        );
      }

      // Import piano stats (keep higher values)
      final importedPianoNotes = jsonData['piano_total_notes'] as int? ?? 0;
      if (importedPianoNotes > _pianoTotalNotes) {
        _pianoTotalNotes = importedPianoNotes;
      }
      final importedPianoMs = jsonData['piano_total_session_ms'] as int? ?? 0;
      if (importedPianoMs > _pianoTotalSessionMs) {
        _pianoTotalSessionMs = importedPianoMs;
      }

      // Save all imported data
      if (importedCount > 0 || relaxJson != null || importedPianoNotes > 0 || importedPianoMs > 0) {
        await Future.wait([
          _saveEvents(),
          _saveRelaxModeStats(),
          _savePianoStats(),
        ]);
        debugPrint('ListeningAnalyticsService: Imported $importedCount events');
        // Single aggregate notification — the `_save*` helpers no longer
        // emit per-call, so listeners refresh once when the import is done.
        notifyListeners();
      }

      return importedCount;
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Import failed: $e');
      return 0;
    }
  }

  /// Get raw event count for stats display
  int get totalEventCount => _events.length;

  // ============ Server Sync Methods ============

  /// Get all unsynced play events
  List<PlayEvent> getUnsyncedEvents() {
    return _events.where((e) => !e.synced).toList();
  }

  /// Get count of unsynced events
  int get unsyncedCount => _events.where((e) => !e.synced).length;

  /// Sync unsynced plays to server
  /// This marks plays on the server with their actual timestamps
  Future<SyncResult> syncToServer({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
  }) async {
    if (!_initialized) {
      return SyncResult(success: false, error: 'Service not initialized');
    }

    final unsynced = getUnsyncedEvents();
    if (unsynced.isEmpty) {
      debugPrint('📊 Sync: No unsynced events to push');
      return SyncResult(success: true, syncedCount: 0);
    }

    // Filter out easter egg tracks (not real Jellyfin items)
    final syncable = unsynced.where((e) => !_isEasterEggTrack(e.trackId)).toList();
    final skipped = unsynced.length - syncable.length;

    if (skipped > 0) {
      // Mark easter egg tracks as "synced" so they don't keep trying
      for (final event in unsynced.where((e) => _isEasterEggTrack(e.trackId))) {
        final index = _events.indexWhere((e) => e.eventId == event.eventId);
        if (index != -1) {
          _events[index] = event.copyWith(synced: true);
        }
      }
      await _saveEvents();
      debugPrint('📊 Sync: Skipped $skipped easter egg plays (not Jellyfin tracks)');
    }

    if (syncable.isEmpty) {
      debugPrint('📊 Sync: No syncable events to push');
      return SyncResult(success: true, syncedCount: 0);
    }

    debugPrint('📊 Sync: Pushing ${syncable.length} unsynced plays to server...');

    int syncedCount = 0;
    int failedCount = 0;
    final errors = <String>[];

    for (final event in syncable) {
      try {
        final result = await client.markPlayed(
          credentials: credentials,
          itemId: event.trackId,
          datePlayed: event.timestamp,
        );

        if (result != null) {
          // Mark as synced locally
          final index = _events.indexWhere((e) => e.eventId == event.eventId);
          if (index != -1) {
            _events[index] = event.copyWith(synced: true);
          }
          syncedCount++;
        } else {
          failedCount++;
          errors.add('Failed to sync ${event.trackName}');
        }
      } catch (e) {
        failedCount++;
        errors.add('Error syncing ${event.trackName}: $e');
      }
    }

    // Save updated sync status
    await _saveEvents();

    debugPrint('📊 Sync complete: $syncedCount synced, $failedCount failed');

    return SyncResult(
      success: failedCount == 0,
      syncedCount: syncedCount,
      failedCount: failedCount,
      errors: errors.isNotEmpty ? errors : null,
    );
  }

  /// Sync play data FROM server to reconcile counts
  /// This fetches PlayCount from server and creates "catch-up" events if needed
  /// Now includes full track metadata (name, artists, genres, duration) for accurate stats
  Future<SyncResult> syncFromServer({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
    required List<String> trackIds,
  }) async {
    if (!_initialized) {
      return SyncResult(success: false, error: 'Service not initialized');
    }

    if (trackIds.isEmpty) {
      return SyncResult(success: true, syncedCount: 0);
    }

    debugPrint('📊 Sync: Fetching play data for ${trackIds.length} tracks from server...');

    try {
      // Get server data with full item metadata (name, artists, genres, duration)
      final serverData = await client.getBatchItemsWithFullData(
        credentials: credentials,
        itemIds: trackIds,
      );

      int addedCount = 0;

      for (final trackId in trackIds) {
        final itemData = serverData[trackId];
        if (itemData == null) continue;

        final userData = itemData['UserData'] as Map<String, dynamic>?;
        if (userData == null) continue;

        final serverPlayCount = userData['PlayCount'] as int? ?? 0;
        final lastPlayedStr = userData['LastPlayedDate'] as String?;

        // Extract track metadata from server response
        final trackName = itemData['Name'] as String? ?? 'Unknown Track';
        final rawArtists = itemData['Artists'] as List<dynamic>?;
        final artists = rawArtists?.whereType<String>().toList() ?? <String>[];
        final rawGenres = itemData['Genres'] as List<dynamic>?;
        final genres = rawGenres?.whereType<String>().toList() ?? <String>[];
        final albumId = itemData['AlbumId'] as String?;
        final albumName = itemData['Album'] as String?;
        final runTimeTicks = itemData['RunTimeTicks'] as int?;
        final durationMs = runTimeTicks != null ? runTimeTicks ~/ 10000 : 0;

        // Count local plays for this track
        final localPlayCount = _events.where((e) => e.trackId == trackId).length;

        // If server has more plays than we have locally, we're missing data
        if (serverPlayCount > localPlayCount) {
          final missingCount = serverPlayCount - localPlayCount;
          debugPrint('📊 Track $trackId ($trackName): server=$serverPlayCount, local=$localPlayCount, missing=$missingCount');

          // Get last played date from server
          final lastPlayed = lastPlayedStr != null
              ? DateTime.tryParse(lastPlayedStr)
              : DateTime.now();
          final baseTime = lastPlayed ?? DateTime.now();

          // Distribute catch-up events across time for more realistic stats
          // Spread plays evenly over the past 30 days leading up to lastPlayed
          for (int i = 0; i < missingCount; i++) {
            // Calculate a spread timestamp - distribute events over 30 days
            final daysAgo = (i * 30) ~/ missingCount;
            final hoursOffset = (i * 24) % 24; // Vary the hour for better distribution
            final spreadTimestamp = baseTime
                .subtract(Duration(days: daysAgo))
                .subtract(Duration(hours: hoursOffset));

            final catchUpEvent = PlayEvent(
              trackId: trackId,
              trackName: trackName,
              albumId: albumId,
              albumName: albumName,
              artists: artists,
              genres: genres,
              timestamp: spreadTimestamp,
              durationMs: durationMs,
              synced: true, // Already on server
            );
            _events.add(catchUpEvent);
            addedCount++;
          }
        }
      }

      if (addedCount > 0) {
        // Sort events by timestamp
        _events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        await _saveEvents();
        debugPrint('📊 Sync: Added $addedCount catch-up events from server with full metadata');
      }

      return SyncResult(success: true, syncedCount: addedCount);
    } catch (e) {
      debugPrint('❌ Sync from server failed: $e');
      return SyncResult(success: false, error: e.toString());
    }
  }

  /// Full bidirectional sync
  /// 1. Push unsynced local plays to server
  /// 2. Pull server data to catch up any missing plays
  Future<SyncResult> fullSync({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
    List<String>? trackIdsToSync,
  }) async {
    debugPrint('📊 Starting full bidirectional sync...');

    // Step 1: Push local plays to server
    final pushResult = await syncToServer(
      client: client,
      credentials: credentials,
    );

    if (!pushResult.success && pushResult.error != null) {
      return pushResult;
    }

    // Step 2: If we have track IDs, pull server data
    if (trackIdsToSync != null && trackIdsToSync.isNotEmpty) {
      final pullResult = await syncFromServer(
        client: client,
        credentials: credentials,
        trackIds: trackIdsToSync,
      );

      return SyncResult(
        success: pushResult.success && pullResult.success,
        syncedCount: pushResult.syncedCount + pullResult.syncedCount,
        failedCount: pushResult.failedCount,
        errors: [...?pushResult.errors, ...?pullResult.errors],
      );
    }

    return pushResult;
  }

  /// Mark all current events as synced (use after initial sync from server)
  Future<void> markAllSynced() async {
    _events = _events.map((e) => e.copyWith(synced: true)).toList();
    await _saveEvents();
    debugPrint('📊 Marked all ${_events.length} events as synced');
  }
}

/// Result of a sync operation
class SyncResult {
  final bool success;
  final int syncedCount;
  final int failedCount;
  final String? error;
  final List<String>? errors;

  SyncResult({
    required this.success,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.error,
    this.errors,
  });

  @override
  String toString() {
    if (success) {
      return 'SyncResult: $syncedCount synced';
    } else {
      return 'SyncResult: FAILED - ${error ?? errors?.join(', ')}';
    }
  }
}
