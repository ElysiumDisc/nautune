import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/playback_logic.dart';

void main() {
  String id(String s) => s;

  group('resolveQueueIndex', () {
    final queue = ['A', 'B', 'A', 'C'];

    test('honours a valid requested index even with duplicates', () {
      expect(resolveQueueIndex(queue, 'A', id, requestedIndex: 2), 2);
      expect(resolveQueueIndex(queue, 'A', id, requestedIndex: 0), 0);
    });

    test('skipping from B to the duplicate A does not loop back to 0', () {
      // Simulates skipToNext from index 1: target index 2 is passed through.
      expect(resolveQueueIndex(queue, 'A', id, requestedIndex: 1 + 1), 2);
    });

    test('ignores a requested index that points at a different track', () {
      expect(resolveQueueIndex(queue, 'C', id, requestedIndex: 1), 3);
    });

    test('ignores an out-of-range requested index', () {
      expect(resolveQueueIndex(queue, 'B', id, requestedIndex: 99), 1);
      expect(resolveQueueIndex(queue, 'B', id, requestedIndex: -1), 1);
    });

    test('without hints returns the first match', () {
      expect(resolveQueueIndex(queue, 'A', id), 0);
    });

    test('with nearIndex prefers the closest match', () {
      expect(resolveQueueIndex(queue, 'A', id, nearIndex: 3), 2);
      expect(resolveQueueIndex(queue, 'A', id, nearIndex: 0), 0);
    });

    test('with nearIndex ties go forward', () {
      // index 1 is equidistant from 0 and 2
      expect(resolveQueueIndex(queue, 'A', id, nearIndex: 1), 2);
    });

    test('returns -1 when the track is absent', () {
      expect(resolveQueueIndex(queue, 'Z', id), -1);
      expect(resolveQueueIndex(queue, 'Z', id, nearIndex: 1), -1);
      expect(resolveQueueIndex(<String>[], 'A', id, requestedIndex: 0), -1);
    });
  });

  group('sleepTimerFadeVolume', () {
    test('no fade outside the window', () {
      expect(
        sleepTimerFadeVolume(userVolume: 0.5, remaining: const Duration(seconds: 31)),
        isNull,
      );
      expect(
        sleepTimerFadeVolume(userVolume: 0.5, remaining: const Duration(minutes: 10)),
        isNull,
      );
    });

    test('no fade at or below zero remaining', () {
      expect(sleepTimerFadeVolume(userVolume: 0.5, remaining: Duration.zero), isNull);
    });

    test('fades proportionally from the current user volume', () {
      expect(
        sleepTimerFadeVolume(userVolume: 0.5, remaining: const Duration(seconds: 30)),
        closeTo(0.5, 1e-9),
      );
      expect(
        sleepTimerFadeVolume(userVolume: 0.5, remaining: const Duration(seconds: 15)),
        closeTo(0.25, 1e-9),
      );
    });

    test('never exceeds the user volume (no blast to 100%)', () {
      for (var s = 1; s <= 30; s++) {
        final v = sleepTimerFadeVolume(
          userVolume: 0.3,
          remaining: Duration(seconds: s),
        )!;
        expect(v, lessThanOrEqualTo(0.3));
      }
    });
  });

  group('scrobbleThresholdSeconds', () {
    test('half the track for short tracks', () {
      expect(scrobbleThresholdSeconds(const Duration(minutes: 3)), 90);
    });

    test('caps at four minutes', () {
      expect(scrobbleThresholdSeconds(const Duration(minutes: 20)), 240);
    });
  });
}
