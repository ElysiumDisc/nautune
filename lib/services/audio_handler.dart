import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import '../jellyfin/jellyfin_track.dart';
import 'engine/engine_player.dart';

class NautuneAudioHandler extends audio_service.BaseAudioHandler with audio_service.QueueHandler, audio_service.SeekHandler {
  EnginePlayer _player;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onStop;
  final Future<void> Function() onSkipToNext;
  final Future<void> Function() onSkipToPrevious;
  final void Function(Duration) onSeek;

  /// Shuffle / repeat from Control Center, CarPlay or Siri.
  final void Function(bool shuffle)? onSetShuffle;
  final void Function(audio_service.AudioServiceRepeatMode mode)? onSetRepeat;
  
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _stateSubscription;

  /// Latest position reported by the player. Kept locally and only pushed to
  /// the OS on state changes / discontinuities: audio_service extrapolates
  /// the lock-screen position from `updatePosition + speed * elapsed`, so
  /// re-broadcasting on every ~200ms tick is wasted work.
  Duration _lastKnownPosition = Duration.zero;

  /// A reported position further than this from the OS's extrapolated
  /// position is treated as a jump (seek, A-B loop, new track) and pushed.
  static const Duration _positionDriftTolerance = Duration(milliseconds: 1500);

  NautuneAudioHandler({
    required EnginePlayer player,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onSkipToNext,
    required this.onSkipToPrevious,
    required this.onSeek,
    this.onSetShuffle,
    this.onSetRepeat,
  }) : _player = player {
    _listenToPlayerState();
  }

  void updatePlayer(EnginePlayer newPlayer) {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _stateSubscription?.cancel();
    _player = newPlayer;
    // The last known position belonged to the outgoing track (typically its
    // very end). Don't let the immediate re-broadcast below show that on the
    // lock screen for the incoming track; the new player's first tick (or
    // forcePlayingState) supplies the real position.
    _lastKnownPosition = Duration.zero;
    _listenToPlayerState();
  }

