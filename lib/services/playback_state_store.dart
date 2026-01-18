import 'dart:async';
import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/playback_state.dart';
export '../models/playback_state.dart' show StreamingQuality, StreamingQualityExtension;

class PlaybackStateStore {
  static const _boxName = 'nautune_playback';
  static const _key = 'state';

  Completer<void>? _activeLock;
  Box? _cachedBox;

  /// Get or open the Hive box, keeping a cached reference to avoid repeated opens
  Future<Box> _box() async {
    if (_cachedBox != null && _cachedBox!.isOpen) {
      return _cachedBox!;
    }
    _cachedBox = await Hive.openBox(_boxName);
    return _cachedBox!;
  }

  /// Initialize the box early for faster first access
  Future<void> initialize() async {
    await _box();
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
    } catch (e, stack) {
      // ignore: avoid_print
      print('Error loading playback state: $e\n$stack');
      return null;
    }
  }

  Future<PlaybackState> _loadOrDefault() async {
    return await load() ?? PlaybackState();
  }

  Future<void> _persist(PlaybackState state) async {
    final box = await _box();
    await box.put(_key, state.toJson());
    // Flush to ensure data is written to disk immediately
    // Critical for iOS where app may be terminated shortly after going to background
    await box.flush();
  }

  Future<void> save(PlaybackState state) => _persist(state);

  Future<void> update(PlaybackState Function(PlaybackState) transform) async {
    // Simple mutex to prevent race conditions during read-modify-write cycles
    while (_activeLock != null) {
      await _activeLock!.future;
    }
    final lock = Completer<void>();
    _activeLock = lock;

    try {
      final current = await _loadOrDefault();
      final updated = transform(current);
      await _persist(updated);
    } finally {
      _activeLock = null;
      lock.complete();
    }
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
    bool? gaplessPlaybackEnabled,
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
        gaplessPlaybackEnabled: gaplessPlaybackEnabled ?? state.gaplessPlaybackEnabled,
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
    bool? gaplessPlaybackEnabled,
    int? maxConcurrentDownloads,
    bool? wifiOnlyDownloads,
    int? storageLimitMB,
    bool? autoCleanupEnabled,
    int? autoCleanupDays,
    StreamingQuality? streamingQuality,
    String? themePaletteId,
    int? customPrimaryColor,
    int? customSecondaryColor,
    int? customAccentColor,
    bool? customThemeIsLight,
    bool? visualizerEnabled,
    int? preCacheTrackCount,
    bool? wifiOnlyCaching,
    bool? isOfflineMode,
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
        gaplessPlaybackEnabled: gaplessPlaybackEnabled ?? state.gaplessPlaybackEnabled,
        maxConcurrentDownloads: maxConcurrentDownloads ?? state.maxConcurrentDownloads,
        wifiOnlyDownloads: wifiOnlyDownloads ?? state.wifiOnlyDownloads,
        storageLimitMB: storageLimitMB ?? state.storageLimitMB,
        autoCleanupEnabled: autoCleanupEnabled ?? state.autoCleanupEnabled,
        autoCleanupDays: autoCleanupDays ?? state.autoCleanupDays,
        streamingQuality: streamingQuality ?? state.streamingQuality,
        themePaletteId: themePaletteId ?? state.themePaletteId,
        customPrimaryColor: customPrimaryColor ?? state.customPrimaryColor,
        customSecondaryColor: customSecondaryColor ?? state.customSecondaryColor,
        customAccentColor: customAccentColor ?? state.customAccentColor,
        customThemeIsLight: customThemeIsLight ?? state.customThemeIsLight,
        visualizerEnabled: visualizerEnabled ?? state.visualizerEnabled,
        preCacheTrackCount: preCacheTrackCount ?? state.preCacheTrackCount,
        wifiOnlyCaching: wifiOnlyCaching ?? state.wifiOnlyCaching,
        isOfflineMode: isOfflineMode ?? state.isOfflineMode,
      );
    });
  }

  Future<void> clearPlaybackData() async {
    await update((state) => state.clearPlayback());
  }
}
