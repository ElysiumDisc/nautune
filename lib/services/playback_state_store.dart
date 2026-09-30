import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_track.dart';
import '../models/appearance.dart';
import '../models/now_playing_layout.dart';
import '../models/replay_gain_mode.dart';
import '../models/transcode_codec.dart';
import '../models/playback_state.dart';
import '../models/visualizer_type.dart';
export '../models/playback_state.dart' show StreamingQuality, StreamingQualityExtension;
export '../models/visualizer_type.dart' show VisualizerType, VisualizerTypeExtension, VisualizerPosition, VisualizerPositionExtension;
export '../models/now_playing_layout.dart' show NowPlayingLayout, NowPlayingLayoutExtension;

/// Where [PlaybackStateStore] keeps its data (Hive in the app; a map in
/// tests).
abstract class PlaybackStateBackend {
  Future<Object?> read(String key);

  /// Write all [entries] in one operation and make them durable.
  Future<void> write(Map<String, Object?> entries);
}

class _HivePlaybackStateBackend implements PlaybackStateBackend {
  static const _boxName = 'nautune_playback';

  Box? _cachedBox;

  Future<Box> _box() async {
    final cached = _cachedBox;
    if (cached != null && cached.isOpen) return cached;
    return _cachedBox = await Hive.openBox(_boxName);
  }

  @override
  Future<Object?> read(String key) async => (await _box()).get(key);

  @override
  Future<void> write(Map<String, Object?> entries) async {
    const maxRetries = 3;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final box = await _box();
        await box.putAll(entries);
        // iOS may terminate the app shortly after it goes to the background.
        await box.flush();
        return;
      } catch (e) {
        debugPrint('Hive persist attempt ${attempt + 1} failed: $e');
        if (attempt == maxRetries - 1) rethrow;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}

/// Persisted playback state (queue, position, settings).
///
/// All instances share one in-memory copy of the state: reads are served
/// from memory, and changes are written to disk coalesced (at most one write
/// per [writeDelay]) and when the app leaves the foreground, instead of a
/// full read-modify-write with a disk flush per change. The queue lives under
/// its own key, so saving a setting or a position doesn't re-encode it.
/// Call [flush] to force pending changes to disk.
class PlaybackStateStore {
  PlaybackStateStore() : _core = _sharedCore;

  /// A store with its own state and [backend] (tests).
  @visibleForTesting
  PlaybackStateStore.withBackend(
    PlaybackStateBackend backend, {
    Duration writeDelay = const Duration(milliseconds: 500),
  }) : _core = _StoreCore(backend, writeDelay);

  static final _StoreCore _sharedCore = _StoreCore(
    _HivePlaybackStateBackend(),
    const Duration(milliseconds: 500),
  );

  final _StoreCore _core;

  /// Load the stored state early for faster first access.
  Future<void> initialize() => _core.ensureLoaded();

  /// The stored state, or null if nothing was ever saved.
  Future<PlaybackState?> load() => _core.load();

  /// Replace the whole state.
  Future<void> save(PlaybackState state) =>
      _core.mutate((_) => state, queueReplaced: true);

  /// Change the state with [transform] (applied in call order).
  Future<void> update(PlaybackState Function(PlaybackState) transform) =>
      // queueReplaced: [transform] sees (and may change) the full queue.
      _core.mutate(transform, queueReplaced: true);

