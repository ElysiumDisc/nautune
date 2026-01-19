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
    artists: (json['artists'] as List<dynamic>).cast<String>(),
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

/// Represents a listening milestone/achievement
class ListeningMilestone {
  final String id;
  final String name;
  final String description;
  final IconType iconType;
  final int targetValue;
  final int currentValue;
  final bool isUnlocked;

  ListeningMilestone({
    required this.id,
    required this.name,
    required this.description,
    required this.iconType,
    required this.targetValue,
    required this.currentValue,
  }) : isUnlocked = currentValue >= targetValue;

  double get progress => (currentValue / targetValue).clamp(0.0, 1.0);
}

enum IconType {
  plays,
  hours,
  streak,
  artists,
  albums,
  tracks,
  genres,
  special,
}

/// Collection of all milestones with progress
class ListeningMilestones {
  final List<ListeningMilestone> all;
  final List<ListeningMilestone> unlocked;
  final ListeningMilestone? nextToUnlock;

  ListeningMilestones({
    required this.all,
  })  : unlocked = all.where((m) => m.isUnlocked).toList(),
        nextToUnlock = all.where((m) => !m.isUnlocked).fold<ListeningMilestone?>(
          null,
          (closest, m) => closest == null || m.progress > closest.progress ? m : closest,
        );

  int get unlockedCount => unlocked.length;
  int get totalCount => all.length;
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
  final bool discovered;

  RelaxModeStats({
    this.totalSessionsMs = 0,
    this.rainUsageMs = 0,
    this.thunderUsageMs = 0,
    this.campfireUsageMs = 0,
    this.discovered = false,
  });

  Duration get totalTime => Duration(milliseconds: totalSessionsMs);

  /// Get percentage of usage for each sound (0-100)
  double get rainPercent {
    final total = rainUsageMs + thunderUsageMs + campfireUsageMs;
    if (total == 0) return 0;
    return (rainUsageMs / total) * 100;
  }

  double get thunderPercent {
    final total = rainUsageMs + thunderUsageMs + campfireUsageMs;
    if (total == 0) return 0;
    return (thunderUsageMs / total) * 100;
  }

  double get campfirePercent {
    final total = rainUsageMs + thunderUsageMs + campfireUsageMs;
    if (total == 0) return 0;
    return (campfireUsageMs / total) * 100;
  }

  /// Get the favorite sound name
  String? get favoriteSoundName {
    if (rainUsageMs == 0 && thunderUsageMs == 0 && campfireUsageMs == 0) return null;
    if (rainUsageMs >= thunderUsageMs && rainUsageMs >= campfireUsageMs) return 'Rain';
    if (thunderUsageMs >= rainUsageMs && thunderUsageMs >= campfireUsageMs) return 'Thunder';
    return 'Campfire';
  }

  Map<String, dynamic> toJson() => {
    'totalSessionsMs': totalSessionsMs,
    'rainUsageMs': rainUsageMs,
    'thunderUsageMs': thunderUsageMs,
    'campfireUsageMs': campfireUsageMs,
    'discovered': discovered,
  };

  factory RelaxModeStats.fromJson(Map<String, dynamic> json) => RelaxModeStats(
    totalSessionsMs: json['totalSessionsMs'] as int? ?? 0,
    rainUsageMs: json['rainUsageMs'] as int? ?? 0,
    thunderUsageMs: json['thunderUsageMs'] as int? ?? 0,
    campfireUsageMs: json['campfireUsageMs'] as int? ?? 0,
    discovered: json['discovered'] as bool? ?? false,
  );

  RelaxModeStats copyWith({
    int? totalSessionsMs,
    int? rainUsageMs,
    int? thunderUsageMs,
    int? campfireUsageMs,
    bool? discovered,
  }) => RelaxModeStats(
    totalSessionsMs: totalSessionsMs ?? this.totalSessionsMs,
    rainUsageMs: rainUsageMs ?? this.rainUsageMs,
    thunderUsageMs: thunderUsageMs ?? this.thunderUsageMs,
    campfireUsageMs: campfireUsageMs ?? this.campfireUsageMs,
    discovered: discovered ?? this.discovered,
  );
}

/// Service for recording and querying local listening analytics
class ListeningAnalyticsService {
  static const _boxName = 'nautune_analytics';
  static const _eventsKey = 'play_events';
  static const _streakKey = 'streak_data';
  static const _relaxModeKey = 'relax_mode_stats';

