import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/services/listening_analytics_service.dart';

PlayEvent _event(
  String id,
  DateTime at, {
  bool synced = false,
  String? user = 'u1',
  String? server = 'https://a.example/jf',
  bool catchUp = false,
}) =>
    PlayEvent(
      trackId: id,
      trackName: id,
      artists: const ['A'],
      genres: const [],
      timestamp: at,
      durationMs: 60000,
      synced: synced,
      userId: user,
      serverUrl: server,
      isCatchUp: catchUp,
    );

void main() {
  group('DST-safe calendar arithmetic', () {
    // US DST starts 2026-03-08 and ends 2026-11-01; EU on 2026-03-29 and
    // 2026-10-25. Whatever the test machine's zone, these must hold.
    test('calendarDaysBetween counts calendar days across DST changes', () {
      expect(calendarDaysBetween(DateTime(2026, 3, 7, 23), DateTime(2026, 3, 9, 0, 30)), 2);
      expect(calendarDaysBetween(DateTime(2026, 11, 1), DateTime(2026, 11, 2)), 1);
      expect(calendarDaysBetween(DateTime(2026, 3, 29), DateTime(2026, 3, 30)), 1);
      expect(calendarDaysBetween(DateTime(2026, 10, 25), DateTime(2026, 10, 24)), -1);
    });

    test('localDateOffset lands on local midnight of the target day', () {
      final d = localDateOffset(DateTime(2026, 3, 9, 0, 30), -1);
      expect([d.year, d.month, d.day, d.hour], [2026, 3, 8, 0]);
      final e = localDateOffset(DateTime(2026, 11, 2), -1);
      expect([e.month, e.day, e.hour], [11, 1, 0]);
    });

    test('streak spanning the spring-forward and fall-back days', () {
      final spring = computeListeningStreak([
        for (var d = 5; d <= 10; d++) DateTime(2026, 3, d, 0, 30),
      ], DateTime(2026, 3, 10, 12));
      expect(spring.currentStreak, 6);
      expect(spring.longestStreak, 6);
      expect(spring.listenedToday, isTrue);

      final fall = computeListeningStreak([
        for (var d = 30; d <= 31; d++) DateTime(2026, 10, d, 23, 30),
        for (var d = 1; d <= 2; d++) DateTime(2026, 11, d, 23, 30),
      ], DateTime(2026, 11, 3, 9));
      expect(fall.listenedToday, isFalse);
      expect(fall.currentStreak, 4, reason: 'yesterday continues the streak');
      expect(fall.longestStreak, 4);
    });

    test('a gap breaks the current streak but not the longest', () {
      final s = computeListeningStreak([
        DateTime(2026, 6, 1), DateTime(2026, 6, 2), DateTime(2026, 6, 3),
        DateTime(2026, 6, 10),
      ], DateTime(2026, 6, 12));
      expect(s.currentStreak, 0);
      expect(s.longestStreak, 3);
    });

    test('startOfWeek is local Monday midnight even in a DST week', () {
      final w = startOfWeek(DateTime(2026, 3, 11, 8)); // Wednesday
      expect([w.month, w.day, w.hour, w.weekday], [3, 9, 0, DateTime.monday]);
      final f = startOfWeek(DateTime(2026, 11, 1, 12)); // Sunday, fall back
      expect([f.month, f.day, f.hour], [10, 26, 0]);
    });

    test('daily counts bucket plays by calendar day across DST', () {
      final counts = dailyPlayCounts([
        DateTime(2026, 3, 8, 0, 15),
        DateTime(2026, 3, 8, 23, 45),
        DateTime(2026, 3, 9, 0, 5),
      ], DateTime(2026, 3, 9, 10), 3);
      expect(counts, [0, 2, 1]);
    });
  });

  group('account scoping and sync eligibility', () {
    final service = ListeningAnalyticsService();
    final now = DateTime.now();

    setUp(() {
      service.setCurrentAccount();
      service.debugSetEvents([
        _event('mine', now.subtract(const Duration(hours: 1))),
        _event('other-user', now.subtract(const Duration(hours: 2)), user: 'u2'),
        // Same Jellyfin user reached through another address: same account.
        _event('moved-server', now.subtract(const Duration(hours: 3)),
            server: 'https://b.example'),
        // No user id recorded: fall back to the server address.
        _event('server-only', now.subtract(const Duration(minutes: 150)),
            user: null),
        _event('server-only-other', now.subtract(const Duration(minutes: 170)),
            user: null, server: 'https://c.example'),
        _event('legacy', now.subtract(const Duration(hours: 4)),
            user: null, server: null),
        _event('reported', now.subtract(const Duration(hours: 5)), synced: true),
        _event('catchup', now.subtract(const Duration(hours: 6)), catchUp: true),
        _event('network-egg', now.subtract(const Duration(hours: 7))),
      ]);
    });

    test('only this account\'s unreported real plays are pushed', () {
      final push = service.pushableEvents(
        serverUrl: 'https://a.example/jf/', // trailing slash normalized
        userId: 'u1',
      );
      expect(push.map((e) => e.trackId), ['mine', 'server-only', 'moved-server']);
    });

    test('user id decides when both sides have one; server URL otherwise', () {
      final e = _event('x', now, server: 'https://b.example');
      expect(e.belongsTo(serverUrl: 'https://a.example/jf', userId: 'u1'), isTrue);
      expect(e.belongsTo(serverUrl: 'https://b.example', userId: 'u2'), isFalse);
      final noUser = _event('y', now, user: null);
      expect(noUser.belongsTo(serverUrl: 'https://a.example/jf/', userId: 'u1'),
          isTrue);
      expect(noUser.belongsTo(serverUrl: 'https://c.example', userId: 'u1'),
          isFalse);
      expect(_event('z', now, user: null, server: null).isUntagged, isTrue);
      expect(_event('w', now, server: null).isUntagged, isFalse);
    });

    test('getters hide other accounts but keep untagged legacy events', () {
      service.setCurrentAccount(serverUrl: 'https://a.example/jf', userId: 'u1');
      final ids = service.getRecentEvents(limit: 100).map((e) => e.trackId);
      expect(
          ids,
          containsAll(
              ['mine', 'moved-server', 'server-only', 'legacy', 'reported', 'catchup']));
      expect(ids, isNot(contains('other-user')));
      expect(ids, isNot(contains('server-only-other')));
      service.setCurrentAccount();
    });

    test('synthetic catch-up plays are excluded from time-based stats', () {
      service.setCurrentAccount(serverUrl: 'https://a.example/jf', userId: 'u1');
      final hourTotal =
          service.getPlaysByHourOfDay().values.fold<int>(0, (a, b) => a + b);
      // mine, moved-server, server-only, legacy, reported, network-egg
      // (catchup excluded)
      expect(hourTotal, 6);
      service.setCurrentAccount();
    });

    test('recordPlay stores reported plays as synced (no double count)',
        () async {
      service.debugSetEvents(const []);
      final track = JellyfinTrack(
        id: 't',
        name: 'T',
        album: null,
        artists: const ['A'],
        serverUrl: 'https://a.example/jf',
        userId: 'u1',
      );
      await service.recordPlay(track, actualDurationMs: 30000);
      await service.recordPlay(track,
          actualDurationMs: 30000,
          playStartTime: now.subtract(const Duration(minutes: 5)),
          reportedToServer: false);
      final push = service.pushableEvents(
          serverUrl: 'https://a.example/jf', userId: 'u1');
      expect(push, hasLength(1));
      expect(push.single.userId, 'u1');
    });
  });

  test('PlayEvent account fields round-trip and default for legacy JSON', () {
    final e = _event('x', DateTime.utc(2026, 1, 1), catchUp: true);
    final back = PlayEvent.fromJson(e.toJson());
    expect(back.userId, 'u1');
    expect(back.serverUrl, 'https://a.example/jf');
    expect(back.isCatchUp, isTrue);
    final legacy = PlayEvent.fromJson({
      'trackId': 't',
      'trackName': 'n',
      'timestamp': '2026-01-01T00:00:00.000Z',
    });
    expect(legacy.isUntagged, isTrue);
    expect(legacy.isCatchUp, isFalse);
  });

  group('skips, period comparisons and import', () {
    final service = ListeningAnalyticsService();
    tearDown(() {
      service.setCurrentAccount();
      service.debugSetEvents(const []);
    });

    test('a track left before the play threshold is a skip, not a play',
        () async {
      service.debugSetEvents(const []);
      final track = JellyfinTrack(
        id: 't',
        name: 'T',
        album: null,
        artists: const ['A'],
        runTimeTicks: const Duration(minutes: 4).inMicroseconds * 10,
        serverUrl: 'https://a.example/jf',
        userId: 'u1',
      );
      await service.recordPlay(track,
          actualDurationMs: 30000, reportedToServer: false); // < 2 min
      await service.recordPlay(track,
          actualDurationMs: 150000,
          playStartTime: DateTime.now().subtract(const Duration(minutes: 10)),
          reportedToServer: false);
      final all = service.getRecentEvents(limit: 10);
      expect(all, hasLength(1)); // only the play
      expect(service.getTotalPlays(), 1);
      // Both count as listening time.
      expect(service.getTotalListeningTime(), const Duration(seconds: 180));
      // A skip is never pushed to the server as a play.
      expect(
          service.pushableEvents(serverUrl: 'https://a.example/jf', userId: 'u1'),
          hasLength(1));
      // The caller's verdict wins over the duration heuristic.
      await service.recordPlay(track,
          actualDurationMs: 200000,
          playStartTime: DateTime.now().subtract(const Duration(minutes: 20)),
          countsAsPlay: false);
      expect(service.getTotalPlays(), 1);
    });

    test('skip flag round-trips through JSON', () {
      final e = PlayEvent(
        trackId: 't',
        trackName: 't',
        artists: const [],
        genres: const [],
        timestamp: DateTime.utc(2026),
        durationMs: 1000,
        isSkip: true,
      );
      expect(PlayEvent.fromJson(e.toJson()).isSkip, isTrue);
      expect(e.toJson().containsKey('isSkip'), isTrue);
    });

    test('comparisons use the same elapsed span of the previous period', () {
      final now = DateTime(2026, 9, 29, 15); // Tuesday afternoon
      service.debugSetEvents([
        _event('this-week', DateTime(2026, 9, 28, 10)),
        _event('last-week-same-span', DateTime(2026, 9, 21, 10)),
        _event('last-week-later', DateTime(2026, 9, 25, 10)),
        _event('last-year-same-span', DateTime(2025, 3, 1)),
        _event('last-year-later', DateTime(2025, 11, 1)),
      ]);
      final week = service.getWeekOverWeekComparison(now: now);
      expect(week.currentPeriodPlays, 1);
      expect(week.previousPeriodPlays, 1);
      final year = service.getYearOverYearComparison(now: now);
      expect(year.currentPeriodPlays, 3);
      expect(year.previousPeriodPlays, 1); // Mar 1, not Nov 1
    });

    test('shiftCalendar clamps the day and keeps the time', () {
      expect(shiftCalendar(DateTime(2026, 3, 31, 8), months: -1),
          DateTime(2026, 2, 28, 8));
      expect(shiftCalendar(DateTime(2028, 2, 29, 8), months: -12),
          DateTime(2027, 2, 28, 8));
      expect(shiftCalendar(DateTime(2026, 9, 29, 15), days: -7),
          DateTime(2026, 9, 22, 15));
    });

    test('importing a backup keeps waves and loon usage', () async {
      service.debugSetEvents(const []);
      await service.recordRelaxModeSession(
        sessionDuration: const Duration(minutes: 5),
        rainUsage: Duration.zero,
        thunderUsage: Duration.zero,
        campfireUsage: Duration.zero,
        waveUsage: const Duration(minutes: 3),
        loonUsage: const Duration(minutes: 2),
      );
      final before = service.getRelaxModeStats();
      await service.importAllStatsFromJson(
          '{"nautune_stats_backup": true, "relax_mode_stats": {"rainUsageMs": 1}}');
      final after = service.getRelaxModeStats();
      expect(after.waveUsageMs, before.waveUsageMs);
      expect(after.loonUsageMs, before.loonUsageMs);
      expect(after.rainUsageMs, greaterThanOrEqualTo(1));
    });
  });
}
