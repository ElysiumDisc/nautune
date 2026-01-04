import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/playback_state.dart';

class PlaybackStateStore {
  static const _boxName = 'nautune_playback';
  static const _key = 'state';

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<PlaybackState?> load() async {
    final box = await _box();
    final raw = box.get(_key);
    if (raw == null) {
      return null;
    }
    try {
      final Map<String, dynamic> data;
      if (raw is Map) {
        data = Map<String, dynamic>.from(raw);
      } else if (raw is String) {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } else {
        return null;
      }
      return PlaybackState.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<PlaybackState> _loadOrDefault() async {
    return await load() ?? PlaybackState();
  }

  Future<void> _persist(PlaybackState state) async {
    final box = await _box();
    await box.put(_key, state.toJson());
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
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    bool? infiniteRadioEnabled,
    int? cacheTtlMinutes,
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
        crossfadeEnabled: crossfadeEnabled ?? state.crossfadeEnabled,
        crossfadeDurationSeconds: crossfadeDurationSeconds ?? state.crossfadeDurationSeconds,
        infiniteRadioEnabled: infiniteRadioEnabled ?? state.infiniteRadioEnabled,
        cacheTtlMinutes: cacheTtlMinutes ?? state.cacheTtlMinutes,
      );
    });
  }

  Future<void> clearPlaybackData() async {
    await update((state) => state.clearPlayback());
  }
}
