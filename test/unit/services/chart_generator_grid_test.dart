import 'dart:math' show Random;

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/chart_data.dart';
import 'package:nautune/services/chart_generator_service.dart';

void main() {
  group('pickBonusLane', () {
    test('never picks a lane with a regular note within the clearance', () {
      // Lanes 0, 1 and 3 are busy around 10s; only 2 and 4 are clear.
      final notes = [
        const ChartNote(timestampMs: 9800, lane: 0),
        const ChartNote(timestampMs: 9950, lane: 1),
        const ChartNote(timestampMs: 10100, lane: 3),
        const ChartNote(timestampMs: 10900, lane: 2), // outside 300ms
      ];
      final random = Random(7);
      for (int i = 0; i < 50; i++) {
        final lane = pickBonusLane(notes, 10000, random);
        expect(lane, anyOf(2, 4));
      }
    });

    test('ignores other bonus notes', () {
      final notes = [
        for (int l = 0; l < 5; l++)
          ChartNote(timestampMs: 10000, lane: l, isBonus: l != 2, bonusType: l != 2 ? BonusType.shield : null),
      ];
      final random = Random(1);
      for (int i = 0; i < 20; i++) {
        expect(pickBonusLane(notes, 10000, random), isNot(2));
      }
    });

    test('falls back to the lane with the most room when every lane is busy', () {
      final notes = [
        const ChartNote(timestampMs: 9990, lane: 0),
        const ChartNote(timestampMs: 10010, lane: 1),
        const ChartNote(timestampMs: 10020, lane: 2),
        const ChartNote(timestampMs: 10250, lane: 3), // furthest away
        const ChartNote(timestampMs: 10030, lane: 4),
      ];
      expect(pickBonusLane(notes, 10000, Random(3)), 3);
    });
  });

  group('snapToLocalGrid', () {
    test('snaps jittered onsets on a drifting tempo back onto the beat', () {
      // True 16th grid of 105.37ms (142.3 BPM), onsets jittered by up to 5ms
      // as the 10ms analysis hop does. The estimated period is slightly off
      // (105.0ms), which a single global grid would accumulate over 60s.
      const trueGrid = 105.37;
      final random = Random(42);
      final truth = <int>[];
      final onsets = <int>[];
      for (int k = 3; k < 570; k += 2) {
        final t = (37 + k * trueGrid).round();
        truth.add(t);
        onsets.add(t + random.nextInt(11) - 5);
      }
      final snapped = snapToLocalGrid(onsets, 105.0, maxSnapMs: 12);

      double meanError(List<int> times) {
        var sum = 0;
        for (int i = 0; i < times.length; i++) {
          sum += (times[i] - truth[i]).abs();
        }
        return sum / times.length;
      }

      expect(meanError(snapped), lessThan(meanError(onsets)));
      for (int i = 0; i < snapped.length; i++) {
        // Never moved by more than the cap, never far from the true beat.
        expect((snapped[i] - onsets[i]).abs(), lessThanOrEqualTo(12));
        expect((snapped[i] - truth[i]).abs(), lessThanOrEqualTo(10), reason: 'onset $i');
      }
    });

    test('leaves onsets alone where they do not follow the grid', () {
      final random = Random(5);
      final onsets = <int>[];
      var t = 0;
      for (int i = 0; i < 200; i++) {
        t += 120 + random.nextInt(400);
        onsets.add(t);
      }
      final snapped = snapToLocalGrid(onsets, 107.0);
      var moved = 0;
      for (int i = 0; i < onsets.length; i++) {
        if (snapped[i] != onsets[i]) moved++;
        expect((snapped[i] - onsets[i]).abs(), lessThanOrEqualTo(12));
      }
      // Random onsets fit no grid: nothing (or almost nothing) moves.
      expect(moved, lessThan(onsets.length ~/ 10));
    });

    test('handles empty input, sparse segments and a degenerate grid', () {
      expect(snapToLocalGrid([], 100.0), isEmpty);
      expect(snapToLocalGrid([103, 5000], 100.0), [103, 5000]);
      expect(snapToLocalGrid([10, 20, 30, 40], 0.5), [10, 20, 30, 40]);
    });
  });
}
