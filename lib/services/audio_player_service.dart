import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart';

import '../jellyfin/jellyfin_track.dart';
import 'playback_state_store.dart';

class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();
  final PlaybackStateStore _stateStore = PlaybackStateStore();
  
  JellyfinTrack? _currentTrack;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  Timer? _positionSaveTimer;
  
  // Streams
  final StreamController<JellyfinTrack?> _currentTrackController = StreamController<JellyfinTrack?>.broadcast();
  final StreamController<bool> _playingController = StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController = StreamController<Duration?>.broadcast();
  
  Stream<JellyfinTrack?> get currentTrackStream => _currentTrackController.stream;
  Stream<bool> get playingStream => _playingController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  
  JellyfinTrack? get currentTrack => _currentTrack;
  AudioPlayer get player => _player;
  
  AudioPlayerService() {
    _initAudioSession();
    _setupListeners();
    _restorePlaybackState();
  }
  
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      print('Audio session setup failed: $e');
    }
  }
  
  void _setupListeners() {
    // Position updates
    _player.onPositionChanged.listen((position) {
      _positionController.add(position);
    });
    
    // Duration updates
    _player.onDurationChanged.listen((duration) {
      _durationController.add(duration);
    });
    
    // State changes
    _player.onPlayerStateChanged.listen((state) {
      final isPlaying = state == PlayerState.playing;
      _playingController.add(isPlaying);
      
      if (isPlaying) {
        _startPositionSaving();
      } else {
        _stopPositionSaving();
        _saveCurrentPosition();
      }
    });
    
    // Track completion
    _player.onPlayerComplete.listen((_) {
      skipToNext();
    });
  }
  
  Future<void> _restorePlaybackState() async {
    final state = await _stateStore.loadPlaybackState();
    if (state != null && state.currentTrackId != null) {
      // For now, we can't fully restore the queue without fetching tracks again
      // Just note that we would need the track data
      // TODO: Store and restore full track data or fetch from server
      print('Saved position: ${state.positionMs}ms for track ${state.currentTrackId}');
    }
  }
  
  Future<void> playTrack(
    JellyfinTrack track, {
    List<JellyfinTrack>? queueContext,
    String? albumId,
    String? albumName,
  }) async {
    _currentTrack = track;
    _currentTrackController.add(track);
    
    if (queueContext != null) {
      _queue = queueContext;
      _currentIndex = _queue.indexWhere((t) => t.id == track.id);
      if (_currentIndex == -1) {
        _queue = [track];
        _currentIndex = 0;
      }
    } else {
      _queue = [track];
      _currentIndex = 0;
    }
    
    await _player.stop();
    await _player.setSourceUrl(track.streamUrl);
    await _player.resume();
    
    await _savePlaybackState();
  }
  
  Future<void> playAlbum(
    List<JellyfinTrack> tracks, {
    String? albumId,
    String? albumName,
  }) async {
    if (tracks.isEmpty) return;
    await playTrack(
      tracks.first,
      queueContext: tracks,
      albumId: albumId,
      albumName: albumName,
    );
  }
  
  Future<void> pause() async {
    await _player.pause();
    await _saveCurrentPosition();
  }
  
  Future<void> resume() async {
    await _player.resume();
  }
  
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    await _saveCurrentPosition();
  }
  
  Future<void> skipToNext() async {
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      await playTrack(_queue[_currentIndex], queueContext: _queue);
    }
  }

  Future<void> skipToPrevious() async {
    if (_currentIndex > 0) {
      _currentIndex--;
      await playTrack(_queue[_currentIndex], queueContext: _queue);
    }
  }

  // Alias methods for compatibility
  Future<void> playPause() async {
    final state = _player.state;
    if (state == PlayerState.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> playNext() => skipToNext();
  Future<void> playPrevious() => skipToPrevious();
  
  void _startPositionSaving() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _saveCurrentPosition();
    });
  }
  
  void _stopPositionSaving() {
    _positionSaveTimer?.cancel();
  }
  
  Future<void> _saveCurrentPosition() async {
    if (_currentTrack == null) return;
    
    final position = await _player.getCurrentPosition();
    if (position != null) {
      await _stateStore.savePlaybackState(
        trackId: _currentTrack!.id,
        position: position,
        queueContext: _queue,
      );
    }
  }
  
  Future<void> _savePlaybackState() async {
    if (_currentTrack == null) return;
    
    await _stateStore.savePlaybackState(
      trackId: _currentTrack!.id,
      position: Duration.zero,
      queueContext: _queue,
    );
  }
  
  void dispose() {
    _positionSaveTimer?.cancel();
    _player.dispose();
    _currentTrackController.close();
    _playingController.close();
    _positionController.close();
    _durationController.close();
  }
}