  void _listenToPlayerState() {
    // Listen to position changes
    _positionSubscription = _player.onPositionChanged.listen((position) {
      _lastKnownPosition = position;
      final expected = playbackState.value.position;
      if ((position - expected).abs() > _positionDriftTolerance) {
        _pushPosition(position);
      }
    });

    // Listen to duration changes
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      final currentItem = mediaItem.value;
      if (currentItem != null) {
        mediaItem.add(currentItem.copyWith(duration: duration));
      }
    });

    // Listen to playback state changes
    _stateSubscription = _player.onPlayerStateChanged.listen(_broadcastState);

    // Immediately broadcast current state to ensure UI/System sync
    // This fixes the issue where swapping players (gapless playback)
    // might miss the initial 'playing' event.
    _broadcastState(_player.state);
  }

  void _broadcastState(EngineState state) {
    final playing = state == EngineState.playing;
    final processingState = state == EngineState.completed
        ? audio_service.AudioProcessingState.completed
        : state == EngineState.playing || state == EngineState.paused
            ? audio_service.AudioProcessingState.ready
            : audio_service.AudioProcessingState.idle;

    // copyWith stamps a fresh updateTime, so always pair it with the real
    // position or the OS would extrapolate from a stale one.
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      updatePosition: _lastKnownPosition,
      controls: [
        audio_service.MediaControl.skipToPrevious,
        playing ? audio_service.MediaControl.pause : audio_service.MediaControl.play,
        audio_service.MediaControl.stop,
        audio_service.MediaControl.skipToNext,
      ],
      systemActions: _systemActions,
      processingState: processingState,
    ));
  }

  static const Set<audio_service.MediaAction> _systemActions = {
    audio_service.MediaAction.seek,
    audio_service.MediaAction.seekForward,
    audio_service.MediaAction.seekBackward,
    audio_service.MediaAction.setShuffleMode,
    audio_service.MediaAction.setRepeatMode,
  };

  /// Mirror the app's shuffle / repeat state to the system (CarPlay's Now
  /// Playing buttons, Siri).
  void updateModes({
    required bool shuffle,
    required audio_service.AudioServiceRepeatMode repeat,
  }) {
    final shuffleMode = shuffle
        ? audio_service.AudioServiceShuffleMode.all
        : audio_service.AudioServiceShuffleMode.none;
    final current = playbackState.value;
    if (current.shuffleMode == shuffleMode && current.repeatMode == repeat) {
      return;
    }
    playbackState.add(current.copyWith(
      shuffleMode: shuffleMode,
      repeatMode: repeat,
      updatePosition: _lastKnownPosition,
    ));
  }

  void _pushPosition(Duration position) {
    _lastKnownPosition = position;
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  /// Force broadcast playing state to OS media controls.
  /// This is used after gapless transitions where the state change event
  /// may not fire because the new player is already in playing state.
  /// Includes position update to force iOS/CarPlay to re-render controls.
  Future<void> forcePlayingState() async {
    // Get current position from player
    final position = await _player.getCurrentPosition() ?? Duration.zero;
    _lastKnownPosition = position;

    playbackState.add(playbackState.value.copyWith(
      playing: true,
      updatePosition: position,
      controls: [
        audio_service.MediaControl.skipToPrevious,
        audio_service.MediaControl.pause,
        audio_service.MediaControl.stop,
        audio_service.MediaControl.skipToNext,
      ],
      systemActions: _systemActions,
      processingState: audio_service.AudioProcessingState.ready,
    ));
  }

  /// Force broadcast current actual state (playing OR paused) to OS.
  /// Unlike forcePlayingState() which always says "playing", this reads
  /// the real player state. Ensures lock screen controls stay interactive.
  Future<void> forceBroadcastCurrentState() async {
    final position = await _player.getCurrentPosition() ?? Duration.zero;
    _lastKnownPosition = position;
    _broadcastState(_player.state);
  }

  /// [offlineArtUri] is the downloaded artwork file (only provided when the
  /// track is downloaded and the file exists). It is preferred over the
  /// network URL so the lock screen / CarPlay show art offline and don't
  /// re-fetch what is already on disk.
  void updateNautuneMediaItem(JellyfinTrack track, {Uri? offlineArtUri}) {
    final networkArtUrl = track.artworkUrl();
    final artUri = offlineArtUri ??
        (networkArtUrl != null ? Uri.parse(networkArtUrl) : null);

    final item = audio_service.MediaItem(
      id: track.id,
      album: track.album,
      title: track.name,
      artist: track.displayArtist,
      duration: track.duration,
      artUri: artUri,
    );
    mediaItem.add(item);
  }

  void updateNautuneQueue(List<JellyfinTrack> tracks) {
    queue.add(tracks.map((track) {
      final artUrl = track.artworkUrl();
      return audio_service.MediaItem(
        id: track.id,
        album: track.album,
        title: track.name,
        artist: track.displayArtist,
        duration: track.duration,
        artUri: artUrl != null ? Uri.parse(artUrl) : null,
      );
    }).toList());
  }

  @override
  Future<void> play() async {
    await onPlay();
  }

  @override
  Future<void> pause() async {
    await onPause();
  }

  @override
  Future<void> stop() async {
    await onStop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    try {
      await onSkipToNext();
    } catch (e) {
      debugPrint('⚠️ Skip to next failed: $e');
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      await onSkipToPrevious();
    } catch (e) {
      debugPrint('⚠️ Skip to previous failed: $e');
    }
  }

  @override
  Future<void> setShuffleMode(audio_service.AudioServiceShuffleMode shuffleMode) async {
    onSetShuffle?.call(shuffleMode != audio_service.AudioServiceShuffleMode.none);
  }

  @override
  Future<void> setRepeatMode(audio_service.AudioServiceRepeatMode repeatMode) async {
    onSetRepeat?.call(repeatMode);
  }

  @override
  Future<void> seek(Duration position) async {
    onSeek(position);
    _pushPosition(position);
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _stateSubscription?.cancel();
  }
}
