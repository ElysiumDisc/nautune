import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/server_uri.dart';

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

  /// Account the play belongs to (null for events recorded before v9 —
  /// "untagged"). Used so one account's plays are never pushed to, or shown
  /// for, another account.
  final String? userId;
  final String? serverUrl;

  /// Synthetic event reconstructed from the server's PlayCount (its
  /// timestamp is invented), excluded from time-of-day / calendar stats.
  final bool isCatchUp;

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
    this.userId,
    this.serverUrl,
    this.isCatchUp = false,
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
    userId: userId,
    serverUrl: serverUrl,
    isCatchUp: isCatchUp,
  );

  /// Whether this event belongs to the account ([serverUrl], [userId]).
  ///
  /// Jellyfin user ids are GUIDs, so when both sides have one it alone
  /// decides (the same account reached through a different server address
  /// stays the same account). The server address is only compared when a
  /// user id is missing. Untagged (legacy) events belong to no account.
  bool belongsTo({String? serverUrl, String? userId}) {
    final mine = this.userId;
    if (mine != null && userId != null) return mine == userId;
    final myServer = this.serverUrl;
    if (myServer != null && serverUrl != null) {
      return normalizeServerBaseUrl(myServer) ==
          normalizeServerBaseUrl(serverUrl);
    }
    return false;
  }

  bool get isUntagged => userId == null && serverUrl == null;

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
    if (userId != null) 'userId': userId,
    if (serverUrl != null) 'serverUrl': serverUrl,
    if (isCatchUp) 'isCatchUp': true,
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
    userId: json['userId'] as String?,
    serverUrl: json['serverUrl'] as String?,
    isCatchUp: json['isCatchUp'] as bool? ?? false,
  );
}

/// Whole calendar days from [from] to [to] (local dates), immune to DST:
/// a 23- or 25-hour day still counts as one day.
int calendarDaysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// Local calendar date of [t] shifted by [days] (DST-safe: built with the
/// calendar constructor, not by subtracting 24-hour durations).
DateTime localDateOffset(DateTime t, int days) =>
    DateTime(t.year, t.month, t.day + days);

/// Current and longest listening streak for play [timestamps] as of [now].
/// Pure (and DST-safe) so it can be tested.
ListeningStreak computeListeningStreak(
  Iterable<DateTime> timestamps,
  DateTime now,
) {
  final days = <DateTime>{
    for (final t in timestamps) DateTime(t.year, t.month, t.day),
  };
  if (days.isEmpty) {
    return ListeningStreak(currentStreak: 0, longestStreak: 0, listenedToday: false);
  }
  final sortedDays = days.toList()..sort((a, b) => b.compareTo(a));
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = localDateOffset(today, -1);
  final listenedToday = sortedDays.first == today;

  var currentStreak = 0;
  if (listenedToday || sortedDays.first == yesterday) {
    var checkDate = listenedToday ? today : yesterday;
    for (final day in sortedDays) {
      if (day == checkDate) {
        currentStreak++;
        checkDate = localDateOffset(checkDate, -1);
      } else if (day.isBefore(checkDate)) {
        break;
      }
    }
  }

  var longestStreak = 0;
  var tempStreak = 0;
  DateTime? prevDay;
  for (final day in sortedDays.reversed) {
    if (prevDay != null && calendarDaysBetween(prevDay, day) == 1) {
      tempStreak++;
    } else {
      tempStreak = 1;
    }
    if (tempStreak > longestStreak) longestStreak = tempStreak;
    prevDay = day;
  }

  return ListeningStreak(
    currentStreak: currentStreak,
    longestStreak: longestStreak,
    lastListeningDate: sortedDays.first,
    listenedToday: listenedToday,
  );
}

/// Start (local midnight) of the Monday-based week containing [now].
DateTime startOfWeek(DateTime now) =>
    DateTime(now.year, now.month, now.day - (now.weekday - 1));

