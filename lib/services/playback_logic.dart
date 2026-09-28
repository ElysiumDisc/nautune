/// Pure playback decisions used by `AudioPlayerService`.
///
/// Kept free of Flutter/plugin imports so the rules can be unit-tested
/// without an audio backend.
library;

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
