import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/playback_state.dart';
import 'playback_state_store.dart';

class AudioPlayerService {
  AudioPlayerService({
    required this.playbackStateStore,
    required String Function(String trackId) buildStreamUrl,
  }) : _buildStreamUrl = buildStreamUrl {
    _player = AudioPlayer();
    _initAudioSession();
    _setupListeners();
  }

  final PlaybackStateStore playbackStateStore;
  final String Function(String trackId) _buildStreamUrl;

  late final AudioPlayer _player;
  List<JellyfinTrack> _queue = [];
  int _currentIndex = 0;
  String? _currentAlbumId;
  String? _currentAlbumName;

  AudioPlayer get player => _player;
  List<JellyfinTrack> get queue => _queue;
  int get currentIndex => _currentIndex;
  JellyfinTrack? get currentTrack =>
      _queue.isEmpty ? null : _queue[_currentIndex];
  bool get hasQueue => _queue.isNotEmpty;

  Future<void> _initAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  void _setupListeners() {
    _player.positionStream.listen((position) {
      _savePlaybackState();
    });

    _player.playingStream.listen((isPlaying) {
      _savePlaybackState();
    });

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        playNext();
      }
    });
  }

  Future<void> playAlbum(List<JellyfinTrack> tracks,
      {String? albumId, String? albumName, int startIndex = 0}) async {
    if (tracks.isEmpty) return;

    _queue = tracks;
    _currentIndex = startIndex;
    _currentAlbumId = albumId;
    _currentAlbumName = albumName;

    await _playCurrentTrack();
  }

  Future<void> playTrack(JellyfinTrack track,
      {List<JellyfinTrack>? queueContext,
      String? albumId,
      String? albumName}) async {
    if (queueContext != null && queueContext.isNotEmpty) {
      _queue = queueContext;
      _currentIndex = queueContext.indexWhere((t) => t.id == track.id);
      if (_currentIndex == -1) _currentIndex = 0;
    } else {
      _queue = [track];
      _currentIndex = 0;
    }

    _currentAlbumId = albumId;
    _currentAlbumName = albumName;

    await _playCurrentTrack();
  }

  Future<void> _playCurrentTrack() async {
    if (_queue.isEmpty) return;

    final track = _queue[_currentIndex];
    final url = _buildStreamUrl(track.id);

    try {
      await _player.setUrl(url);
      await _player.play();
      await _savePlaybackState();
    } catch (e) {
      // Error handled by UI listening to player state
    }
  }

  Future<void> playPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    await _savePlaybackState();
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      await _playCurrentTrack();
    } else {
      await stop();
    }
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrentTrack();
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    await _savePlaybackState();
  }

  Future<void> stop() async {
    await _player.stop();
    _queue = [];
    _currentIndex = 0;
    _currentAlbumId = null;
    _currentAlbumName = null;
    await playbackStateStore.clear();
  }

  Future<void> restorePlaybackState() async {
    final savedState = await playbackStateStore.load();
    if (savedState == null || !savedState.hasTrack) return;

    // Note: Queue restoration requires fetching tracks from Jellyfin
    // This will be handled by AppState which has access to JellyfinService
  }

  Future<void> _savePlaybackState() async {
    if (_queue.isEmpty || currentTrack == null) return;

    final state = PlaybackState(
      currentTrackId: currentTrack!.id,
      currentTrackName: currentTrack!.name,
      currentAlbumId: _currentAlbumId,
      currentAlbumName: _currentAlbumName,
      positionMs: _player.position.inMilliseconds,
      isPlaying: _player.playing,
      queueIds: _queue.map((t) => t.id).toList(),
      currentQueueIndex: _currentIndex,
    );

    await playbackStateStore.save(state);
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}