/// Play counts per calendar day for the [days] days ending today (index 0 =
/// oldest), DST-safe.
List<int> dailyPlayCounts(Iterable<DateTime> timestamps, DateTime now, int days) {
  final counts = List<int>.filled(days, 0);
  for (final t in timestamps) {
    final daysAgo = calendarDaysBetween(t, now);
    if (daysAgo >= 0 && daysAgo < days) counts[days - 1 - daysAgo]++;
  }
  return counts;
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

  /// Legacy storage: the whole history as one JSON string under one key
  /// (rewritten in full on every play). Migrated to per-event keys.
  static const _eventsKey = 'play_events';

  /// Each event is stored under `ev:<eventId>` so recording a play writes
  /// one small record instead of re-encoding the whole year of history.
  static const _eventKeyPrefix = 'ev:';
  static const _streakKey = 'streak_data';
  static const _relaxModeKey = 'relax_mode_stats';
  static const _pianoStatsKey = 'piano_stats';

  /// Events older than this are pruned.
  static const Duration _retention = Duration(days: 365);

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
  Future<void>? _initializing;
  Future<SyncResult>? _syncing;

  String? _accountServerUrl;
  String? _accountUserId;

  /// Singleton instance
  static final ListeningAnalyticsService _instance = ListeningAnalyticsService._internal();
  factory ListeningAnalyticsService() => _instance;
  ListeningAnalyticsService._internal();

  bool get isInitialized => _initialized;

  /// Scope the stats getters to one account: events tagged with another
  /// account are hidden (untagged legacy events stay visible). Pass nulls
  /// (e.g. on logout) to show everything.
  void setCurrentAccount({String? serverUrl, String? userId}) {
    if (_accountServerUrl == serverUrl && _accountUserId == userId) return;
    _accountServerUrl = serverUrl;
    _accountUserId = userId;
    notifyListeners();
  }

  bool _isVisible(PlayEvent e) {
    final server = _accountServerUrl;
    final user = _accountUserId;
    if ((server == null && user == null) || e.isUntagged) return true;
    return e.belongsTo(serverUrl: server, userId: user);
  }

  /// Events of the current account (newest first).
  Iterable<PlayEvent> get _visibleEvents => _events.where(_isVisible);

  /// Real (non-synthetic) events of the current account, for stats that
  /// depend on when a play happened.
  Iterable<PlayEvent> get _timedEvents =>
      _visibleEvents.where((e) => !e.isCatchUp);

  /// Check if a track ID belongs to an easter egg (not a real Jellyfin track)
  bool _isEasterEggTrack(String trackId) {
    return trackId.startsWith('essential-mix') ||
        trackId.startsWith('network-') ||
        trackId.startsWith('relax-');
  }

  /// Initialize the service and load existing data
  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _initialize().whenComplete(() => _initializing = null);
  }

  Future<void> _initialize() async {
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
        _pruneOldEvents(),
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

  // Piano stats tracking (notes played, session time).
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

  static String _eventKey(PlayEvent e) => '$_eventKeyPrefix${e.eventId}';

  Future<void> _loadEvents() async {
    final box = _box;
    if (box == null) {
      _events = [];
      return;
    }
    final loaded = <String, PlayEvent>{};

    PlayEvent? decode(Object? raw) {
      try {
        if (raw is String) {
          return PlayEvent.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map));
        }
        if (raw is Map) return PlayEvent.fromJson(Map<String, dynamic>.from(raw));
      } catch (e) {
        debugPrint('ListeningAnalyticsService: skipping bad event: $e');
      }
      return null;
    }

    // Per-event records (current format).
    for (final key in box.keys) {
      if (key is String && key.startsWith(_eventKeyPrefix)) {
        final event = decode(box.get(key));
        if (event != null) loaded[event.eventId!] = event;
      }
    }

    // One-time migration of the legacy single-blob history. Decoded per
    // event so one malformed row can't wipe the whole history.
    final legacy = box.get(_eventsKey);
    if (legacy != null) {
      List<dynamic> list = const [];
      try {
        if (legacy is String) {
          list = jsonDecode(legacy) as List<dynamic>;
        } else if (legacy is List) {
          list = legacy;
        }
      } catch (e) {
        debugPrint('ListeningAnalyticsService: Error loading legacy events: $e');
      }
      final migrated = <String, dynamic>{};
      for (final raw in list) {
        var event = decode(raw);
        if (event == null) continue;
        // Legacy events carry no account. Pushing them would risk sending
        // account A's plays to account B's server, and online plays were
        // already counted by the Jellyfin playback reports, so they are
        // treated as already synced.
        if (!event.synced) event = event.copyWith(synced: true);
        loaded.putIfAbsent(event.eventId!, () => event!);
        migrated[_eventKey(event)] = event.toJson();
      }
      await box.putAll(migrated);
      await box.delete(_eventsKey);
      debugPrint('ListeningAnalyticsService: Migrated ${migrated.length} events to per-event storage');
    }

    _events = loaded.values.toList()
      // Sort by timestamp descending (most recent first)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    await _pruneOldEvents();
  }

  /// Persist [events] (new or changed) as individual records.
  Future<void> _persistEvents(Iterable<PlayEvent> events) async {
    final box = _box;
    if (box == null) return;
    final entries = {for (final e in events) _eventKey(e): e.toJson()};
    if (entries.isEmpty) return;
    await box.putAll(entries);
  }

  /// Drop events older than [_retention] (keeps a year for streaks, period
  /// comparisons and top content on the Profile dashboard).
  Future<void> _pruneOldEvents() async {
    final cutoff = DateTime.now().subtract(_retention);
    final old = _events.where((e) => e.timestamp.isBefore(cutoff)).toList();
    if (old.isEmpty) return;
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
    await _box?.deleteAll(old.map(_eventKey));
  }

  /// Record a play event for a track with actual listening duration
  /// [actualDurationMs] - The actual time listened in milliseconds (not full track length)
  /// [playStartTime] - When the track started playing (for accurate timestamp)
  /// [reportedToServer] - whether Jellyfin already counts this play through
  /// the playback start/stop reports (sent live, or queued offline and
  /// replayed later). Such events are stored as synced and are never pushed
  /// again with `markPlayed`, which would count the play a second time.
  /// Pass false only when no playback reporting covered the play.
  Future<void> recordPlay(
    JellyfinTrack track, {
    int? actualDurationMs,
    DateTime? playStartTime,
    bool reportedToServer = true,
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
      synced: reportedToServer,
      userId: track.userId,
      serverUrl: track.serverUrl,
    );

    _events.insert(0, event); // Add to front (most recent)

    // One small write instead of re-encoding the whole history.
    unawaited(_persistEvents([event]));

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

    for (final event in _timedEvents) {
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

    for (final event in _timedEvents) {
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
    for (final event in _timedEvents) {
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

  /// Get listening streak information (DST-safe calendar-day arithmetic).
  ListeningStreak getStreakInfo() {
    return computeListeningStreak(
      _timedEvents.map((e) => e.timestamp),
      DateTime.now(),
    );
  }

  /// Compare this week vs last week
  PeriodComparison getWeekOverWeekComparison() {
    final now = DateTime.now();
    final startOfThisWeek = startOfWeek(now);
    final startOfLastWeek = localDateOffset(startOfThisWeek, -7);

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

    for (final event in _timedEvents) {
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
    return _visibleEvents.where((e) => e.timestamp.isAfter(cutoff)).length;
  }

  /// Get total listening time in the given date range
  Duration getTotalListeningTime({DateTime? since}) {
    final cutoff = since ?? DateTime(2000);
    int totalMs = 0;
    for (final event in _visibleEvents) {
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
    return dailyPlayCounts(
      _timedEvents.map((e) => e.timestamp),
      DateTime.now(),
      days,
    );
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
    final relevantEvents = _timedEvents
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
    return _visibleEvents.take(limit).toList();
  }

  /// Get play events from the same day in previous months/years (On This Day)
  /// Returns events from:
  /// - Same day of the month in any previous month (e.g., Jan 15th shows Dec 15th, Nov 15th, etc.)
  /// - Prioritizes more recent events
  List<PlayEvent> getOnThisDayEvents() {
    final now = DateTime.now();
    final today = now.day;
    final todayDate = DateTime(now.year, now.month, now.day);

    // Find events from the same day of the month in any previous month
    final matchingEvents = _timedEvents.where((event) {
      // Must be from a previous date (not today)
      final eventDate = DateTime(event.timestamp.year, event.timestamp.month, event.timestamp.day);
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
    final relevantEvents = _timedEvents
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
    final relevantEvents = _visibleEvents.where((e) => e.timestamp.isAfter(cutoff)).toList();

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
    final keys = _events.map(_eventKey).toList();
    _events.clear();
    await _box?.deleteAll(keys);
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
      final imported = <PlayEvent>[];

      // Import play events
      final eventsJson = jsonData['play_events'] as List<dynamic>?;
      if (eventsJson != null) {
        final existingEventIds = _events.map((e) => e.eventId).toSet();

        for (final eventJson in eventsJson) {
          try {
            final parsed = PlayEvent.fromJson(
              Map<String, dynamic>.from(eventJson as Map),
            );
            // Imported plays are history, never pushed to a server: the
            // backup may come from another account/server.
            final event = parsed.synced ? parsed : parsed.copyWith(synced: true);
            // Only add if not a duplicate (by eventId)
            if (!existingEventIds.contains(event.eventId)) {
              _events.add(event);
              imported.add(event);
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
          _persistEvents(imported),
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
  int get totalEventCount => _visibleEvents.length;

  // ============ Server Sync Methods ============

  /// Unsynced events of the current account (see [setCurrentAccount]); with
  /// no account set, all unsynced events.
  List<PlayEvent> getUnsyncedEvents() {
    return _visibleEvents.where((e) => !e.synced).toList();
  }

  /// Get count of unsynced events
  int get unsyncedCount => _visibleEvents.where((e) => !e.synced).length;

  /// Events [syncToServer] would push for this account: unsynced, tagged
  /// with this account (see [PlayEvent.belongsTo]), and real Jellyfin tracks.
  @visibleForTesting
  List<PlayEvent> pushableEvents({
    required String serverUrl,
    required String userId,
  }) =>
      _events
          .where((e) =>
              !e.synced &&
              !e.isCatchUp &&
              !_isEasterEggTrack(e.trackId) &&
              e.belongsTo(serverUrl: serverUrl, userId: userId))
          .toList();

  /// Push plays that no Jellyfin playback report covered to the server
  /// (`POST /UserPlayedItems/{id}?datePlayed=…`, which increments
  /// PlayCount). Only this account's events are pushed. Single-flight:
  /// concurrent callers share one run, so no event is pushed twice.
  Future<SyncResult> syncToServer({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
  }) {
    return _syncing ??= _syncToServer(client: client, credentials: credentials)
        .whenComplete(() => _syncing = null);
  }

  Future<SyncResult> _syncToServer({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
  }) async {
    if (!_initialized) {
      return SyncResult(success: false, error: 'Service not initialized');
    }

    // Easter-egg plays (not Jellyfin items) never sync; mark them done.
    final eggs = _events
        .where((e) => !e.synced && _isEasterEggTrack(e.trackId))
        .toList();
    if (eggs.isNotEmpty) {
      _markSynced(eggs.map((e) => e.eventId!).toSet());
      debugPrint('📊 Sync: Skipped ${eggs.length} easter egg plays (not Jellyfin tracks)');
    }

    final syncable = pushableEvents(
      serverUrl: client.serverUrl,
      userId: credentials.userId,
    );
    if (syncable.isEmpty) {
      debugPrint('📊 Sync: No syncable events to push');
      return SyncResult(success: true, syncedCount: 0);
    }

    debugPrint('📊 Sync: Pushing ${syncable.length} unreported plays to server...');

    int syncedCount = 0;
    int failedCount = 0;
    final errors = <String>[];
    final done = <String>{};

    for (final event in syncable) {
      try {
        final result = await client.markPlayed(
          credentials: credentials,
          itemId: event.trackId,
          datePlayed: event.timestamp,
        );

        if (result != null) {
          done.add(event.eventId!);
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
    _markSynced(done);

    debugPrint('📊 Sync complete: $syncedCount synced, $failedCount failed');

    return SyncResult(
      success: failedCount == 0,
      syncedCount: syncedCount,
      failedCount: failedCount,
      errors: errors.isNotEmpty ? errors : null,
    );
  }

  /// Marks the events with [eventIds] as synced and persists them.
  void _markSynced(Set<String> eventIds) {
    if (eventIds.isEmpty) return;
    final changed = <PlayEvent>[];
    for (var i = 0; i < _events.length; i++) {
      final e = _events[i];
      if (!e.synced && eventIds.contains(e.eventId)) {
        _events[i] = e.copyWith(synced: true);
        changed.add(_events[i]);
      }
    }
    unawaited(_persistEvents(changed));
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

      final added = <PlayEvent>[];
      final localCounts = <String, int>{};
      for (final e in _events) {
        if (e.belongsTo(serverUrl: client.serverUrl, userId: credentials.userId)) {
          localCounts[e.trackId] = (localCounts[e.trackId] ?? 0) + 1;
        }
      }

      for (final trackId in trackIds) {
        final itemData = serverData[trackId];
        if (itemData == null) continue;

        final userData = itemData['UserData'] as Map<String, dynamic>?;
        if (userData == null) continue;

        final serverPlayCount = (userData['PlayCount'] as num?)?.toInt() ?? 0;
        final lastPlayedStr = userData['LastPlayedDate'] as String?;

        // Extract track metadata from server response
        final trackName = itemData['Name'] as String? ?? 'Unknown Track';
        final rawArtists = itemData['Artists'] as List<dynamic>?;
        final artists = rawArtists?.whereType<String>().toList() ?? <String>[];
        final rawGenres = itemData['Genres'] as List<dynamic>?;
        final genres = rawGenres?.whereType<String>().toList() ?? <String>[];
        final albumId = itemData['AlbumId'] as String?;
        final albumName = itemData['Album'] as String?;
        final runTimeTicks = (itemData['RunTimeTicks'] as num?)?.toInt();
        final durationMs = runTimeTicks != null ? runTimeTicks ~/ 10000 : 0;

        // Count local plays for this track (this account only)
        final localPlayCount = localCounts[trackId] ?? 0;

        // If server has more plays than we have locally, we're missing data
        if (serverPlayCount > localPlayCount) {
          final missingCount = serverPlayCount - localPlayCount;

          // Server dates are UTC: convert so local-day stats line up.
          final baseTime = (lastPlayedStr != null
                  ? DateTime.tryParse(lastPlayedStr)?.toLocal()
                  : null) ??
              DateTime.now();

          // Spread the synthetic plays over the 30 days up to lastPlayed.
          // They are flagged isCatchUp and excluded from time-based stats.
          for (int i = 0; i < missingCount; i++) {
            final daysAgo = (i * 30) ~/ missingCount;
            final hoursOffset = (i * 7) % 24;
            final spreadTimestamp = baseTime
                .subtract(Duration(days: daysAgo))
                .subtract(Duration(hours: hoursOffset));

            added.add(PlayEvent(
              trackId: trackId,
              trackName: trackName,
              albumId: albumId,
              albumName: albumName,
              artists: artists,
              genres: genres,
              timestamp: spreadTimestamp,
              durationMs: durationMs,
              synced: true, // Already on server
              eventId: '${trackId}_catchup_${spreadTimestamp.millisecondsSinceEpoch}_$i',
              userId: credentials.userId,
              serverUrl: client.serverUrl,
              isCatchUp: true,
            ));
          }
        }
      }

      if (added.isNotEmpty) {
        _events
          ..addAll(added)
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        await _persistEvents(added);
        debugPrint('📊 Sync: Added ${added.length} catch-up events from server with full metadata');
      }

      return SyncResult(success: true, syncedCount: added.length);
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
    final changedIds = {
      for (final e in _events)
        if (!e.synced) e.eventId,
    };
    _events = _events.map((e) => e.synced ? e : e.copyWith(synced: true)).toList();
    await _persistEvents(_events.where((e) => changedIds.contains(e.eventId)));
    debugPrint('📊 Marked all ${_events.length} events as synced');
  }

  /// Test hook: load [events] as if read from storage.
  @visibleForTesting
  void debugSetEvents(List<PlayEvent> events) {
    _events = [...events]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _initialized = true;
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
