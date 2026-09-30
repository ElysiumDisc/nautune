import 'dart:math' show Random, sin, pi;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/chart_data.dart';
import 'package:nautune/services/chart_generator_service.dart';

void main() {
  group('estimateGridPhaseMs', () {
    test('finds the offset of onsets that sit off a zero-based grid', () {
      // 125ms grid (120 BPM 16ths), onsets all 40ms after grid lines
      final onsets = [for (int k = 0; k < 40; k++) 40 + k * 125];
      expect(estimateGridPhaseMs(onsets, 125), 40);
    });

    test('tolerates jitter', () {
      final onsets = [
        for (int k = 0; k < 40; k++) 70 + k * 125 + (k.isEven ? 3 : -3),
      ];
      final phase = estimateGridPhaseMs(onsets, 125);
      expect((phase - 70).abs(), lessThanOrEqualTo(3));
    });

    test('returns 0 for empty input or degenerate grid', () {
      expect(estimateGridPhaseMs([], 125), 0);
      expect(estimateGridPhaseMs([10, 20], 0), 0);
    });
  });

  group('quantizeToGrid', () {
    test('snaps to the nearest phase-aligned grid line', () {
      expect(quantizeToGrid(1043, 125, 40), 1040);
      expect(quantizeToGrid(1100, 125, 40), 1040);
      expect(quantizeToGrid(1110, 125, 40), 1165);
    });

    test('leaves notes alone when the grid line is too far away', () {
      expect(quantizeToGrid(1100, 125, 40, maxSnapMs: 31), 1100);
      expect(quantizeToGrid(1060, 125, 40, maxSnapMs: 31), 1040);
    });

    test('never returns negative times', () {
      expect(quantizeToGrid(5, 125, 100), greaterThanOrEqualTo(0));
    });
  });

  group('thinNotesEvenly', () {
    List<ChartNote> singles(int count, {int gapMs = 200}) => [
          for (int i = 0; i < count; i++) ChartNote(timestampMs: i * gapMs, lane: i % 5),
        ];

    test('returns the input unchanged when under the cap', () {
      final notes = singles(10);
      expect(identical(thinNotesEvenly(notes, 10), notes), isTrue);
    });

    test('drops chord partners before whole onsets', () {
      final notes = <ChartNote>[
        for (int i = 0; i < 10; i++) ...[
          ChartNote(timestampMs: i * 200, lane: 0),
          ChartNote(timestampMs: i * 200, lane: 3),
        ],
      ];
      final thinned = thinNotesEvenly(notes, 15);
      expect(thinned.length, 15);
      // Every onset survives.
      expect(thinned.map((n) => n.timestampMs).toSet().length, 10);
    });

    test('keeps notes spread over the whole song instead of truncating', () {
      final notes = singles(9000);
      final thinned = thinNotesEvenly(notes, 3000);
      expect(thinned.length, 3000);
      expect(thinned.last.timestampMs, greaterThan(notes.last.timestampMs * 0.99));
      // Still sorted by time
      for (int i = 1; i < thinned.length; i++) {
        expect(thinned[i].timestampMs, greaterThan(thinned[i - 1].timestampMs));
      }
    });
  });

  group('analyzeSamplesForTesting', () {
    const rate = 44100;

    Float32List clickTrack({required int seconds, required int firstClickMs, required int intervalMs}) {
      final samples = Float32List(rate * seconds);
      final noise = Random(1);
      // Quiet noise floor so the spectrum is never exactly silent
      for (int i = 0; i < samples.length; i++) {
        samples[i] = (noise.nextDouble() - 0.5) * 0.001;
      }
      for (int t = firstClickMs; t < seconds * 1000; t += intervalMs) {
        final start = t * rate ~/ 1000;
        for (int i = 0; i < 2000 && start + i < samples.length; i++) {
          final env = 1.0 - i / 2000;
          samples[start + i] += 0.8 * env * sin(2 * pi * 220 * i / rate);
        }
      }
      return samples;
    }

    test('silence produces no notes', () {
      final result = analyzeSamplesForTesting(Float32List(rate * 5));
      expect(result.notes, isEmpty);
    });

    test('too-short audio produces no notes', () {
      final result = analyzeSamplesForTesting(Float32List(3000));
      expect(result.notes, isEmpty);
    });

    test('click track notes land on the clicks, not early', () {
      const first = 370; // deliberately off a zero-based grid
      const interval = 500; // 120 BPM
      final result = analyzeSamplesForTesting(
        clickTrack(seconds: 20, firstClickMs: first, intervalMs: interval),
      );
      // Ignore the start-up transient of the noise floor in the first frames
      final notes = result.notes.where((n) => !n.isBonus && n.timestampMs > 200).toList();
      expect(notes.length, greaterThanOrEqualTo(35));
      for (final note in notes) {
        final offset = (note.timestampMs - first) % interval;
        final error = offset < interval - offset ? offset : interval - offset;
        expect(error, lessThanOrEqualTo(20), reason: 'note at ${note.timestampMs}ms');
      }
      // Sorted by time
      for (int i = 1; i < notes.length; i++) {
        expect(notes[i].timestampMs, greaterThanOrEqualTo(notes[i - 1].timestampMs));
      }
    });
  });
}