  Box? _box;
  List<PlayEvent> _events = [];
  RelaxModeStats _relaxModeStats = RelaxModeStats();
  bool _initialized = false;

  /// Singleton instance
  static final ListeningAnalyticsService _instance = ListeningAnalyticsService._internal();
  factory ListeningAnalyticsService() => _instance;
  ListeningAnalyticsService._internal();

  bool get isInitialized => _initialized;

  /// Initialize the service and load existing data
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _box = await Hive.openBox(_boxName);
      await _loadEvents();
      await _loadRelaxModeStats();
      _initialized = true;
      debugPrint('ListeningAnalyticsService: Initialized with ${_events.length} events');
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Failed to initialize: $e');
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

  /// Mark Relax Mode as discovered (for milestone)
  Future<void> markRelaxModeDiscovered() async {
    if (_relaxModeStats.discovered) return;
    _relaxModeStats = _relaxModeStats.copyWith(discovered: true);
    await _saveRelaxModeStats();
    debugPrint('ListeningAnalyticsService: Relax Mode discovered!');
  }

  /// Record Relax Mode session usage
  /// Call this when exiting Relax Mode with the duration and slider usage
  Future<void> recordRelaxModeSession({
    required Duration sessionDuration,
    required Duration rainUsage,
    required Duration thunderUsage,
    required Duration campfireUsage,
  }) async {
    if (!_initialized) return;

    _relaxModeStats = RelaxModeStats(
      totalSessionsMs: _relaxModeStats.totalSessionsMs + sessionDuration.inMilliseconds,
      rainUsageMs: _relaxModeStats.rainUsageMs + rainUsage.inMilliseconds,
      thunderUsageMs: _relaxModeStats.thunderUsageMs + thunderUsage.inMilliseconds,
      campfireUsageMs: _relaxModeStats.campfireUsageMs + campfireUsage.inMilliseconds,
      discovered: true,
    );

    await _saveRelaxModeStats();
    debugPrint('ListeningAnalyticsService: Recorded Relax Mode session (${sessionDuration.inMinutes}m)');
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

      _events = jsonList
          .map((e) => PlayEvent.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();

      // Sort by timestamp descending (most recent first)
      _events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      debugPrint('ListeningAnalyticsService: Error loading events: $e');
      _events = [];
    }
  }

