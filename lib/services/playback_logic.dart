/// Pure playback decisions used by `AudioPlayerService`.
///
/// Kept free of Flutter/plugin imports so the rules can be unit-tested
/// without an audio backend.
library;

import 'dart:math' show Random;

/// Resolves which queue slot a track should play from.
///
/// Queues may contain the same track more than once (e.g. `[A, B, A, C]`),
/// so the caller's explicit [requestedIndex] wins whenever it is in range and
/// actually points at [trackId]. Otherwise the queue is searched; when
/// [nearIndex] is given, the matching slot closest to it is chosen (ties go
/// forward, i.e. to the later slot), else the first match. Returns -1 when the
/// track is not in the queue.
int resolveQueueIndex<T>(
  List<T> queue,
  String trackId,
  String Function(T item) idOf, {
  int? requestedIndex,
  int? nearIndex,
}) {
  if (requestedIndex != null &&
      requestedIndex >= 0 &&
      requestedIndex < queue.length &&
      idOf(queue[requestedIndex]) == trackId) {
    return requestedIndex;
  }

  if (nearIndex == null) {
    for (var i = 0; i < queue.length; i++) {
      if (idOf(queue[i]) == trackId) return i;
    }
    return -1;
  }

  var best = -1;
  var bestDistance = 0;
  for (var i = 0; i < queue.length; i++) {
    if (idOf(queue[i]) != trackId) continue;
    final distance = (i - nearIndex).abs();
    // On a tie the later (forward) slot wins.
    if (best == -1 || distance < bestDistance ||
        (distance == bestDistance && i > best)) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}

/// Volume the sleep timer should apply at [remaining] time left, or null when
/// outside the fade window (no fade should be applied).
///
/// The fade is always computed from the user's *current* volume, so a timer
/// never has to remember (and later restore) a stale "pre-sleep" volume.
double? sleepTimerFadeVolume({
  required double userVolume,
  required Duration remaining,
  Duration fadeWindow = const Duration(seconds: 30),
}) {
  final remainingSeconds = remaining.inSeconds;
  final windowSeconds = fadeWindow.inSeconds;
  if (windowSeconds <= 0) return null;
  if (remainingSeconds <= 0 || remainingSeconds > windowSeconds) return null;
  return (userVolume * (remainingSeconds / windowSeconds)).clamp(0.0, 1.0);
}

/// ListenBrainz scrobble threshold: 50% of the track or 4 minutes, whichever
/// is less.
int scrobbleThresholdSeconds(Duration trackDuration) {
  final half = trackDuration.inSeconds ~/ 2;
  const fourMinutes = 240;
  return half < fourMinutes ? half : fourMinutes;
}

// ---------------------------------------------------------------------------
// Queue index bookkeeping
// ---------------------------------------------------------------------------

/// Current-track index after removing the item at [removedIndex] from a
/// queue that had [lengthBefore] items.
///
/// Removing an earlier item shifts the current track down by one. Removing
/// the current item makes whatever slides into its slot current (the next
/// track), or the new last track when the current one was last. Returns 0
/// when the queue becomes empty.
int currentIndexAfterRemoval({
  required int currentIndex,
  required int removedIndex,
  required int lengthBefore,
}) {
  final lengthAfter = lengthBefore - 1;
  if (lengthAfter <= 0) return 0;
  if (removedIndex < currentIndex) return currentIndex - 1;
  if (removedIndex == currentIndex && currentIndex >= lengthAfter) {
    return lengthAfter - 1;
  }
  return currentIndex;
}

/// Current-track index after moving the item at [from] to [to] (final
/// position, i.e. `removeAt(from)` followed by `insert(to, item)`).
int currentIndexAfterMove({
  required int currentIndex,
  required int from,
  required int to,
}) {
  if (from == currentIndex) return to;
  if (from < currentIndex && to >= currentIndex) return currentIndex - 1;
  if (from > currentIndex && to <= currentIndex) return currentIndex + 1;
  return currentIndex;
}

/// Current-track index after inserting an item at [insertIndex].
int currentIndexAfterInsert({
  required int currentIndex,
  required int insertIndex,
}) {
  return insertIndex <= currentIndex ? currentIndex + 1 : currentIndex;
}

/// The next queue slot after [from], moving in [direction] (`1` forward,
/// `-1` backward), whose item [isPlayable] — e.g. the next downloaded track
/// while offline. With [wrap] (repeat-all) the search continues past the end
/// (or start) of the queue.
///
/// [from] itself is never returned and every other slot is checked at most
/// once, so this always terminates. Returns -1 when no slot qualifies (or
/// the queue is empty / [direction] is invalid).
int nextPlayableIndex({
  required int length,
  required int from,
  required int direction,
  required bool wrap,
  required bool Function(int index) isPlayable,
}) {
  if (length <= 0 || (direction != 1 && direction != -1)) return -1;
  var i = from;
  for (var step = 0; step < length; step++) {
    i += direction;
    if (i < 0 || i >= length) {
      if (!wrap) return -1;
      i = direction > 0 ? 0 : length - 1;
    }
    if (i == from) return -1;
    if (isPlayable(i)) return i;
  }
  return -1;
}

/// How many queue slots are passed over going from [from] to [target] in
/// [direction] (wrapping around a queue of [length]), counting [from] but
/// not [target]. `0` when they are the same slot.
int queueStepsBetween({
  required int length,
  required int from,
  required int target,
  required int direction,
}) {
  if (length <= 0) return 0;
  return ((target - from) * direction) % length;
}

/// Shuffles [queue] keeping the item at [currentIndex] first.
///
/// Only that one slot is pulled out, so other occurrences of the same track
/// (duplicates) stay in the queue.
List<T> shuffleKeepingCurrent<T>(
  List<T> queue,
  int currentIndex,
  Random random,
) {
  if (queue.isEmpty) return <T>[];
  if (currentIndex < 0 || currentIndex >= queue.length) {
    return List<T>.of(queue)..shuffle(random);
  }
  final rest = List<T>.of(queue)..removeAt(currentIndex);
  rest.shuffle(random);
  return <T>[queue[currentIndex], ...rest];
}

/// What the "previous" control (in-app, lock screen, CarPlay) should do.
enum PreviousAction {
  /// Nothing to do (empty queue).
  none,

  /// Seek the current track back to 0.
  restartCurrent,

  /// Play the track at `currentIndex - 1`.
  previousTrack,

  /// Wrap around to the last track (repeat-all at the start of the queue).
  wrapToLast,
}

/// How far into a track "previous" restarts it instead of going back
/// (Apple Music behaviour).
const Duration previousRestartThreshold = Duration(seconds: 3);

/// Decides what "previous" does. More than [restartThreshold] into the
/// track it restarts the track; otherwise it goes to the previous track,
/// wrapping to the last one under repeat-all at the start of the queue, or
/// restarting the first track when there is nothing before it.
PreviousAction resolvePreviousAction({
  required Duration position,
  required int currentIndex,
  required int queueLength,
  required bool repeatAll,
  Duration restartThreshold = previousRestartThreshold,
}) {
  if (queueLength <= 0) return PreviousAction.none;
  if (position > restartThreshold) return PreviousAction.restartCurrent;
  if (currentIndex > 0) return PreviousAction.previousTrack;
  if (repeatAll) return PreviousAction.wrapToLast;
  return PreviousAction.restartCurrent;
}

// ---------------------------------------------------------------------------
// Streaming / caching policy
// ---------------------------------------------------------------------------

/// Whether a second, full background copy of a *streaming* track may be
/// downloaded (used for the iOS FFT shadow player, waveform extraction, A-B
/// loop and offline replay).
///
/// The player is already downloading the same audio to play it, so the copy
/// doubles the bandwidth for that track. Only allow it when something wants
/// it, on Wi-Fi, and outside iOS Low Power Mode / battery saver.
bool shouldCacheStreamingCopy({
  required bool wanted,
  required bool onWifi,
  required bool lowPowerMode,
  required bool batterySaver,
}) {
  return wanted && onWifi && !lowPowerMode && !batterySaver;
}

/// A cached file as seen by the size-budget eviction.
class CacheEntryInfo {
  const CacheEntryInfo({
    required this.key,
    required this.bytes,
    required this.lastUsed,
  });

  final String key;
  final int bytes;
  final DateTime lastUsed;
}

/// Keys to evict (least recently used first) so the cache fits in
/// [maxBytes]. Keys in [protectedKeys] (e.g. the playing track) are never
/// evicted.
List<String> cacheKeysToEvict(
  List<CacheEntryInfo> entries, {
  required int maxBytes,
  Set<String> protectedKeys = const {},
}) {
  var total = 0;
  for (final e in entries) {
    total += e.bytes;
  }
  if (total <= maxBytes) return const [];
  final byAge = List<CacheEntryInfo>.of(entries)
    ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
  final evict = <String>[];
  for (final e in byAge) {
    if (total <= maxBytes) break;
    if (protectedKeys.contains(e.key)) continue;
    evict.add(e.key);
    total -= e.bytes;
  }
  return evict;
}

// ---------------------------------------------------------------------------
// Stall detection
// ---------------------------------------------------------------------------

/// Detects a "playing" player whose position has stopped advancing (e.g. a
/// stream that died mid-track: AVPlayer stops, but no error or completion
/// event reaches Dart).
class PlaybackStallDetector {
  PlaybackStallDetector({
    this.threshold = const Duration(seconds: 12),
    this.minProgress = const Duration(milliseconds: 50),
  });

  final Duration threshold;
  final Duration minProgress;

  Duration? _lastPosition;
  DateTime? _lastProgressAt;

  void reset() {
    _lastPosition = null;
    _lastProgressAt = null;
  }

  /// Feed a position tick taken while the player reports "playing". Returns
  /// true while the position has not moved for at least [threshold].
  bool onTick(Duration position, DateTime now) {
    final last = _lastPosition;
    if (last == null || (position - last).abs() >= minProgress) {
      _lastPosition = position;
      _lastProgressAt = now;
      return false;
    }
    return now.difference(_lastProgressAt!) >= threshold;
  }
}