  /// Write pending changes now (app going to the background, logout).
  Future<void> flush() => _core.flush();

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
  }) {
    // The queue snapshot (one JSON map per track) is built lazily, when it is
    // written or read, not on every call.
    return _core.mutate(
      (state) => state.copyWith(
        currentTrackId: currentTrack?.id ?? state.currentTrackId,
        currentTrackName: currentTrack?.name ?? state.currentTrackName,
        currentAlbumId: currentTrack?.albumId ?? state.currentAlbumId,
        currentAlbumName: currentTrack?.album ?? state.currentAlbumName,
        positionMs: position != null ? position.inMilliseconds : state.positionMs,
        isPlaying: isPlaying ?? state.isPlaying,
        currentQueueIndex: currentQueueIndex ?? state.currentQueueIndex,
        repeatMode: repeatMode ?? state.repeatMode,
        shuffleEnabled: shuffleEnabled ?? state.shuffleEnabled,
        volume: volume ?? state.volume,
        gaplessPlaybackEnabled: gaplessPlaybackEnabled ?? state.gaplessPlaybackEnabled,
      ),
      queue: queue,
    );
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
    VisualizerType? visualizerType,
    VisualizerPosition? visualizerPosition,
    int? preCacheTrackCount,
    bool? wifiOnlyCaching,
    List<double>? equalizerGains,
    bool? equalizerEnabled,
    double? playbackSpeed,
    bool? remoteControlEnabled,
    bool? smartShuffleEnabled,
    String? playlistSort,
    String? favoritesSort,
    bool? artworkTintEnabled,
    bool? frostedBlurEnabled,
    AccentSource? accentSource,
    CornerStyle? cornerStyle,
    AppearanceMode? appearanceMode,
    TranscodeCodec? transcodeCodec,
    double? replayGainPreampDb,
    ReplayGainMode? replayGainMode,
    bool? isOfflineMode,
    bool? submarineModeEnabled,
    Map<String, dynamic>? batterySaverSnapshot,
    int? gridSize,
    bool? useListMode,
    NowPlayingLayout? nowPlayingLayout,
    List<int>? navTabOrder,
  }) {
    return _core.mutate((state) {
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
        visualizerType: visualizerType ?? state.visualizerType,
        visualizerPosition: visualizerPosition ?? state.visualizerPosition,
        preCacheTrackCount: preCacheTrackCount ?? state.preCacheTrackCount,
        wifiOnlyCaching: wifiOnlyCaching ?? state.wifiOnlyCaching,
        equalizerGains: equalizerGains ?? state.equalizerGains,
        equalizerEnabled: equalizerEnabled ?? state.equalizerEnabled,
        playbackSpeed: playbackSpeed ?? state.playbackSpeed,
        remoteControlEnabled: remoteControlEnabled ?? state.remoteControlEnabled,
        smartShuffleEnabled: smartShuffleEnabled ?? state.smartShuffleEnabled,
        playlistSort: playlistSort ?? state.playlistSort,
        favoritesSort: favoritesSort ?? state.favoritesSort,
        artworkTintEnabled: artworkTintEnabled ?? state.artworkTintEnabled,
        frostedBlurEnabled: frostedBlurEnabled ?? state.frostedBlurEnabled,
        accentSource: accentSource ?? state.accentSource,
        cornerStyle: cornerStyle ?? state.cornerStyle,
        appearanceMode: appearanceMode ?? state.appearanceMode,
        transcodeCodec: transcodeCodec ?? state.transcodeCodec,
        replayGainPreampDb: replayGainPreampDb ?? state.replayGainPreampDb,
        replayGainMode: replayGainMode ?? state.replayGainMode,
        isOfflineMode: isOfflineMode ?? state.isOfflineMode,
        submarineModeEnabled: submarineModeEnabled ?? state.submarineModeEnabled,
        batterySaverSnapshot: batterySaverSnapshot ?? state.batterySaverSnapshot,
        gridSize: gridSize ?? state.gridSize,
        useListMode: useListMode ?? state.useListMode,
        nowPlayingLayout: nowPlayingLayout ?? state.nowPlayingLayout,
        navTabOrder: navTabOrder ?? state.navTabOrder,
      );
    });
  }

  /// Clear the queue and current track (settings are kept) and write it to
  /// disk right away: the queue snapshot carries server URLs and tokens.
  Future<void> clearPlaybackData() async {
    await _core.mutate((state) => state.clearPlayback(), queueReplaced: true);
    await _core.flush();
  }
}

/// One change to the state, kept until the stored state has been read (see
/// [_StoreCore.mutate]).
class _Mutation {
  _Mutation(this.transform, this.queue, this.queueReplaced);

  final PlaybackState Function(PlaybackState) transform;
  final List<JellyfinTrack>? queue;
  final bool queueReplaced;
}

class _StoreCore {
  _StoreCore(this.backend, this.writeDelay);

  static const stateKey = 'state';
  static const queueKey = 'queue';

  final PlaybackStateBackend backend;
  final Duration writeDelay;

  PlaybackState? _state;
  bool _hasStored = false;
  Future<void>? _loadFuture;

  /// The stored state has been read. Until then nothing is written (it
  /// would replace the stored settings with defaults): changes are applied
  /// in memory and kept in [_unloadedChanges], to be replayed on top of the
  /// stored state once a read succeeds.
  bool _loaded = false;
  final List<_Mutation> _unloadedChanges = [];
  Timer? _loadRetryTimer;

  /// Latest queue, not yet converted to [PlaybackState.queueSnapshot].
  List<JellyfinTrack>? _pendingQueue;
  bool _stateDirty = false;
  bool _queueDirty = false;
  Timer? _writeTimer;
  Future<void> _writeChain = Future<void>.value();
  _FlushOnBackground? _lifecycleHook;

