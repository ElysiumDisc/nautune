import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/playback_state.dart';

class PlaybackStateStore {
  static const String _key = 'nautune_playback_state';

  Future<PlaybackState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json == null) {
      return null;
    }
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      return PlaybackState.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<PlaybackState> _loadOrDefault() async {
    return await load() ?? PlaybackState();
  }

  Future<void> _persist(PlaybackState state) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(state.toJson());
    await prefs.setString(_key, json);
  }

  Future<void> save(PlaybackState state) => _persist(state);

  Future<void> update(PlaybackState Function(PlaybackState) transform) async {
    final current = await _loadOrDefault();
    final updated = transform(current);
    await _persist(updated);
  }

  Future<void> savePlaybackSnapshot({
    JellyfinTrack? currentTrack,
    Duration? position,
    List<JellyfinTrack>? queue,
    int? currentQueueIndex,
    bool? isPlaying,
    String? repeatMode,
    bool? shuffleEnabled,
    double? volume,
  }) async {
    await update((state) {
      final updatedQueueIds =
          queue != null ? queue.map((t) => t.id).toList() : state.queueIds;
      final updatedSnapshot = queue != null
          ? queue.map((t) => t.toStorageJson()).toList()
          : state.queueSnapshot;
      return state.copyWith(
        currentTrackId: currentTrack?.id ?? state.currentTrackId,
        currentTrackName: currentTrack?.name ?? state.currentTrackName,
        currentAlbumId: currentTrack?.albumId ?? state.currentAlbumId,
        currentAlbumName: currentTrack?.album ?? state.currentAlbumName,
        positionMs: position != null ? position.inMilliseconds : state.positionMs,
        isPlaying: isPlaying ?? state.isPlaying,
        queueIds: updatedQueueIds,
        queueSnapshot: updatedSnapshot,
        currentQueueIndex: currentQueueIndex ?? state.currentQueueIndex,
        repeatMode: repeatMode ?? state.repeatMode,
        shuffleEnabled: shuffleEnabled ?? state.shuffleEnabled,
        volume: volume ?? state.volume,
      );
    });
  }

  Future<void> saveUiState({
    int? libraryTabIndex,
    Map<String, double>? scrollOffsets,
    bool? showVolumeBar,
  }) async {
    await update((state) {
      final mergedOffsets = Map<String, double>.from(state.scrollOffsets);
      if (scrollOffsets != null) {
        mergedOffsets.addAll(scrollOffsets);
      }
      return state.copyWith(
        libraryTabIndex: libraryTabIndex ?? state.libraryTabIndex,
        scrollOffsets: scrollOffsets != null ? mergedOffsets : state.scrollOffsets,
        showVolumeBar: showVolumeBar ?? state.showVolumeBar,
      );
    });
  }

  Future<void> clearPlaybackData() async {
    await update((state) => state.clearPlayback());
  }
}
