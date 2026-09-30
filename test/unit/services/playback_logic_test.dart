import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/replay_gain_mode.dart';
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

    test('is at least one second for very short tracks', () {
      expect(scrobbleThresholdSeconds(const Duration(seconds: 1)), 1);
      expect(scrobbleThresholdSeconds(Duration.zero), 1);
    });
  });

  group('isLastFmScrobbleLength', () {
    test('requires more than 30 seconds', () {
      expect(isLastFmScrobbleLength(const Duration(seconds: 30)), isFalse);
      expect(isLastFmScrobbleLength(const Duration(seconds: 31)), isTrue);
    });

    test('allows an unknown length', () {
      expect(isLastFmScrobbleLength(null), isTrue);
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

    test('removing the current last track wraps to the first with wrap', () {
      expect(
        currentIndexAfterRemoval(
          currentIndex: 2,
          removedIndex: 2,
          lengthBefore: 3,
          wrap: true,
        ),
        0,
      );
      // Only the last slot wraps; a middle one still takes the next track.
      expect(
        currentIndexAfterRemoval(
          currentIndex: 1,
          removedIndex: 1,
          lengthBefore: 3,
          wrap: true,
        ),
        1,
      );
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

  group('resolvePreviousAction', () {
    PreviousAction resolve({
      required int seconds,
      required int index,
      int length = 5,
      bool repeatAll = false,
    }) =>
        resolvePreviousAction(
          position: Duration(seconds: seconds),
          currentIndex: index,
          queueLength: length,
          repeatAll: repeatAll,
        );

    test('more than 3 s in restarts the current track', () {
      expect(resolve(seconds: 4, index: 2), PreviousAction.restartCurrent);
      expect(resolve(seconds: 4, index: 0), PreviousAction.restartCurrent);
      expect(resolve(seconds: 4, index: 0, repeatAll: true),
          PreviousAction.restartCurrent);
    });

    test('within the first 3 s goes to the previous track', () {
      expect(resolve(seconds: 0, index: 2), PreviousAction.previousTrack);
      expect(resolve(seconds: 3, index: 2), PreviousAction.previousTrack,
          reason: 'exactly 3 s is still "at the start"');
      expect(
        resolvePreviousAction(
          position: const Duration(milliseconds: 3001),
          currentIndex: 2,
          queueLength: 5,
          repeatAll: false,
        ),
        PreviousAction.restartCurrent,
      );
    });

    test('at the start of the queue', () {
      expect(resolve(seconds: 1, index: 0, repeatAll: true),
          PreviousAction.wrapToLast);
      expect(resolve(seconds: 1, index: 0), PreviousAction.restartCurrent);
      expect(resolve(seconds: 1, index: 0, length: 1, repeatAll: true),
          PreviousAction.wrapToLast);
    });

    test('empty queue does nothing', () {
      expect(resolve(seconds: 10, index: 0, length: 0), PreviousAction.none);
      expect(resolve(seconds: 0, index: 0, length: 0, repeatAll: true),
          PreviousAction.none);
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

  group('nextPlayableIndex', () {
    // Slots 1 and 4 hold downloaded tracks.
    const downloaded = {1, 4};
    bool playable(int i) => downloaded.contains(i);

    int next(int from, {int direction = 1, bool wrap = false, int length = 6}) =>
        nextPlayableIndex(
          length: length,
          from: from,
          direction: direction,
          wrap: wrap,
          isPlayable: playable,
        );

    test('forward finds the next playable slot, skipping the rest', () {
      expect(next(1), 4);
      expect(next(2), 4);
      expect(next(0), 1);
    });

    test('forward past the last playable slot is -1 without repeat', () {
      expect(next(4), -1);
      expect(next(5), -1);
    });

    test('repeat-all wraps forward', () {
      expect(next(4, wrap: true), 1);
      expect(next(5, wrap: true), 1);
    });

    test('backward finds the previous playable slot', () {
      expect(next(3, direction: -1), 1);
      expect(next(5, direction: -1), 4);
      expect(next(1, direction: -1), -1);
      expect(next(0, direction: -1), -1);
    });

    test('repeat-all wraps backward', () {
      expect(next(1, direction: -1, wrap: true), 4);
      expect(next(0, direction: -1, wrap: true), 4);
    });

    test('never returns the starting slot', () {
      // Only slot 1 is playable; starting on it there is nowhere to go.
      expect(
        nextPlayableIndex(
          length: 3,
          from: 1,
          direction: 1,
          wrap: true,
          isPlayable: (i) => i == 1,
        ),
        -1,
      );
    });

    test('none playable returns -1 and checks each slot at most once', () {
      var checks = 0;
      final result = nextPlayableIndex(
        length: 5,
        from: 2,
        direction: 1,
        wrap: true,
        isPlayable: (_) {
          checks++;
          return false;
        },
      );
      expect(result, -1);
      expect(checks, 4);
    });

    test('empty queue or invalid direction returns -1', () {
      expect(
        nextPlayableIndex(
            length: 0, from: 0, direction: 1, wrap: true, isPlayable: (_) => true),
        -1,
      );
      expect(
        nextPlayableIndex(
            length: 3, from: 0, direction: 0, wrap: true, isPlayable: (_) => true),
        -1,
      );
    });
  });

  group('queueStepsBetween', () {
    test('counts the slots passed over, including the start', () {
      expect(queueStepsBetween(length: 6, from: 2, target: 3, direction: 1), 1);
      expect(queueStepsBetween(length: 6, from: 2, target: 5, direction: 1), 3);
    });

    test('handles wrap-around in both directions', () {
      expect(queueStepsBetween(length: 6, from: 5, target: 1, direction: 1), 2);
      expect(queueStepsBetween(length: 6, from: 1, target: 4, direction: -1), 3);
    });

    test('same slot or empty queue is 0', () {
      expect(queueStepsBetween(length: 6, from: 2, target: 2, direction: 1), 0);
      expect(queueStepsBetween(length: 0, from: 0, target: 0, direction: 1), 0);
    });
  });

  group('replayGainMultiplier', () {
    double gain(ReplayGainMode mode,
            {double? track, double? album, double preamp = 0}) =>
        replayGainMultiplier(
          mode: mode,
          trackGainDb: track,
          albumGainDb: album,
          preampDb: preamp,
        );

    test('off ignores gain and preamp', () {
      expect(gain(ReplayGainMode.off, track: -6, preamp: -6), 1.0);
    });

    test('track mode attenuates loud tracks', () {
      expect(gain(ReplayGainMode.track, track: -6), closeTo(0.501, 0.001));
    });

    test('positive gain cannot exceed full scale without preamp', () {
      expect(gain(ReplayGainMode.track, track: 4), 1.0);
    });

    test('negative preamp leaves room to raise quiet tracks', () {
      final quiet = gain(ReplayGainMode.track, track: 4, preamp: -6);
      final loud = gain(ReplayGainMode.track, track: -4, preamp: -6);
      expect(quiet, lessThan(1.0));
      expect(quiet / loud, closeTo(pow(10, 8 / 20), 0.001));
    });

    test('album mode prefers album gain, falls back to track gain', () {
      expect(gain(ReplayGainMode.album, track: -2, album: -6),
          closeTo(0.501, 0.001));
      expect(gain(ReplayGainMode.album, track: -6), closeTo(0.501, 0.001));
    });

    test('missing gain only applies the preamp', () {
      expect(gain(ReplayGainMode.track), 1.0);
      expect(gain(ReplayGainMode.track, preamp: -6), closeTo(0.501, 0.001));
    });
  });

  group('ListenedTimeTracker', () {
    final t0 = DateTime(2026);
    Duration s(int seconds) => Duration(seconds: seconds);

    test('counts normal playback', () {
      final tracker = ListenedTimeTracker();
      for (var i = 0; i <= 10; i++) {
        tracker.onPosition(s(i), t0.add(s(i)));
      }
      expect(tracker.listened, s(10));
    });

    test('ignores a seek forward', () {
      final tracker = ListenedTimeTracker()
        ..onPosition(s(0), t0)
        ..onPosition(s(1), t0.add(s(1)))
        ..onPosition(s(120), t0.add(s(2)))
        ..onPosition(s(121), t0.add(s(3)));
      expect(tracker.listened, s(2));
    });

    test('ignores backward jumps and paused ticks', () {
      final tracker = ListenedTimeTracker()
        ..onPosition(s(10), t0)
        ..onPosition(s(10), t0.add(s(5)))
        ..onPosition(s(2), t0.add(s(6)))
        ..onPosition(s(3), t0.add(s(7)));
      expect(tracker.listened, s(1));
    });

    test('a seek made while paused is not credited', () {
      final tracker = ListenedTimeTracker()
        ..onPosition(s(10), t0)
        ..onPosition(s(190), t0.add(const Duration(minutes: 5)));
      expect(tracker.listened, Duration.zero);
    });

    test('reset clears and can seed', () {
      final tracker = ListenedTimeTracker()
        ..onPosition(s(0), t0)
        ..onPosition(s(1), t0.add(s(1)))
        ..reset(s(30));
      expect(tracker.listened, s(30));
      tracker.onPosition(s(50), t0.add(s(2)));
      expect(tracker.listened, s(30)); // first tick after reset is a baseline
    });
  });

  group('audio cache variants', () {
    const base = 'https://h/Audio/t1/universal?userId=u';

    test('original-quality and uncapped URLs are the original variant', () {
      expect(cacheVariantForUrl(null), kOriginalCacheVariant);
      expect(cacheVariantForUrl('https://h/Items/t1/Download?api_key=k'),
          kOriginalCacheVariant);
      expect(cacheVariantForUrl('$base&maxStreamingBitrate=140000000'),
          kOriginalCacheVariant);
    });

    test('capped URLs carry bitrate and codec', () {
      expect(
        cacheVariantForUrl('$base&maxStreamingBitrate=128000&audioCodec=aac'),
        '128000-aac',
      );
    });

    test('keys round-trip to the track id, including legacy keys', () {
      expect(trackIdFromCacheKey(audioCacheKey('t1', '128000-mp3')), 't1');
      expect(trackIdFromCacheKey('t1'), 't1');
    });

    test('a low-bitrate copy never satisfies an original request', () {
      expect(cacheKeysForRequest('t1', kOriginalCacheVariant), ['t1@orig']);
    });

    test('an original or legacy copy satisfies a lossy request', () {
      expect(cacheKeysForRequest('t1', '128000-mp3'),
          ['t1@128000-mp3', 't1@orig', 't1']);
    });
  });

  group('restoreQueueOrder', () {
    test('round-trips a shuffle and follows the current track', () {
      final original = ['A', 'B', 'C', 'D', 'E'];
      final shuffled = shuffleKeepingCurrent(original, 2, Random(7));
      expect(shuffled.first, 'C');
      final r = restoreQueueOrder(original, shuffled, 0, id);
      expect(r.queue, original);
      expect(r.index, 2);
    });

    test('keeps items added while shuffled, drops removed ones', () {
      final r = restoreQueueOrder(
        ['A', 'B', 'C', 'D'],
        ['C', 'X', 'A', 'D'], // B removed, X added
        1,
        id,
      );
      expect(r.queue, ['A', 'C', 'D', 'X']);
      expect(r.index, 3);
    });

    test('matches duplicates by occurrence', () {
      final r = restoreQueueOrder(['A', 'B', 'A'], ['A', 'A', 'B'], 1, id);
      expect(r.queue, ['A', 'B', 'A']);
      expect(r.index, 2);
    });
  });

  group('sleepTimerLabel', () {
    test('time, tracks, end of track, none', () {
      expect(sleepTimerLabel(Duration.zero), isNull);
      expect(sleepTimerLabel(const Duration(minutes: 12, seconds: 5)), '12:05');
      expect(sleepTimerLabel(const Duration(hours: 1, minutes: 2, seconds: 9)), '1:02:09');
      expect(sleepTimerLabel(const Duration(seconds: -1)), 'End of track');
      expect(sleepTimerLabel(const Duration(seconds: -3)), '3 tracks');
    });
  });

  group('smartShuffle', () {
    final now = DateTime(2026, 9, 27);
    List<String> run(List<String> items,
            {Map<String, DateTime> played = const {}, int seed = 1, int keepFirst = -1}) =>
        smartShuffle<String>(
          items,
          lastPlayedOf: (t) => played[t],
          artistOf: (t) => t.substring(0, 1),
          random: Random(seed),
          now: now,
          keepFirst: keepFirst,
        );

    test('is a permutation and keeps the current track first', () {
      final items = ['a1', 'b1', 'c1', 'd1', 'e1'];
      final r = run(items, keepFirst: 2);
      expect(r.first, 'c1');
      expect(r.toSet(), items.toSet());
      expect(r.length, items.length);
    });

    test('avoids back-to-back artists when possible', () {
      final items = ['a1', 'a2', 'a3', 'b1', 'b2', 'b3', 'c1', 'c2'];
      for (var seed = 0; seed < 20; seed++) {
        final r = run(items, seed: seed);
        for (var i = 1; i < r.length; i++) {
          expect(r[i][0] == r[i - 1][0], isFalse, reason: '$r');
        }
      }
    });

    test('recently played tracks tend to land later', () {
      final items = [for (var i = 0; i < 20; i++) 'x$i'];
      final played = {'x0': now.subtract(const Duration(hours: 1))};
      var positions = 0;
      for (var seed = 0; seed < 200; seed++) {
        positions += run(items, played: played, seed: seed).indexOf('x0');
      }
      expect(positions / 200, greaterThan(12)); // uniform would be ~9.5
    });
  });

  test('audioExtensionForMime maps stream content types', () {
    expect(audioExtensionForMime('audio/flac'), 'flac');
    expect(audioExtensionForMime('audio/mpeg; charset=binary'), 'mp3');
    expect(audioExtensionForMime('audio/mp4'), 'm4a');
    expect(audioExtensionForMime(''), 'mp3');
  });

  group('PlaybackStallDetector (timer-fed, with buffering)', () {
    final t0 = DateTime(2026, 1, 1);

    test('short buffering with a frozen position is not a stall', () {
      final d = PlaybackStallDetector();
      const pos = Duration(seconds: 30);
      for (var s = 0; s <= 10; s++) {
        expect(
          d.onTick(pos, t0.add(Duration(seconds: s)), buffering: true),
          isFalse,
        );
      }
    });

    test('a position frozen past the threshold is a stall when not buffering', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const pos = Duration(seconds: 30);
      var stalled = false;
      for (var s = 0; s <= 12; s++) {
        stalled = d.onTick(pos, t0.add(Duration(seconds: s)));
        if (s < 12) expect(stalled, isFalse, reason: 'at ${s}s');
      }
      expect(stalled, isTrue);
    });

    test('a frozen position while buffering is only judged by the buffering '
        'threshold', () {
      final d = PlaybackStallDetector(
        threshold: const Duration(seconds: 12),
        bufferingThreshold: const Duration(seconds: 30),
      );
      const pos = Duration(seconds: 30);
      for (var s = 0; s < 30; s++) {
        expect(
          d.onTick(pos, t0.add(Duration(seconds: s)), buffering: true),
          isFalse,
          reason: 'at ${s}s',
        );
      }
      expect(d.onTick(pos, t0.add(const Duration(seconds: 30)), buffering: true), isTrue);
    });

    test('the default buffering threshold is generous (30 s)', () {
      final d = PlaybackStallDetector();
      const pos = Duration(seconds: 30);
      for (var s = 0; s < 30; s++) {
        expect(d.onTick(pos, t0.add(Duration(seconds: s)), buffering: true), isFalse);
      }
      expect(d.onTick(pos, t0.add(const Duration(seconds: 30)), buffering: true), isTrue);
    });

    test('buffering without a network is never a stall (AVPlayer resumes '
        'when the connection is back)', () {
      final d = PlaybackStallDetector(bufferingThreshold: const Duration(seconds: 20));
      const pos = Duration(seconds: 30);
      for (var s = 0; s <= 600; s += 5) {
        expect(
          d.onTick(pos, t0.add(Duration(seconds: s)),
              buffering: true, networkAvailable: false),
          isFalse,
          reason: 'at ${s}s',
        );
      }
    });

    test('the buffering clock starts when the network is back', () {
      final d = PlaybackStallDetector(bufferingThreshold: const Duration(seconds: 20));
      const pos = Duration(seconds: 30);
      for (var s = 0; s < 60; s++) {
        d.onTick(pos, t0.add(Duration(seconds: s)), buffering: true, networkAvailable: false);
      }
      // Online again but still buffering: 20 s from now, not from t0.
      expect(d.onTick(pos, t0.add(const Duration(seconds: 60)), buffering: true), isFalse);
      expect(d.onTick(pos, t0.add(const Duration(seconds: 79)), buffering: true), isFalse);
      expect(d.onTick(pos, t0.add(const Duration(seconds: 80)), buffering: true), isTrue);
    });

    test('a position parked at the reported duration while playing is not a '
        'stall (completion ends the track)', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const duration = Duration(minutes: 3);
      for (var s = 0; s <= 120; s++) {
        expect(
          d.onTick(duration, t0.add(Duration(seconds: s)), duration: duration),
          isFalse,
          reason: 'at ${s}s',
        );
      }
    });

    test('a position frozen before the reported duration is still a stall', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const duration = Duration(minutes: 3);
      const pos = Duration(minutes: 2);
      d.onTick(pos, t0, duration: duration);
      expect(
        d.onTick(pos, t0.add(const Duration(seconds: 12)), duration: duration),
        isTrue,
      );
    });

    test('buffering without a break past its threshold is a stall even if '
        'the position creeps', () {
      final d = PlaybackStallDetector(
        threshold: const Duration(seconds: 12),
        bufferingThreshold: const Duration(seconds: 20),
      );
      var stalled = false;
      for (var s = 0; s <= 20; s++) {
        stalled = d.onTick(
          Duration(milliseconds: 30000 + s * 100),
          t0.add(Duration(seconds: s)),
          buffering: true,
        );
        if (s < 20) expect(stalled, isFalse, reason: 'at ${s}s');
      }
      expect(stalled, isTrue);
    });

    test('a break in buffering restarts the buffering clock', () {
      final d = PlaybackStallDetector(bufferingThreshold: const Duration(seconds: 20));
      for (var s = 0; s < 15; s++) {
        d.onTick(Duration(seconds: s), t0.add(Duration(seconds: s)), buffering: true);
      }
      d.onTick(const Duration(seconds: 15), t0.add(const Duration(seconds: 15)));
      expect(
        d.onTick(const Duration(seconds: 16), t0.add(const Duration(seconds: 25)),
            buffering: true),
        isFalse,
      );
    });

    test('reset (pause) clears both clocks', () {
      final d = PlaybackStallDetector(threshold: const Duration(seconds: 12));
      const pos = Duration(seconds: 5);
      d.onTick(pos, t0, buffering: true);
      d.reset();
      expect(d.onTick(pos, t0.add(const Duration(seconds: 30)), buffering: true), isFalse);
    });
  });

  group('LatestValueRelay', () {
    test('listen, cancel, listen again: replays the latest value, then updates',
        () async {
      final source = StreamController<int>.broadcast(sync: true);
      final relay = LatestValueRelay<int>(source.stream);
      final stream = relay.stream; // cached like a widget would

      final first = <int>[];
      final sub1 = stream.listen(first.add);
      source.add(1);
      source.add(2);
      await pumpEventQueue();
      expect(first, [1, 2]);
      await sub1.cancel();

      source.add(3); // nobody listening
      await pumpEventQueue();

      final second = <int>[];
      final sub2 = stream.listen(second.add);
      await pumpEventQueue();
      expect(second, [3], reason: 'a new listener gets the latest value at once');
      source.add(4);
      await pumpEventQueue();
      expect(second, [3, 4]);
      await sub2.cancel();

      await relay.close();
      await source.close();
    });

    test('several listeners at once', () async {
      final source = StreamController<int>.broadcast(sync: true);
      final relay = LatestValueRelay<int>(source.stream);
      final a = <int>[];
      final b = <int>[];
      final subA = relay.stream.listen(a.add);
      final subB = relay.stream.listen(b.add);
      source.add(7);
      await pumpEventQueue();
      expect(a, [7]);
      expect(b, [7]);
      await subA.cancel();
      await subB.cancel();
      await relay.close();
      await source.close();
    });

    test('equals drops repeats', () async {
      final source = StreamController<int>.broadcast(sync: true);
      final relay = LatestValueRelay<int>(source.stream, equals: (a, b) => a == b);
      final seen = <int>[];
      final sub = relay.stream.listen(seen.add);
      source
        ..add(1)
        ..add(1)
        ..add(2);
      await pumpEventQueue();
      expect(seen, [1, 2]);
      expect(relay.value, 2);
      await sub.cancel();
      await relay.close();
      await source.close();
    });
  });

  group('stream cache file names', () {
    test('round-trip the cache key, unique per load', () {
      final a = streamCacheFileName('abc@orig', '1');
      final b = streamCacheFileName('abc@orig', '2');
      expect(a, isNot(b));
      expect(streamCacheKeyFromFileName(a), 'abc@orig');
      expect(streamCacheKeyFromFileName(streamCacheFileName('x~y@320000-mp3', '9')),
          'x~y@320000-mp3');
    });

    test('files from older versions are named after the key alone', () {
      expect(streamCacheKeyFromFileName(Uri.encodeComponent('abc@orig')), 'abc@orig');
    });
  });

  group('shouldSaveStreamWhilePlaying', () {
    bool save({
      bool cache = false,
      bool visualizer = false,
      bool current = true,
      bool wifi = false,
      bool lowPower = false,
      bool saver = false,
    }) =>
        shouldSaveStreamWhilePlaying(
          wantedForCache: cache,
          visualizerWanted: visualizer,
          isCurrentTrack: current,
          onWifi: wifi,
          lowPowerMode: lowPower,
          batterySaver: saver,
        );

    test('visualizer on screen: the current track is saved on any network', () {
      expect(save(visualizer: true), isTrue);
      expect(save(visualizer: true, wifi: true), isTrue);
    });

    test('tracks loaded ahead follow the Wi-Fi-only policy', () {
      expect(save(visualizer: true, current: false), isFalse);
      expect(save(visualizer: true, current: false, wifi: true), isTrue);
      expect(save(cache: true, current: false, wifi: true), isTrue);
    });

    test('pre-cache alone is Wi-Fi only', () {
      expect(save(cache: true), isFalse);
      expect(save(cache: true, wifi: true), isTrue);
    });

    test('power saving or nothing wanting it: never', () {
      expect(save(visualizer: true, lowPower: true), isFalse);
      expect(save(visualizer: true, saver: true), isFalse);
      expect(save(cache: true, wifi: true, lowPower: true), isFalse);
      expect(save(wifi: true), isFalse);
    });
  });

  test('outageRetryDelay backs off to every 30 s', () {
    expect(
      [for (var i = 0; i < 6; i++) outageRetryDelay(i).inSeconds],
      [5, 10, 20, 30, 30, 30],
    );
  });
}
