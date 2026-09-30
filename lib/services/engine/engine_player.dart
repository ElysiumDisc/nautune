import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:rxdart/rxdart.dart';

/// Where a track's audio comes from.
@immutable
class EngineSource {
  const EngineSource.file(this.path)
      : url = null,
        asset = null,
        cacheFile = null;

  const EngineSource.asset(this.asset)
      : path = null,
        url = null,
        cacheFile = null;

  /// A stream. With [cacheFile], the stream is downloaded once and saved to
  /// that file while it plays (only for untranscoded streams, which have a
  /// known length).
  const EngineSource.url(this.url, {this.cacheFile})
      : path = null,
        asset = null;

  final String? path;
  final String? asset;
  final String? url;
  final File? cacheFile;

  bool get isLocal => path != null || asset != null;

  ja.AudioSource toAudioSource() {
    if (path != null) {
      final p = path!.startsWith('file://') ? Uri.parse(path!).toFilePath() : path!;
      return ja.AudioSource.file(p);
    }
    if (asset != null) return ja.AudioSource.asset(asset!);
    final uri = Uri.parse(url!);
    final file = cacheFile;
    // ignore: experimental_member_use
    if (file != null) return ja.LockCachingAudioSource(uri, cacheFile: file);
    return ja.AudioSource.uri(uri);
  }

  @override
  String toString() => path ?? asset ?? url ?? '';
}

/// Simplified player state used by the playback engine.
enum EngineState { stopped, playing, paused, completed }

/// A playback error reported by the native player after loading (e.g. a
/// stream that failed mid-track). [index] is the playlist item it belongs
/// to (the gapless window may hold the current and the next track).
@immutable
class EnginePlaybackError {
  const EnginePlaybackError(this.code, this.message, this.index);

  final int code;
  final String? message;
  final int? index;

  @override
  String toString() => 'EnginePlaybackError($code, $message, index: $index)';
}

/// The one place Nautune talks to just_audio. It keeps the small surface
/// the engine was built on (load a source, resume, pause, seek, volume,
/// position/duration/state/complete streams) and adds a two-item playlist
/// window for gapless playback: [appendNext] queues the next track on the
/// same AVQueuePlayer, which starts it with no gap, and [onAdvanced] fires
/// when that happens.
class EnginePlayer {
  EnginePlayer()
      : _player = ja.AudioPlayer(
          // AudioPlayerService handles interruptions (ducking, resume only
          // if it was playing) itself.
          handleInterruptions: false,
          useLazyPreparation: false,
        ) {
    _indexSub = _player.currentIndexStream.listen(_onIndex);
  }

  final ja.AudioPlayer _player;
  late final StreamSubscription<int?> _indexSub;
  final _advanced = StreamController<void>.broadcast();

  /// Source queued after the current one (the gapless window), if any.
  ja.AudioSource? _nextSource;
  int _lastIndex = 0;
  bool _loading = false;
  bool _disposed = false;

  /// Fires when playback moved on to the track queued with [appendNext].
  Stream<void> get onAdvanced => _advanced.stream;

  late final Stream<Duration> onPositionChanged = _player
      .createPositionStream(
        minPeriod: const Duration(milliseconds: 200),
        maxPeriod: const Duration(milliseconds: 200),
      )
      .asBroadcastStream();

  Stream<Duration> get onDurationChanged =>
      _player.durationStream.whereType<Duration>();

  Stream<Duration> get bufferedPosition => _player.bufferedPositionStream;

  Stream<EngineState> get onPlayerStateChanged =>
      _player.playerStateStream.map(_map).distinct();

  /// Fires when the whole playlist has finished (no next track queued).
  Stream<void> get onPlayerComplete => _player.processingStateStream
      .distinct()
      .where((s) => s == ja.ProcessingState.completed)
      .map((_) {});

  /// Native playback errors after the source loaded (load failures are
  /// thrown by [setSource] instead).
  Stream<EnginePlaybackError> get onError => _player.errorStream
      .map((e) => EnginePlaybackError(e.code, e.message, e.index));

  EngineState get state => _map(_player.playerState);

