import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/chart_data.dart';

ChartNote _note(int ms, int lane, {bool bonus = false}) => ChartNote(
      timestampMs: ms,
      lane: lane,
      isBonus: bonus,
      bonusType: bonus ? BonusType.doublePoints : null,
    );

void main() {
  group('ChartJudge.findHittable picks the closest note', () {
    test('a tap on a note is not taken by an older one still in its late window', () {
      // Notes 120ms apart in the same lane, window 143ms: a tap right on the
      // second note hits the second note.
      final judge = ChartJudge([_note(1000, 2), _note(1120, 2)]);
      expect(judge.findHittable(2, 1120, 143), 1);
      // A tap nearer the first note still hits the first.
      expect(judge.findHittable(2, 1040, 143), 0);
    });

    test('a nearby bonus note does not take a tap meant for a regular note', () {
      final judge = ChartJudge([_note(920, 1, bonus: true), _note(1000, 1)]);
      expect(judge.findHittable(1, 995, 143), 1);
    });

    test('on an exact tie a regular note beats a bonus note', () {
      final bonusFirst = ChartJudge([_note(1000, 3, bonus: true), _note(1000, 3)]);
      expect(bonusFirst.findHittable(3, 1000, 100), 1);
      final regularFirst = ChartJudge([_note(1000, 3), _note(1000, 3, bonus: true)]);
      expect(regularFirst.findHittable(3, 1000, 100), 0);
      // Equidistant early and late regular notes: the earlier one wins.
      final tie = ChartJudge([_note(900, 0), _note(1100, 0)]);
      expect(tie.findHittable(0, 1000, 150), 0);
    });

    test('judged notes and other lanes are skipped', () {
      final judge = ChartJudge([_note(1000, 2), _note(1010, 4), _note(1030, 2)]);
      judge.markJudged(0);
      expect(judge.findHittable(2, 1000, 100), 2);
      expect(judge.findHittable(4, 1000, 100), 1);
      expect(judge.findHittable(3, 1000, 100), -1);
    });
  });

  group('ChartJudge.visible', () {
    test('keeps a note drawn for the whole late window', () {
      final judge = ChartJudge([_note(1000, 0), _note(2500, 1), _note(4000, 2)]);
      // 200ms late with a 245ms window: still visible (and still hittable).
      expect(judge.visible(1200, 2000, 245), [0, 1]);
      expect(judge.findHittable(0, 1200, 245), 0);
      // Past the late window it is gone.
      expect(judge.visible(1300, 2000, 245), [1]);
    });

    test('hides judged notes and notes beyond the lead time', () {
      final judge = ChartJudge([_note(1000, 0), _note(1100, 1), _note(5000, 2)]);
      judge.markJudged(1);
      expect(judge.visible(1000, 2000, 100), [0]);
    });
  });
}
