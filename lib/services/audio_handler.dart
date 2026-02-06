import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import '../jellyfin/jellyfin_track.dart';

class NautuneAudioHandler extends audio_service.BaseAudioHandler with audio_service.QueueHandler, audio_service.SeekHandler {
  AudioPlayer _player;
  final void Function() onPlay;
  final void Function() onPause;
  final void Function() onStop;
  final void Function() onSkipToNext;
  final void Function() onSkipToPrevious;
  final void Function(Duration) onSeek;
  
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _stateSubscription;

  NautuneAudioHandler({
    required AudioPlayer player,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onSkipToNext,
    required this.onSkipToPrevious,
    required this.onSeek,
  }) : _player = player {
    _listenToPlayerState();
  }

  void updatePlayer(AudioPlayer newPlayer) {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _stateSubscription?.cancel();
    _player = newPlayer;
    _listenToPlayerState();
  }

  void _listenToPlayerState() {
    // Listen to position changes
    _positionSubscription = _player.onPositionChanged.listen((position) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
      ));
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

  void _broadcastState(PlayerState state) {
    final playing = state == PlayerState.playing;
    final processingState = state == PlayerState.completed
        ? audio_service.AudioProcessingState.completed
        : state == PlayerState.playing || state == PlayerState.paused
            ? audio_service.AudioProcessingState.ready
            : audio_service.AudioProcessingState.idle;

    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      controls: [
        audio_service.MediaControl.skipToPrevious,
        playing ? audio_service.MediaControl.pause : audio_service.MediaControl.play,
        audio_service.MediaControl.stop,
        audio_service.MediaControl.skipToNext,
      ],
      systemActions: const {
        audio_service.MediaAction.seek,
        audio_service.MediaAction.seekForward,
        audio_service.MediaAction.seekBackward,
      },
      processingState: processingState,
    ));
  }

  /// Force broadcast playing state to OS media controls.
  /// This is used after gapless transitions where the state change event
  /// may not fire because the new player is already in playing state.
  /// Includes position update to force iOS/CarPlay to re-render controls.
  Future<void> forcePlayingState() async {
    // Get current position from player
    final position = await _player.getCurrentPosition() ?? Duration.zero;

    playbackState.add(playbackState.value.copyWith(
      playing: true,
      updatePosition: position,
      controls: [
        audio_service.MediaControl.skipToPrevious,
        audio_service.MediaControl.pause,
        audio_service.MediaControl.stop,
        audio_service.MediaControl.skipToNext,
      ],
      systemActions: const {
        audio_service.MediaAction.seek,
        audio_service.MediaAction.seekForward,
        audio_service.MediaAction.seekBackward,
      },
      processingState: audio_service.AudioProcessingState.ready,
    ));
  }

  /// Force broadcast current actual state (playing OR paused) to OS.
  /// Unlike forcePlayingState() which always says "playing", this reads
  /// the real player state. Ensures lock screen controls stay interactive.
  Future<void> forceBroadcastCurrentState() async {
    final position = await _player.getCurrentPosition() ?? Duration.zero;
    _broadcastState(_player.state);
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  void updateNautuneMediaItem(JellyfinTrack track, {Uri? offlineArtUri}) {
    // Use network artwork URL if available, otherwise fall back to offline artwork
    final networkArtUrl = track.artworkUrl();
    final artUri = networkArtUrl != null ? Uri.parse(networkArtUrl) : offlineArtUri;

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
    queue.add(tracks.map((track) => audio_service.MediaItem(
      id: track.id,
      album: track.album,
      title: track.name,
      artist: track.displayArtist,
      duration: track.duration,
      artUri: track.artworkUrl() != null ? Uri.parse(track.artworkUrl()!) : null,
    )).toList());
  }

  @override
  Future<void> play() async {
    onPlay();
  }

  @override
  Future<void> pause() async {
    onPause();
  }

  @override
  Future<void> stop() async {
    // Fire and forget onStop to prevent deadlocks if reporting hangs
    onStop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    try {
      onSkipToNext();
    } catch (e) {
      debugPrint('⚠️ Skip to next failed: $e');
    }
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      onSkipToPrevious();
    } catch (e) {
      debugPrint('⚠️ Skip to previous failed: $e');
    }
  }

  @override
  Future<void> seek(Duration position) async {
    onSeek(position);
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _stateSubscription?.cancel();
  }
}
