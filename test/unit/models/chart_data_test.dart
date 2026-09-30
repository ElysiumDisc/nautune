import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/chart_data.dart';
import 'package:nautune/services/chart_cache_service.dart';

ChartNote _note(int ms, int lane, {bool bonus = false}) => ChartNote(
      timestampMs: ms,
      lane: lane,
      isBonus: bonus,
      bonusType: bonus ? BonusType.shield : null,
    );

ChartData _chart(List<ChartNote> notes) => ChartData(
      id: 't_chart',
      trackId: 't',
      trackName: 'Track',
      artistName: 'Artist',
      notes: notes,
      bpm: 120,
      durationMs: 60000,
      generatedAt: DateTime(2026),
    );

void main() {
  group('ChartJudge', () {
    test('both notes of a chord can be hit in either order', () {
      final judge = ChartJudge([_note(1000, 1), _note(1000, 3)]);

      final second = judge.findHittable(3, 1000, 100);
      expect(second, 1);
      judge.markJudged(second);
      // The lane-1 partner is still hittable after the lane-3 tap.
      final first = judge.findHittable(1, 1000, 100);
      expect(first, 0);
      judge.markJudged(first);

      expect(judge.cursor, 2);
      expect(judge.remainingScorable, 0);
    });

    test('a judged note is never found again (no double counting)', () {
      final judge = ChartJudge([_note(900, 0), _note(1000, 4)]);
      final i = judge.findHittable(4, 1000, 50, includeBonus: false);
      judge.markJudged(i);
      expect(judge.findHittable(4, 1000, 50, includeBonus: false), -1);
      // The earlier lane-0 note still blocks the cursor until judged.
      expect(judge.cursor, 0);
      expect(judge.expire(1200, 100), [0]);
      expect(judge.cursor, 2);
    });

    test('expire returns only unjudged notes past the late window', () {
      final judge = ChartJudge([_note(100, 0), _note(200, 1), _note(900, 2)]);
      judge.markJudged(1);
      expect(judge.expire(400, 150), [0]);
      expect(judge.expire(400, 150), isEmpty);
      expect(judge.cursor, 2);
    });

    test('findHittable respects the window and includeBonus', () {
      final judge = ChartJudge([_note(1000, 2, bonus: true), _note(1300, 2)]);
      expect(judge.findHittable(2, 1000, 100, includeBonus: false), -1);
      expect(judge.findHittable(2, 1000, 100), 0);
      expect(judge.findHittable(2, 1150, 100), -1);
      expect(judge.findHittable(2, 1250, 100), 1);
    });

    test('remainingScorable ignores bonus notes', () {
      final judge = ChartJudge([_note(100, 0), _note(200, 1, bonus: true), _note(300, 2)]);
      expect(judge.remainingScorable, 2);
    });
  });

  group('ChartData', () {
    test('scorableNoteCount excludes golden bonus notes', () {
      final chart = _chart([_note(100, 0), _note(200, 1, bonus: true), _note(300, 2)]);
      expect(chart.scorableNoteCount, 2);
    });

    test('JSON round-trip keeps version and hit stats', () {
      final chart = _chart([_note(100, 0)]).copyWithScore(totalNotesHit: 42, playCount: 3);
      final restored = ChartData.fromJson(chart.toJson());
      expect(restored.version, ChartData.currentVersion);
      expect(restored.isCurrentVersion, isTrue);
      expect(restored.totalNotesHit, 42);
      expect(restored.playCount, 3);
    });

    test('charts cached before versioning are treated as stale', () {
      final json = _chart([_note(100, 0)]).toJson()..remove('v');
      final restored = ChartData.fromJson(json);
      expect(restored.version, 1);
      expect(restored.isCurrentVersion, isFalse);
    });
  });

  group('isPerfectScore', () {
    final cache = ChartCacheService.instance;

    test('perfect when every scorable note is hit, even with bonus notes in the chart', () {
      final chart = _chart([_note(100, 0), _note(200, 1, bonus: true), _note(300, 2)]);
      expect(cache.isPerfectScore(1, 1, 0, chart.scorableNoteCount), isTrue);
    });

    test('not perfect with a miss, a skipped note, or an empty chart', () {
      expect(cache.isPerfectScore(2, 0, 1, 3), isFalse);
      expect(cache.isPerfectScore(1, 0, 0, 2), isFalse);
      expect(cache.isPerfectScore(0, 0, 0, 0), isFalse);
    });
  });
}
