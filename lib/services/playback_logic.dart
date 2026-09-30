/// Pure playback decisions used by `AudioPlayerService`.
///
/// Kept free of Flutter/plugin imports so the rules can be unit-tested
/// without an audio backend.
library;

import 'dart:async';
import 'dart:math' show Random, pow;

import '../models/replay_gain_mode.dart';

/// Linear volume multiplier for ReplayGain [mode].
///
/// [trackGainDb] / [albumGainDb] are Jellyfin's normalization gains (dB to
/// reach its loudness target). Album mode falls back to the track gain.
/// [preampDb] shifts every track; because the player cannot amplify past
/// full scale, a negative preamp is what gives quiet tracks (positive gain)
/// room to be raised to match loud ones. The result is clamped to (0, 1].
double replayGainMultiplier({
  required ReplayGainMode mode,
  double? trackGainDb,
  double? albumGainDb,
  double preampDb = 0,
}) {
  if (mode == ReplayGainMode.off) return 1.0;
  final gain = mode == ReplayGainMode.album
      ? (albumGainDb ?? trackGainDb)
      : trackGainDb;
  final db = (gain ?? 0) + preampDb;
  final linear = pow(10, db / 20).toDouble();
  return linear.clamp(0.05, 1.0);
}

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

/// Short countdown label for the sleep timer, from the value on
/// `sleepTimerStream`: positive is time left (`12:05`, `1:02:09`), negative
/// is tracks left (`-1` is the end of this track), zero means no timer.
String? sleepTimerLabel(Duration value) {
  if (value == Duration.zero) return null;
  if (value.isNegative) {
    final tracks = -value.inSeconds;
    return tracks == 1 ? 'End of track' : '$tracks tracks';
  }
  final h = value.inHours;
  final m = value.inMinutes.remainder(60);
  final sec = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// ListenBrainz scrobble threshold: 50% of the track or 4 minutes, whichever
/// is less.
int scrobbleThresholdSeconds(Duration trackDuration) {
  final half = trackDuration.inSeconds ~/ 2;
  const fourMinutes = 240;
  return half < fourMinutes ? half : fourMinutes;
}

/// Accumulates the time a track was actually listened to, from position
/// ticks. A position jump that outruns the wall clock (a seek forward) and any
/// backward jump (seek back, A-B loop restart) add nothing, and neither do
/// paused ticks, so skipping ahead can't trigger a play count or scrobble.
class ListenedTimeTracker {
  Duration _listened = Duration.zero;
  Duration? _lastPosition;
  DateTime? _lastTick;

  /// Allowance on top of elapsed wall time for timer/decoder jitter.
  static const Duration _jitter = Duration(milliseconds: 1500);

  /// Largest advance credited between two ticks (ticks arrive every ~200 ms).
  /// Also rejects a seek made while paused, where wall time is long.
  static const Duration _maxStep = Duration(seconds: 5);

  Duration get listened => _listened;

  /// Start counting a new track, optionally crediting [seed] already heard
  /// (e.g. a session restored mid-track).
  void reset([Duration seed = Duration.zero]) {
    _listened = seed;
    _lastPosition = null;
    _lastTick = null;
  }

  void onPosition(Duration position, DateTime now) {
    final lastPosition = _lastPosition;
    final lastTick = _lastTick;
    _lastPosition = position;
    _lastTick = now;
    if (lastPosition == null || lastTick == null) return;
    final advanced = position - lastPosition;
    if (advanced <= Duration.zero) return;
    if (advanced > _maxStep) return; // a seek
    if (advanced > now.difference(lastTick) + _jitter) return; // a seek
    _listened += advanced;
  }
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
/// Smart shuffle: a random order that plays recently heard tracks later
/// and avoids the same artist twice in a row where it can.
///
/// Tracks heard in the last three days are drawn with lower weight
/// (weighted random sampling), so they tend to land near the end instead of
/// being excluded. [keepFirst] (a slot index) stays at the front, as with
/// [shuffleKeepingCurrent].
List<T> smartShuffle<T>(
  List<T> items, {
  required DateTime? Function(T item) lastPlayedOf,
  required String Function(T item) artistOf,
  required Random random,
  required DateTime now,
  int keepFirst = -1,
}) {
  if (items.length < 2) return List<T>.of(items);
  final hasFirst = keepFirst >= 0 && keepFirst < items.length;
  final rest = List<T>.of(items);
  final T? first = hasFirst ? rest.removeAt(keepFirst) : null;

  double weight(T item) {
    final last = lastPlayedOf(item);
    if (last == null) return 1.0;
    final hours = now.difference(last).inMinutes / 60.0;
    return (hours / 72.0).clamp(0.1, 1.0);
  }

  // Efraimidis–Spirakis: sort by u^(1/w), larger first.
  final keyed = [
    for (final item in rest)
      (item, pow(random.nextDouble(), 1 / weight(item)).toDouble()),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  final ordered = [
    if (hasFirst) first as T,
    for (final (item, _) in keyed) item,
  ];

  // Spread artists: if a track repeats the previous artist, pull the next
  // track by someone else forward.
  // Near the end only one artist may be left; then move the clashing track
  // back into an earlier gap between two other artists.
  bool fitsAt(List<T> list, int k, String artist) =>
      (k == 0 || artistOf(list[k - 1]) != artist) &&
      (k == list.length || artistOf(list[k]) != artist);
  final minSlot = hasFirst ? 1 : 0;
  for (var i = 1; i < ordered.length; i++) {
    final prevArtist = artistOf(ordered[i - 1]);
    if (artistOf(ordered[i]) != prevArtist) continue;
    var fixed = false;
    for (var j = i + 1; j < ordered.length; j++) {
      if (artistOf(ordered[j]) != prevArtist) {
        ordered.insert(i, ordered.removeAt(j));
        fixed = true;
        break;
      }
    }
    if (fixed) continue;
    final item = ordered.removeAt(i);
    final artist = artistOf(item);
    var placed = false;
    for (var k = minSlot; k <= ordered.length; k++) {
      if (fitsAt(ordered, k, artist)) {
        ordered.insert(k, item);
        placed = true;
        break;
      }
    }
    if (!placed) ordered.insert(i, item); // unavoidable (one artist dominates)
  }
  return ordered;
}

/// Undo a shuffle: [current] (the shuffled queue, possibly edited since)
/// back in [original] order. Items added while shuffled keep their relative
/// order after the restored ones; items removed while shuffled stay gone.
/// Duplicates are matched by occurrence. Returns the queue and where the
/// item at [currentIndex] ended up (-1 when [currentIndex] is -1).
({List<T> queue, int index}) restoreQueueOrder<T>(
  List<T> original,
  List<T> current,
  int currentIndex,
  String Function(T item) idOf,
) {
  final available = <String, List<int>>{};
  for (var i = 0; i < current.length; i++) {
    available.putIfAbsent(idOf(current[i]), () => []).add(i);
  }
  final order = <int>[];
  for (final item in original) {
    final slots = available[idOf(item)];
    if (slots != null && slots.isNotEmpty) order.add(slots.removeAt(0));
  }
  final used = order.toSet();
  for (var i = 0; i < current.length; i++) {
    if (!used.contains(i)) order.add(i);
  }
  return (
    queue: [for (final i in order) current[i]],
    index: currentIndex < 0 ? -1 : order.indexOf(currentIndex),
  );
}

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

/// Whether a stream should be saved to disk while it plays (just_audio
/// LockCachingAudioSource). A saved stream keeps downloading to the end even
/// after the track is skipped, so for the pre-cache (and for tracks loaded
/// ahead, which may well be skipped) it follows the background-copy policy
/// ([shouldCacheStreamingCopy]: Wi-Fi only, no power saving). The iOS
/// visualizer needs a local copy of the track playing *now*: that one is
/// saved on any network while a visualizer is on screen (not in Low Power
/// Mode / battery saver) — it costs nothing extra unless the track is
/// skipped.
bool shouldSaveStreamWhilePlaying({
  required bool wantedForCache,
  required bool visualizerWanted,
  required bool isCurrentTrack,
  required bool onWifi,
  required bool lowPowerMode,
  required bool batterySaver,
}) {
  if (lowPowerMode || batterySaver) return false;
  if (visualizerWanted && isCurrentTrack) return true;
  return shouldCacheStreamingCopy(
    wanted: wantedForCache || visualizerWanted,
    onWifi: onWifi,
    lowPowerMode: lowPowerMode,
    batterySaver: batterySaver,
  );
}

/// Delay before the [attempt]-th (0-based) automatic retry of a track whose
/// reload failed during a network outage: 5 s, 10 s, 20 s, then every 30 s.
Duration outageRetryDelay(int attempt) {
  const steps = [5, 10, 20];
  return Duration(seconds: attempt < steps.length ? steps[attempt] : 30);
}

/// A cached file as seen by the size-budget eviction.
// ---------------------------------------------------------------------------
// Audio cache variants
// ---------------------------------------------------------------------------

/// Cache variant for the best available copy (original file, or the
/// original-quality stream that only transcodes formats AVPlayer can't play).
const String kOriginalCacheVariant = 'orig';

/// Streams at or above this cap are original quality (the app requests
/// original quality with a 140 Mbps cap).
const int _originalVariantMinBitrate = 100000000;

/// Which quality a stream [url] delivers, used to key the audio cache so a
/// copy cached at a low bitrate is never replayed after switching to a
/// higher quality. URLs without a bitrate cap (download/override URLs) are
/// original quality.
String cacheVariantForUrl(String? url) {
  if (url == null) return kOriginalCacheVariant;
  final query = Uri.tryParse(url)?.queryParameters ?? const {};
  final bitrate = int.tryParse(query['maxStreamingBitrate'] ?? '');
  if (bitrate == null || bitrate >= _originalVariantMinBitrate) {
    return kOriginalCacheVariant;
  }
  final codec = query['audioCodec'] ?? 'mp3';
  return '$bitrate-$codec';
}

/// File extension for an audio `Content-Type` (for files saved from a
/// stream), so AVPlayer can open the cached copy later.
String audioExtensionForMime(String mime) {
  final m = mime.toLowerCase().split(';').first.trim();
  return switch (m) {
    'audio/mpeg' || 'audio/mp3' => 'mp3',
    'audio/flac' || 'audio/x-flac' => 'flac',
    'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' || 'audio/aac' || 'audio/aacp' => 'm4a',
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    'audio/aiff' || 'audio/x-aiff' => 'aiff',
    _ => 'mp3',
  };
}

/// Cache key for [trackId] cached at [variant] (`id@variant`).
String audioCacheKey(String trackId, String variant) => '$trackId@$variant';

/// Track id a cache key belongs to. Keys written before variants existed are
/// the bare track id.
String trackIdFromCacheKey(String key) {
  final at = key.indexOf('@');
  return at < 0 ? key : key.substring(0, at);
}

/// File name for a stream saved while it plays: the cache [key] plus a
/// [unique] suffix, so two loads of the same track never share a partial
/// file. [unique] must not contain `~`.
String streamCacheFileName(String key, String unique) =>
    '${Uri.encodeComponent(key)}~$unique';

/// Cache key of a stream-cache file name (see [streamCacheFileName]); older
/// versions named the file after the encoded key alone.
String streamCacheKeyFromFileName(String fileName) {
  final tilde = fileName.lastIndexOf('~');
  return Uri.decodeComponent(tilde < 0 ? fileName : fileName.substring(0, tilde));
}

/// Cache keys that satisfy a request for [trackId] at [variant], best first.
/// An original-quality copy satisfies any request; a lower-bitrate or legacy
/// (unknown quality) copy only satisfies a request for a lossy variant.
List<String> cacheKeysForRequest(String trackId, String variant) {
  final original = audioCacheKey(trackId, kOriginalCacheVariant);
  if (variant == kOriginalCacheVariant) return [original];
  return [audioCacheKey(trackId, variant), original, trackId];
}

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

/// Detects a "playing" player that has stopped making progress (e.g. a
/// stream that died mid-track: AVPlayer stops, but no error or completion
/// event reaches Dart).
///
/// Feed it from a periodic timer (not from the player's position stream:
/// that stream drops repeated positions, so a frozen position never arrives
/// as a tick). It is deliberately conservative — a false alarm reloads the
/// track and throws away what AVPlayer had buffered:
/// * not buffering: a stall once the position has not moved for
///   [threshold] — except at/after the reported duration, where the player
///   is just finishing (a short duration estimate) and its completion event
///   ends the track;
/// * buffering (waiting for data, so a frozen position is expected): a stall
///   only after buffering without a break for [bufferingThreshold], and
///   never while there is no network — AVPlayer resumes by itself when the
///   connection is back, a reload now would only fail.
class PlaybackStallDetector {
  PlaybackStallDetector({
    this.threshold = const Duration(seconds: 12),
    this.bufferingThreshold = const Duration(seconds: 30),
    this.minProgress = const Duration(milliseconds: 50),
  });

  final Duration threshold;
  final Duration bufferingThreshold;
  final Duration minProgress;

  Duration? _lastPosition;
  DateTime? _lastProgressAt;
  DateTime? _bufferingSince;

  void reset() {
    _lastPosition = null;
    _lastProgressAt = null;
    _bufferingSince = null;
  }

  /// Feed a sample taken while the player reports "playing". [buffering]:
  /// it is waiting for data; [networkAvailable]: false while the device has
  /// no connection (or the app is offline); [duration]: the player's
  /// duration, if known. Returns true once playback counts as stalled.
  bool onTick(
    Duration position,
    DateTime now, {
    bool buffering = false,
    bool networkAvailable = true,
    Duration? duration,
  }) {
    if (buffering) {
      // Waiting for data: only the buffering clock counts.
      _lastPosition = position;
      _lastProgressAt = now;
      if (!networkAvailable) {
        // An outage: wait for the network, however long it takes.
        _bufferingSince = null;
        return false;
      }
      final since = _bufferingSince ??= now;
      return now.difference(since) >= bufferingThreshold;
    }
    _bufferingSince = null;

    final last = _lastPosition;
    if (last == null || (position - last).abs() >= minProgress) {
      _lastPosition = position;
      _lastProgressAt = now;
      return false;
    }
    if (duration != null && duration > Duration.zero && position >= duration) {
      // Parked at the reported end while still playing: the audio runs past
      // an estimated duration, completion follows.
      _lastProgressAt = now;
      return false;
    }
    return now.difference(_lastProgressAt!) >= threshold;
  }
}

// ---------------------------------------------------------------------------
// Shared latest-value streams
// ---------------------------------------------------------------------------

/// A multi-listener stream that stays subscribed to [source] and replays the
/// latest value to every new listener.
///
/// Unlike `shareValue()` (rxdart's refCount closes its subject when the last
/// listener cancels, so a widget that remounts later can't listen again),
/// listeners can come and go any number of times. Call [close] when done.
class LatestValueRelay<T> {
  LatestValueRelay(Stream<T> source, {bool Function(T a, T b)? equals})
      : _equals = equals {
    _sourceSub = source.listen(_add, onError: _controller.addError);
  }

  final bool Function(T a, T b)? _equals;
  final StreamController<T> _controller = StreamController<T>.broadcast(sync: true);
  late final StreamSubscription<T> _sourceSub;
  T? _latest;
  bool _hasValue = false;

  bool get hasValue => _hasValue;

  /// Latest value (throws if nothing was emitted yet; check [hasValue]).
  T get value {
    if (!_hasValue) throw StateError('No value yet');
    return _latest as T;
  }

  void _add(T value) {
    final equals = _equals;
    if (_hasValue && equals != null && equals(_latest as T, value)) return;
    _latest = value;
    _hasValue = true;
    if (!_controller.isClosed) _controller.add(value);
  }

  /// Every listener first receives the latest value (if any), then updates.
  late final Stream<T> stream = Stream<T>.multi((listener) {
    if (_hasValue) listener.add(_latest as T);
    final sub = _controller.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    listener.onCancel = sub.cancel;
    listener.onPause = sub.pause;
    listener.onResume = sub.resume;
  }, isBroadcast: true);

  Future<void> close() async {
    await _sourceSub.cancel();
    await _controller.close();
  }
}