  /// Current position (just_audio extrapolates it while playing).
  Duration get position => _player.position;

  /// Duration of the item playing now, if known (the extrapolated
  /// [position] never goes past it).
  Duration? get duration => _player.duration;

  /// Waiting for data while supposed to be playing.
  bool get isBuffering {
    final s = _player.processingState;
    return s == ja.ProcessingState.buffering || s == ja.ProcessingState.loading;
  }

  /// Whether playback was requested (just_audio keeps this set through
  /// buffering, errors and completion; only pause/stop clear it).
  bool get wantsToPlay => _player.playing;

  /// Playlist index of the item playing now.
  int? get currentIndex => _player.currentIndex;

  static EngineState _map(ja.PlayerState s) {
    switch (s.processingState) {
      case ja.ProcessingState.completed:
        return EngineState.completed;
      case ja.ProcessingState.idle:
        return EngineState.stopped;
      case ja.ProcessingState.loading:
      case ja.ProcessingState.buffering:
      case ja.ProcessingState.ready:
        return s.playing ? EngineState.playing : EngineState.paused;
    }
  }

  bool get hasSource => _player.audioSource != null;
  double get volume => _player.volume;
  bool get hasNext => _nextSource != null;

  Future<Duration?> getCurrentPosition() async => _player.position;
  Future<Duration?> getDuration() async => _player.duration;

  /// Load [source] as the only item. Returns its duration. Load failures
  /// throw [PlatformException] (as the engine's fallback paths expect); a
  /// load interrupted by a newer one returns null.
  Future<Duration?> setSource(EngineSource source) async {
    _nextSource = null;
    _lastIndex = 0;
    _loading = true;
    try {
      // just_audio keeps playing across a source change; the engine expects
      // a loaded-but-paused player that it starts with resume().
      if (_player.playing) await _player.pause();
      return await _player.setAudioSource(source.toAudioSource());
    } on ja.PlayerInterruptedException {
      return null;
    } on ja.PlayerException catch (e) {
      throw PlatformException(code: '${e.code}', message: e.message);
    } finally {
      _loading = false;
      _lastIndex = _player.currentIndex ?? 0;
    }
  }

  /// Queue [source] to start right after the current track, gaplessly.
  Future<void> appendNext(EngineSource source) async {
    await removeNext();
    await _dropPlayed();
    final audio = source.toAudioSource();
    _nextSource = audio;
    await _player.addAudioSource(audio);
  }

  /// Drop the queued next track (queue edited, repeat/sleep changed).
  Future<void> removeNext() async {
    final next = _nextSource;
    if (next == null) return;
    _nextSource = null;
    final index = _player.sequence.indexWhere((s) => identical(s, next));
    final current = _player.currentIndex ?? 0;
    if (index > current) {
      await _player.removeAudioSourceAt(index);
    }
  }

  /// Remove already-played items so the playlist stays at most
  /// [current, next] and their native resources are released.
  Future<void> _dropPlayed() async {
    final current = _player.currentIndex ?? 0;
    for (var i = current - 1; i >= 0; i--) {
      await _player.removeAudioSourceAt(i);
    }
    _lastIndex = _player.currentIndex ?? 0;
  }

  void _onIndex(int? index) {
    if (index == null || _loading || _disposed) return;
    final advanced = index > _lastIndex;
    _lastIndex = index;
    if (advanced) {
      // Normally the track from appendNext; if the engine had already
      // dropped it, the engine resyncs with its queue.
      _nextSource = null;
      _advanced.add(null);
    }
  }

  /// Start (or continue) playback. Returns once playback was requested;
  /// just_audio's own play() future only completes when playback stops.
  Future<void> resume() async {
    unawaited(_player.play().catchError((Object e) {
      debugPrint('⚠️ Engine play failed: $e');
    }));
  }

  Future<void> pause() => _player.pause();

  /// Stop and release the native player; the source stays set and reloads
  /// on the next resume.
  Future<void> stop() async {
    await removeNext();
    await _player.stop();
  }

  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> dispose() async {
    _disposed = true;
    await _indexSub.cancel();
    await _advanced.close();
    await _player.dispose();
  }
}
