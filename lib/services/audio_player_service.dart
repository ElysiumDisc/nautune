import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';

import '../jellyfin/jellyfin_track.dart';
import 'download_service.dart';
import 'playback_state_store.dart';

class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _nextPlayer = AudioPlayer();
  final PlaybackStateStore _stateStore = PlaybackStateStore();
  DownloadService? _downloadService;
  
  JellyfinTrack? _currentTrack;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  Timer? _positionSaveTimer;
  bool _isTransitioning = false;

  void setDownloadService(DownloadService service) {
    _downloadService = service;
  }
  
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

  String get _deviceId => 'nautune-${Platform.operatingSystem}';
  
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
    
    // Track completion - gapless transition
    _player.onPlayerComplete.listen((_) async {
      if (!_isTransitioning) {
        await _gaplessTransition();
      }
    });
  }
  
  Future<void> _gaplessTransition() async {
    if (_currentIndex + 1 < _queue.length) {
      _isTransitioning = true;
      
      // Swap players for gapless playback
      final temp = _player;
      // Note: This is a simplified approach. For true gapless,
      // we'd need platform-specific implementations or just_audio package
      
      _currentIndex++;
      _currentTrack = _queue[_currentIndex];
      _currentTrackController.add(_currentTrack);
      
      // Preload next track if available
      if (_currentIndex + 1 < _queue.length) {
        await _preloadNextTrack();
      }
      
      _isTransitioning = false;
      _saveCurrentPosition();
    } else {
      // Queue finished
      await stop();
    }
  }
  
  Future<void> _preloadNextTrack() async {
    if (_currentIndex + 1 >= _queue.length) return;
    
    final nextTrack = _queue[_currentIndex + 1];
    final url = nextTrack.directDownloadUrl();
    
    if (url != null) {
      try {
        await _nextPlayer.setSource(UrlSource(url));
      } catch (e) {
        // Preload failed, will try regular load on track change
      }
    }
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
    bool reorderQueue = false,
  }) async {
    _currentTrack = track;
    _currentTrackController.add(track);
    
    if (queueContext != null) {
      if (reorderQueue) {
        _queue = List<JellyfinTrack>.from(queueContext)
          ..sort((a, b) {
            final discA = a.discNumber ?? 0;
            final discB = b.discNumber ?? 0;
            if (discA != discB) return discA.compareTo(discB);
            final trackA = a.indexNumber ?? 0;
            final trackB = b.indexNumber ?? 0;
            if (trackA != trackB) return trackA.compareTo(trackB);
            return a.name.compareTo(b.name);
          });
      } else {
        _queue = queueContext;
      }
      _currentIndex = _queue.indexWhere((t) => t.id == track.id);
      if (_currentIndex == -1) {
        _queue = [track];
        _currentIndex = 0;
      }
    } else {
      _queue = [track];
      _currentIndex = 0;
    }
    
    final downloadUrl = track.directDownloadUrl();
    final universalUrl = track.universalStreamUrl(
      deviceId: _deviceId,
      maxBitrate: 320000,
      audioCodec: 'mp3',
      container: 'mp3',
    );

    await _player.stop();

    Future<bool> trySetSource(String? url, {bool isFile = false}) async {
      if (url == null) return false;
      try {
        if (isFile) {
          await _player.setSource(DeviceFileSource(url));
        } else {
          await _player.setSource(UrlSource(url));
        }
        return true;
      } on PlatformException {
        return false;
      }
    }

    String? activeUrl;
    bool isOffline = false;
    
    // Check for downloaded file first (works in airplane mode!)
    final localPath = _downloadService?.getLocalPath(track.id);
    if (localPath != null && await trySetSource(localPath, isFile: true)) {
      activeUrl = localPath;
      isOffline = true;
      print('Playing from local file: $localPath');
    } else if (await trySetSource(downloadUrl)) {
      activeUrl = downloadUrl;
    } else if (await trySetSource(universalUrl)) {
      activeUrl = universalUrl;
    }

    if (activeUrl == null) {
      throw PlatformException(
        code: 'no_source',
        message: 'Unable to prepare media stream for ${track.name}',
      );
    }

    try {
      await _player.resume();
    } on PlatformException {
      if (activeUrl != universalUrl && universalUrl != null) {
        if (await trySetSource(universalUrl)) {
          await _player.resume();
          activeUrl = universalUrl;
        } else {
          rethrow;
        }
      } else {
        rethrow;
      }
    }
    
    await _savePlaybackState();
  }
  
  Future<void> playAlbum(
    List<JellyfinTrack> tracks, {
    String? albumId,
    String? albumName,
  }) async {
    if (tracks.isEmpty) return;
    final ordered = List<JellyfinTrack>.from(tracks)
      ..sort((a, b) {
        final discA = a.discNumber ?? 0;
        final discB = b.discNumber ?? 0;
        if (discA != discB) return discA.compareTo(discB);
        final trackA = a.indexNumber ?? 0;
        final trackB = b.indexNumber ?? 0;
        if (trackA != trackB) return trackA.compareTo(trackB);
        return a.name.compareTo(b.name);
      });
    final first = ordered.first;
    await playTrack(
      first,
      queueContext: ordered,
      albumId: albumId,
      albumName: albumName,
      reorderQueue: false,
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

  Future<void> stop() async {
    await _player.stop();
    _currentTrack = null;
    _currentTrackController.add(null);
    _queue.clear();
    _currentIndex = 0;
    await _stateStore.clear();
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
  Future<void> next() => skipToNext();
  Future<void> previous() => skipToPrevious();
  
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