  /// Read the stored state (again, if an earlier read failed).
  Future<void> ensureLoaded() => _loadFuture ??= _load();

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return null;
  }

  Future<void> _load() async {
    final Object? rawState;
    final Object? rawQueue;
    try {
      rawState = await backend.read(stateKey);
      rawQueue = await backend.read(queueKey);
    } catch (e, stack) {
      // Couldn't read (e.g. the box failed to open): try again on the next
      // access, and write nothing meanwhile.
      debugPrint('Reading playback state failed (will retry): $e\n$stack');
      _loadFuture = null;
      if (_unloadedChanges.isNotEmpty) _scheduleLoadRetry();
      return;
    }

    // Read fine but unparseable data can't get better by retrying: start
    // from defaults.
    PlaybackState? state;
    var migrateQueue = false;
    try {
      final data = _decode(rawState);
      state = data == null ? null : PlaybackState.fromJson(data);
    } catch (e, stack) {
      debugPrint('Stored playback state is unreadable: $e\n$stack');
    }
    try {
      final queue = _decode(rawQueue);
      if (queue != null) {
        state = (state ?? PlaybackState()).copyWith(
          queueIds: [for (final id in (queue['ids'] as List? ?? const [])) id as String],
          queueSnapshot: [
            for (final t in (queue['snapshot'] as List? ?? const []))
              Map<String, dynamic>.from(t as Map),
          ],
        );
      } else if (state != null &&
          (state.queueIds.isNotEmpty || state.queueSnapshot.isNotEmpty)) {
        // Saved by an older version (queue inside the state): move it to its
        // own key with the next write.
        migrateQueue = true;
      }
    } catch (e, stack) {
      debugPrint('Stored queue is unreadable: $e\n$stack');
    }

    _loaded = true;
    _loadRetryTimer?.cancel();
    _loadRetryTimer = null;
    _state = state;
    _hasStored = state != null;
    _pendingQueue = null;
    _stateDirty = false;
    _queueDirty = migrateQueue;
    // Changes made before the read succeeded go on top of the stored state.
    final changes = List<_Mutation>.of(_unloadedChanges);
    _unloadedChanges.clear();
    for (final change in changes) {
      _apply(change);
    }
    if (changes.isNotEmpty) _scheduleWrite();
  }

  void _scheduleLoadRetry() {
    _loadRetryTimer ??= Timer(writeDelay * 4, () {
      _loadRetryTimer = null;
      if (!_loaded) unawaited(ensureLoaded());
    });
  }

  Future<PlaybackState?> load() async {
    await ensureLoaded();
    materializeQueue();
    return _hasStored ? _state : null;
  }

  /// Fold [_pendingQueue] into the state's queue fields.
  void materializeQueue() {
    final queue = _pendingQueue;
    if (queue == null) return;
    _pendingQueue = null;
    _state = (_state ?? PlaybackState()).copyWith(
      queueIds: [for (final t in queue) t.id],
      queueSnapshot: [for (final t in queue) t.toStorageJson()],
    );
  }

  /// Apply [transform] to the in-memory state and schedule a write. With
  /// [queue] the stored queue becomes that list; [queueReplaced] means
  /// [transform] sees the full queue and itself sets the queue fields.
  Future<void> mutate(
    PlaybackState Function(PlaybackState) transform, {
    List<JellyfinTrack>? queue,
    bool queueReplaced = false,
  }) async {
    await ensureLoaded();
    final change = _Mutation(
      transform,
      queue == null ? null : List<JellyfinTrack>.of(queue),
      queueReplaced,
    );
    _apply(change);
    if (_loaded) {
      _scheduleWrite();
    } else {
      _unloadedChanges.add(change);
      _scheduleLoadRetry();
    }
  }

  void _apply(_Mutation change) {
    final queue = change.queue;
    if (queue != null) {
      _pendingQueue = queue;
      _queueDirty = true;
    } else if (change.queueReplaced) {
      materializeQueue();
      _queueDirty = true;
    }
    _state = change.transform(_state ?? PlaybackState());
    _hasStored = true;
    _stateDirty = true;
  }

  void _scheduleWrite() {
    _hookLifecycle();
    _writeTimer ??= Timer(writeDelay, () {
      _writeTimer = null;
      unawaited(_enqueueWrite());
    });
  }

  Future<void> flush() async {
    await ensureLoaded();
    _writeTimer?.cancel();
    _writeTimer = null;
    await _enqueueWrite();
  }

  /// Writes run one after another (no overlap), each writing whatever is
  /// pending when it starts.
  Future<void> _enqueueWrite() {
    final next = _writeChain.then((_) => _writeNow());
    _writeChain = next.catchError((Object e) {
      debugPrint('Playback state write failed: $e');
    });
    return _writeChain;
  }

  Future<void> _writeNow() async {
    if (!_loaded || (!_stateDirty && !_queueDirty)) return;
    materializeQueue();
    final state = _state;
    if (state == null) return;
    final writeQueue = _queueDirty;
    _stateDirty = false;
    _queueDirty = false;
    final stateJson = state.toJson()
      ..remove('queueIds')
      ..remove('queueSnapshot');
    final entries = <String, Object?>{
      if (writeQueue)
        queueKey: <String, Object?>{
          'ids': state.queueIds,
          'snapshot': state.queueSnapshot,
        },
      stateKey: stateJson,
    };
    try {
      await backend.write(entries);
    } catch (e) {
      // Keep it pending for the next write.
      _stateDirty = true;
      if (writeQueue) _queueDirty = true;
      rethrow;
    }
  }

  void _hookLifecycle() {
    if (_lifecycleHook != null) return;
    try {
      final hook = _FlushOnBackground(this);
      WidgetsBinding.instance.addObserver(hook);
      _lifecycleHook = hook;
    } catch (_) {
      // No binding (plain unit tests): writes still happen on the timer.
    }
  }
}

/// Writes pending playback state as soon as the app stops being active
/// (iOS may suspend or kill it from there).
class _FlushOnBackground with WidgetsBindingObserver {
  _FlushOnBackground(this._core);

  final _StoreCore _core;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_core.flush());
  }
}