  Future<void> _saveEvents() async {
    if (_box == null) return;

    // Keep only last 180 days (6 months) of events to prevent unbounded growth
    final cutoff = DateTime.now().subtract(const Duration(days: 180));
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));

    final jsonList = _events.map((e) => e.toJson()).toList();
    await _box!.put(_eventsKey, jsonEncode(jsonList));
  }

  /// Record a play event for a track
  Future<void> recordPlay(JellyfinTrack track) async {
    if (!_initialized) {
      debugPrint('ListeningAnalyticsService: Not initialized, skipping record');
      return;
    }

    final event = PlayEvent(
      trackId: track.id,
      trackName: track.name,
      albumId: track.albumId,
      albumName: track.album,
      artists: track.artists,
      genres: track.genres ?? [],
      timestamp: DateTime.now(),
      durationMs: track.runTimeTicks != null ? track.runTimeTicks! ~/ 10000 : 0,
    );

    _events.insert(0, event); // Add to front (most recent)

    // Save asynchronously
    unawaited(_saveEvents());

    debugPrint('ListeningAnalyticsService: Recorded play for "${track.name}"');
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
      if (event.timestamp.isAfter(currentStart) && event.timestamp.isBefore(currentEnd)) {
        currentPlays++;
        currentTimeMs += event.durationMs;
        currentTracks.add(event.trackId);
      } else if (event.timestamp.isAfter(previousStart) && event.timestamp.isBefore(previousEnd)) {
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

  /// Get milestone achievements with progress
  ListeningMilestones getMilestones() {
    final totalPlays = _events.length;
    final totalHoursValue = getTotalListeningTime().inMinutes / 60.0;
    final streak = getStreakInfo();
    final uniqueArtists = <String>{};
    final uniqueAlbums = <String>{};
    final uniqueTracks = <String>{};
    final uniqueGenres = <String>{};

    // Count night owl (10pm-4am), early bird (5am-8am), and weekend plays
    int nightOwlPlays = 0;
    int earlyBirdPlays = 0;
    int weekendPlays = 0;

    for (final event in _events) {
      uniqueTracks.add(event.trackId);
      uniqueArtists.addAll(event.artists);
      uniqueGenres.addAll(event.genres);
      if (event.albumId != null) {
        uniqueAlbums.add(event.albumId!);
      }

      // Check time of day
      final hour = event.timestamp.hour;
      if (hour >= 22 || hour < 4) {
        nightOwlPlays++;
      } else if (hour >= 5 && hour <= 8) {
        earlyBirdPlays++;
      }

      // Check if weekend (Saturday = 6, Sunday = 7)
      final weekday = event.timestamp.weekday;
      if (weekday == DateTime.saturday || weekday == DateTime.sunday) {
        weekendPlays++;
      }
    }

    // Calculate marathon sessions (sessions over 2 hours)
    int marathonSessions = 0;
    if (_events.isNotEmpty) {
      final sortedEvents = List<PlayEvent>.from(_events)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      DateTime? lastEventTime;
      int sessionDurationMs = 0;

      for (final event in sortedEvents) {
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
    }

    final milestones = <ListeningMilestone>[
      // Play count milestones - Voyage themed
      ListeningMilestone(
        id: 'plays_10',
        name: 'Setting Sail',
        description: 'Play 10 tracks',
        iconType: IconType.plays,
        targetValue: 10,
        currentValue: totalPlays,
      ),
      ListeningMilestone(
        id: 'plays_100',
        name: 'Open Waters',
        description: 'Play 100 tracks',
        iconType: IconType.plays,
        targetValue: 100,
        currentValue: totalPlays,
      ),
      ListeningMilestone(
        id: 'plays_500',
        name: 'Seasoned Sailor',
        description: 'Play 500 tracks',
        iconType: IconType.plays,
        targetValue: 500,
        currentValue: totalPlays,
      ),
      ListeningMilestone(
        id: 'plays_1000',
        name: 'Fleet Captain',
        description: 'Play 1,000 tracks',
        iconType: IconType.plays,
        targetValue: 1000,
        currentValue: totalPlays,
      ),
      ListeningMilestone(
        id: 'plays_5000',
        name: 'Admiral',
        description: 'Play 5,000 tracks',
        iconType: IconType.plays,
        targetValue: 5000,
        currentValue: totalPlays,
      ),
      ListeningMilestone(
        id: 'plays_10000',
        name: 'Grand Admiral',
        description: 'Play 10,000 tracks',
        iconType: IconType.plays,
        targetValue: 10000,
        currentValue: totalPlays,
      ),

      // Hours milestones - Depth themed
      ListeningMilestone(
        id: 'hours_1',
        name: 'First Tide',
        description: 'Listen for 1 hour',
        iconType: IconType.hours,
        targetValue: 1,
        currentValue: totalHoursValue.floor(),
      ),
      ListeningMilestone(
        id: 'hours_10',
        name: 'Ocean Current',
        description: 'Listen for 10 hours',
        iconType: IconType.hours,
        targetValue: 10,
        currentValue: totalHoursValue.floor(),
      ),
      ListeningMilestone(
        id: 'hours_50',
        name: 'Deep Sea Diver',
        description: 'Listen for 50 hours',
        iconType: IconType.hours,
        targetValue: 50,
        currentValue: totalHoursValue.floor(),
      ),
      ListeningMilestone(
        id: 'hours_100',
        name: 'Mariana Depths',
        description: 'Listen for 100 hours',
        iconType: IconType.hours,
        targetValue: 100,
        currentValue: totalHoursValue.floor(),
      ),
      ListeningMilestone(
        id: 'hours_250',
        name: 'Abyssal Explorer',
        description: 'Listen for 250 hours',
        iconType: IconType.hours,
        targetValue: 250,
        currentValue: totalHoursValue.floor(),
      ),
      ListeningMilestone(
        id: 'hours_500',
        name: 'Kraken\'s Domain',
        description: 'Listen for 500 hours',
        iconType: IconType.hours,
        targetValue: 500,
        currentValue: totalHoursValue.floor(),
      ),

      // Streak milestones - Wind/Weather themed
      ListeningMilestone(
        id: 'streak_3',
        name: 'Sea Breeze',
        description: '3-day listening streak',
        iconType: IconType.streak,
        targetValue: 3,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_7',
        name: 'Trade Winds',
        description: '7-day listening streak',
        iconType: IconType.streak,
        targetValue: 7,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_14',
        name: 'Monsoon Season',
        description: '14-day listening streak',
        iconType: IconType.streak,
        targetValue: 14,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_30',
        name: 'Steady Current',
        description: '30-day listening streak',
        iconType: IconType.streak,
        targetValue: 30,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_60',
        name: 'Tidal Force',
        description: '60-day listening streak',
        iconType: IconType.streak,
        targetValue: 60,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_100',
        name: 'Eternal Voyage',
        description: '100-day listening streak',
        iconType: IconType.streak,
        targetValue: 100,
        currentValue: streak.longestStreak,
      ),
      ListeningMilestone(
        id: 'streak_365',
        name: 'Poseidon\'s Blessing',
        description: '365-day listening streak',
        iconType: IconType.streak,
        targetValue: 365,
        currentValue: streak.longestStreak,
      ),

      // Artist milestones - Explorer themed
      ListeningMilestone(
        id: 'artists_10',
        name: 'Port Explorer',
        description: 'Listen to 10 different artists',
        iconType: IconType.artists,
        targetValue: 10,
        currentValue: uniqueArtists.length,
      ),
      ListeningMilestone(
        id: 'artists_50',
        name: 'Island Hopper',
        description: 'Listen to 50 different artists',
        iconType: IconType.artists,
        targetValue: 50,
        currentValue: uniqueArtists.length,
      ),
      ListeningMilestone(
        id: 'artists_100',
        name: 'World Voyager',
        description: 'Listen to 100 different artists',
        iconType: IconType.artists,
        targetValue: 100,
        currentValue: uniqueArtists.length,
      ),
      ListeningMilestone(
        id: 'artists_250',
        name: 'Seven Seas Explorer',
        description: 'Listen to 250 different artists',
        iconType: IconType.artists,
        targetValue: 250,
        currentValue: uniqueArtists.length,
      ),

      // Album milestones - Treasure themed
      ListeningMilestone(
        id: 'albums_10',
        name: 'Treasure Hunter',
        description: 'Listen to tracks from 10 albums',
        iconType: IconType.albums,
        targetValue: 10,
        currentValue: uniqueAlbums.length,
      ),
      ListeningMilestone(
        id: 'albums_50',
        name: 'Chest Collector',
        description: 'Listen to tracks from 50 albums',
        iconType: IconType.albums,
        targetValue: 50,
        currentValue: uniqueAlbums.length,
      ),
      ListeningMilestone(
        id: 'albums_100',
        name: 'Sunken Treasure',
        description: 'Listen to tracks from 100 albums',
        iconType: IconType.albums,
        targetValue: 100,
        currentValue: uniqueAlbums.length,
      ),
      ListeningMilestone(
        id: 'albums_200',
        name: 'Golden Armada',
        description: 'Listen to tracks from 200 albums',
        iconType: IconType.albums,
        targetValue: 200,
        currentValue: uniqueAlbums.length,
      ),

      // Track milestones - Shell/Pearl themed
      ListeningMilestone(
        id: 'tracks_50',
        name: 'Shell Seeker',
        description: 'Discover 50 unique tracks',
        iconType: IconType.tracks,
        targetValue: 50,
        currentValue: uniqueTracks.length,
      ),
      ListeningMilestone(
        id: 'tracks_200',
        name: 'Pearl Diver',
        description: 'Discover 200 unique tracks',
        iconType: IconType.tracks,
        targetValue: 200,
        currentValue: uniqueTracks.length,
      ),
      ListeningMilestone(
        id: 'tracks_500',
        name: 'Coral Reef',
        description: 'Discover 500 unique tracks',
        iconType: IconType.tracks,
        targetValue: 500,
        currentValue: uniqueTracks.length,
      ),
      ListeningMilestone(
        id: 'tracks_1000',
        name: 'Ocean\'s Symphony',
        description: 'Discover 1,000 unique tracks',
        iconType: IconType.tracks,
        targetValue: 1000,
        currentValue: uniqueTracks.length,
      ),

      // Genre milestones - Navigation themed
      ListeningMilestone(
        id: 'genres_5',
        name: 'Compass Rose',
        description: 'Explore 5 different genres',
        iconType: IconType.genres,
        targetValue: 5,
        currentValue: uniqueGenres.length,
      ),
      ListeningMilestone(
        id: 'genres_10',
        name: 'Chart Master',
        description: 'Explore 10 different genres',
        iconType: IconType.genres,
        targetValue: 10,
        currentValue: uniqueGenres.length,
      ),
      ListeningMilestone(
        id: 'genres_20',
        name: 'Musical Navigator',
        description: 'Explore 20 different genres',
        iconType: IconType.genres,
        targetValue: 20,
        currentValue: uniqueGenres.length,
      ),

      // Special time-based milestones - Creature themed
      ListeningMilestone(
        id: 'night_owl_50',
        name: 'Night Whale',
        description: 'Play 50 tracks between 10pm-4am',
        iconType: IconType.special,
        targetValue: 50,
        currentValue: nightOwlPlays,
      ),
      ListeningMilestone(
        id: 'night_owl_200',
        name: 'Midnight Kraken',
        description: 'Play 200 tracks between 10pm-4am',
        iconType: IconType.special,
        targetValue: 200,
        currentValue: nightOwlPlays,
      ),
      ListeningMilestone(
        id: 'early_bird_50',
        name: 'Dawn Dolphin',
        description: 'Play 50 tracks between 5am-8am',
        iconType: IconType.special,
        targetValue: 50,
        currentValue: earlyBirdPlays,
      ),
      ListeningMilestone(
        id: 'early_bird_200',
        name: 'Sunrise Siren',
        description: 'Play 200 tracks between 5am-8am',
        iconType: IconType.special,
        targetValue: 200,
        currentValue: earlyBirdPlays,
      ),

      // Weekend milestones - Calendar themed
      ListeningMilestone(
        id: 'weekend_100',
        name: 'Weekend Captain',
        description: 'Play 100 tracks on weekends',
        iconType: IconType.special,
        targetValue: 100,
        currentValue: weekendPlays,
      ),

      // Marathon milestones - Endurance themed
      ListeningMilestone(
        id: 'marathon_5',
        name: 'Marathon Voyager',
        description: 'Have 5 listening sessions over 2 hours',
        iconType: IconType.special,
        targetValue: 5,
        currentValue: marathonSessions,
      ),

      // Relax Mode milestone - Hidden feature discovery
      ListeningMilestone(
        id: 'relax_mode',
        name: 'Calm Waters',
        description: 'Discover the hidden Relax Mode',
        iconType: IconType.special,
        targetValue: 1,
        currentValue: _relaxModeStats.discovered ? 1 : 0,
      ),
    ];

    return ListeningMilestones(all: milestones);
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

    debugPrint('📊 Sync: Pushing ${unsynced.length} unsynced plays to server...');

    int syncedCount = 0;
    int failedCount = 0;
    final errors = <String>[];

    for (final event in unsynced) {
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
      // Get server play counts in batches
      final serverData = await client.getBatchUserItemData(
        credentials: credentials,
        itemIds: trackIds,
      );

      int addedCount = 0;

      for (final trackId in trackIds) {
        final userData = serverData[trackId];
        if (userData == null) continue;

        final serverPlayCount = userData['PlayCount'] as int? ?? 0;
        final lastPlayedStr = userData['LastPlayedDate'] as String?;

        // Count local plays for this track
        final localPlayCount = _events.where((e) => e.trackId == trackId).length;

        // If server has more plays than we have locally, we're missing data
        if (serverPlayCount > localPlayCount) {
          final missingCount = serverPlayCount - localPlayCount;
          debugPrint('📊 Track $trackId: server=$serverPlayCount, local=$localPlayCount, missing=$missingCount');

          // Create catch-up events marked as synced (they came from server)
          final lastPlayed = lastPlayedStr != null
              ? DateTime.tryParse(lastPlayedStr)
              : DateTime.now();

          for (int i = 0; i < missingCount; i++) {
            final catchUpEvent = PlayEvent(
              trackId: trackId,
              trackName: 'Synced from server', // We don't have the name
              artists: [],
              genres: [],
              timestamp: lastPlayed ?? DateTime.now(),
              durationMs: 0,
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
        debugPrint('📊 Sync: Added $addedCount catch-up events from server');
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
