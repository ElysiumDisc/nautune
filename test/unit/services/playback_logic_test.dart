import 'dart:math';

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

  group('queue index bookkeeping', () {
    // Simulate the queue operation on a list and check the current item
    // stays current.
    int trackRemoval(List<String> q, int current, int remove) {
      final expected = remove == current
          ? null
          : q[current];
      final after = List.of(q)..removeAt(remove);
      final idx = currentIndexAfterRemoval(
        currentIndex: current,
        removedIndex: remove,
        lengthBefore: q.length,
      );
      if (expected != null) expect(after[idx], expected);
      return idx;
    }

    test('removing before/after current keeps the current track', () {
      final q = ['A', 'B', 'C', 'D'];
      expect(trackRemoval(q, 2, 0), 1);
      expect(trackRemoval(q, 2, 3), 2);
    });

    test('removing the current track makes the next one current', () {
      expect(trackRemoval(['A', 'B', 'C'], 1, 1), 1); // C slid into slot 1
    });

    test('removing the current last track falls back to the new last', () {
      expect(trackRemoval(['A', 'B', 'C'], 2, 2), 1);
    });

    test('removing the only track yields 0', () {
      expect(
        currentIndexAfterRemoval(currentIndex: 0, removedIndex: 0, lengthBefore: 1),
        0,
      );
    });

    test('moves keep the current track (exhaustive, with duplicates)', () {
      final q = ['A', 'B', 'A', 'C', 'D'];
      for (var current = 0; current < q.length; current++) {
        for (var from = 0; from < q.length; from++) {
          for (var to = 0; to < q.length; to++) {
            // Tag slots so duplicates are distinguishable.
            final tagged = [for (var i = 0; i < q.length; i++) '${q[i]}$i'];
            final item = tagged.removeAt(from);
            tagged.insert(to, item);
            final idx = currentIndexAfterMove(
              currentIndex: current,
              from: from,
              to: to,
            );
            expect(tagged[idx], '${q[current]}$current',
                reason: 'current=$current from=$from to=$to');
          }
        }
      }
    });

    test('inserts keep the current track', () {
      final q = ['A', 'B', 'C'];
      for (var current = 0; current < q.length; current++) {
        for (var at = 0; at <= q.length; at++) {
          final after = List.of(q)..insert(at, 'X');
          final idx = currentIndexAfterInsert(currentIndex: current, insertIndex: at);
          expect(after[idx], q[current], reason: 'current=$current at=$at');
        }
      }
    });
  });

  group('shuffleKeepingCurrent', () {
    test('current slot first, nothing lost, duplicates kept', () {
      final q = ['A', 'B', 'A', 'C', 'A'];
      final out = shuffleKeepingCurrent(q, 2, Random(1));
      expect(out.first, 'A');
      expect(out.length, q.length);
      expect(out.where((t) => t == 'A').length, 3);
      expect([...out]..sort(), [...q]..sort());
    });

    test('no current index shuffles everything', () {
      final out = shuffleKeepingCurrent(['A', 'B', 'C'], -1, Random(2));
      expect([...out]..sort(), ['A', 'B', 'C']);
    });

    test('empty queue', () {
      expect(shuffleKeepingCurrent(<String>[], 0, Random()), isEmpty);
    });
  });

  group('shouldCacheStreamingCopy', () {
    test('only on Wi-Fi, when wanted, outside power saving', () {
      expect(
        shouldCacheStreamingCopy(
            wanted: true, onWifi: true, lowPowerMode: false, batterySaver: false),
        isTrue,
      );
      expect(
        shouldCacheStreamingCopy(
            wanted: true, onWifi: false, lowPowerMode: false, batterySaver: false),
        isFalse,
        reason: 'cellular: the stream already downloads it once',
      );
      expect(
        shouldCacheStreamingCopy(
            wanted: true, onWifi: true, lowPowerMode: true, batterySaver: false),
        isFalse,
      );
      expect(
        shouldCacheStreamingCopy(
            wanted: true, onWifi: true, lowPowerMode: false, batterySaver: true),
        isFalse,
      );
      expect(
        shouldCacheStreamingCopy(
            wanted: false, onWifi: true, lowPowerMode: false, batterySaver: false),
        isFalse,
      );
    });
  });

  group('cacheKeysToEvict', () {
    final t0 = DateTime(2026, 1, 1);
    CacheEntryInfo e(String key, int bytes, int minutes) => CacheEntryInfo(
          key: key,
          bytes: bytes,
          lastUsed: t0.add(Duration(minutes: minutes)),
        );

    test('nothing to do under budget', () {
      expect(cacheKeysToEvict([e('a', 10, 0), e('b', 10, 1)], maxBytes: 20), isEmpty);
    });

    test('evicts least recently used first until under budget', () {
      final entries = [e('new', 40, 30), e('old', 40, 0), e('mid', 40, 10)];
      expect(cacheKeysToEvict(entries, maxBytes: 80), ['old']);
      expect(cacheKeysToEvict(entries, maxBytes: 40), ['old', 'mid']);
    });

    test('never evicts protected keys', () {
      final entries = [e('playing', 50, 0), e('b', 50, 5)];
      expect(
        cacheKeysToEvict(entries, maxBytes: 50, protectedKeys: {'playing'}),
        ['b'],
      );
    });
  });

  group('PlaybackStallDetector', () {
    final t0 = DateTime(2026, 1, 1);

    test('advancing position is never a stall', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      for (var i = 0; i < 200; i++) {
        expect(
          d.onTick(Duration(milliseconds: i * 200), t0.add(Duration(milliseconds: i * 200))),
          isFalse,
        );
      }
    });

    test('frozen position is reported after the threshold', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const pos = Duration(seconds: 42);
      expect(d.onTick(pos, t0), isFalse);
      expect(d.onTick(pos, t0.add(const Duration(seconds: 11))), isFalse);
      expect(d.onTick(pos, t0.add(const Duration(seconds: 12))), isTrue);
    });

    test('reset forgets the frozen period (e.g. after a pause)', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const pos = Duration(seconds: 42);
      d.onTick(pos, t0);
      d.reset();
      // Resuming minutes later at the same position isn't a stall.
      expect(d.onTick(pos, t0.add(const Duration(minutes: 5))), isFalse);
    });

    test('a backward jump (seek / A-B loop) counts as progress', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      d.onTick(const Duration(seconds: 60), t0);
      expect(
        d.onTick(const Duration(seconds: 10), t0.add(const Duration(seconds: 13))),
        isFalse,
      );
    });
  });
}
