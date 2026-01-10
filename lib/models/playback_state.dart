import '../jellyfin/jellyfin_track.dart';

class PlaybackState {
  PlaybackState({
    this.currentTrackId,
    this.currentTrackName,
    this.currentAlbumId,
    this.currentAlbumName,
    this.positionMs = 0,
    this.isPlaying = false,
    this.queueIds = const [],
    this.queueSnapshot = const [],
    this.currentQueueIndex = 0,
    this.repeatMode = 'off',
    this.shuffleEnabled = false,
    this.volume = 1.0,
    this.scrollOffsets = const <String, double>{},
    this.libraryTabIndex = 0,
    this.showVolumeBar = true,
    this.crossfadeEnabled = false,
    this.crossfadeDurationSeconds = 3,
    this.infiniteRadioEnabled = false,
    this.cacheTtlMinutes = 2,
    this.gaplessPlaybackEnabled = true,
  });

  final String? currentTrackId;
  final String? currentTrackName;
  final String? currentAlbumId;
  final String? currentAlbumName;
  final int positionMs;
  final bool isPlaying;
  final List<String> queueIds;
  final List<Map<String, dynamic>> queueSnapshot;
  final int currentQueueIndex;
  final String repeatMode;
  final bool shuffleEnabled;
  final double volume;
  final Map<String, double> scrollOffsets;
  final int libraryTabIndex;
  final bool showVolumeBar;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final bool infiniteRadioEnabled;
  final int cacheTtlMinutes;
  final bool gaplessPlaybackEnabled;

  bool get hasTrack => currentTrackId != null;

  PlaybackState copyWith({
    String? currentTrackId,
    String? currentTrackName,
    String? currentAlbumId,
    String? currentAlbumName,
    int? positionMs,
    bool? isPlaying,
    List<String>? queueIds,
    List<Map<String, dynamic>>? queueSnapshot,
    int? currentQueueIndex,
    String? repeatMode,
    bool? shuffleEnabled,
    double? volume,
    Map<String, double>? scrollOffsets,
    int? libraryTabIndex,
    bool? showVolumeBar,
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    bool? infiniteRadioEnabled,
    int? cacheTtlMinutes,
    bool? gaplessPlaybackEnabled,
  }) {
    return PlaybackState(
      currentTrackId: currentTrackId ?? this.currentTrackId,
      currentTrackName: currentTrackName ?? this.currentTrackName,
      currentAlbumId: currentAlbumId ?? this.currentAlbumId,
      currentAlbumName: currentAlbumName ?? this.currentAlbumName,
      positionMs: positionMs ?? this.positionMs,
      isPlaying: isPlaying ?? this.isPlaying,
      queueIds: queueIds ?? this.queueIds,
      queueSnapshot: queueSnapshot ?? this.queueSnapshot,
      currentQueueIndex: currentQueueIndex ?? this.currentQueueIndex,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      volume: volume ?? this.volume,
      scrollOffsets: scrollOffsets ?? this.scrollOffsets,
      libraryTabIndex: libraryTabIndex ?? this.libraryTabIndex,
      showVolumeBar: showVolumeBar ?? this.showVolumeBar,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDurationSeconds: crossfadeDurationSeconds ?? this.crossfadeDurationSeconds,
      infiniteRadioEnabled: infiniteRadioEnabled ?? this.infiniteRadioEnabled,
      cacheTtlMinutes: cacheTtlMinutes ?? this.cacheTtlMinutes,
      gaplessPlaybackEnabled: gaplessPlaybackEnabled ?? this.gaplessPlaybackEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'currentTrackId': currentTrackId,
      'currentTrackName': currentTrackName,
      'currentAlbumId': currentAlbumId,
      'currentAlbumName': currentAlbumName,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
      'queueIds': queueIds,
      'queueSnapshot': queueSnapshot,
      'currentQueueIndex': currentQueueIndex,
      'repeatMode': repeatMode,
      'shuffleEnabled': shuffleEnabled,
      'volume': volume,
      'scrollOffsets': scrollOffsets,
      'libraryTabIndex': libraryTabIndex,
      'showVolumeBar': showVolumeBar,
      'crossfadeEnabled': crossfadeEnabled,
      'crossfadeDurationSeconds': crossfadeDurationSeconds,
      'infiniteRadioEnabled': infiniteRadioEnabled,
      'cacheTtlMinutes': cacheTtlMinutes,
      'gaplessPlaybackEnabled': gaplessPlaybackEnabled,
    };
  }

  factory PlaybackState.fromJson(Map<String, dynamic> json) {
    final rawOffsets = json['scrollOffsets'] as Map? ?? const {};
    return PlaybackState(
      currentTrackId: json['currentTrackId'] as String?,
      currentTrackName: json['currentTrackName'] as String?,
      currentAlbumId: json['currentAlbumId'] as String?,
      currentAlbumName: json['currentAlbumName'] as String?,
      positionMs: json['positionMs'] as int? ?? 0,
      isPlaying: json['isPlaying'] as bool? ?? false,
      queueIds: (json['queueIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      queueSnapshot: (json['queueSnapshot'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
      currentQueueIndex: json['currentQueueIndex'] as int? ?? 0,
      repeatMode: json['repeatMode'] as String? ?? 'off',
      shuffleEnabled: json['shuffleEnabled'] as bool? ?? false,
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      scrollOffsets: rawOffsets.entries.fold<Map<String, double>>({}, (map, entry) {
        if (entry.key is String && entry.value is num) {
          map[entry.key as String] = (entry.value as num).toDouble();
        }
        return map;
      }),
      libraryTabIndex: json['libraryTabIndex'] as int? ?? 0,
      showVolumeBar: json['showVolumeBar'] as bool? ?? true,
      crossfadeEnabled: json['crossfadeEnabled'] as bool? ?? false,
      crossfadeDurationSeconds: json['crossfadeDurationSeconds'] as int? ?? 3,
      infiniteRadioEnabled: json['infiniteRadioEnabled'] as bool? ?? false,
      cacheTtlMinutes: (json['cacheTtlMinutes'] as num?)?.toInt() ?? 2,
      gaplessPlaybackEnabled: json['gaplessPlaybackEnabled'] as bool? ?? true,
    );
  }

  /// Clears playback-related data while preserving UI settings.
  /// Returns a new PlaybackState with playback fields reset to defaults.
  PlaybackState clearPlayback() {
    // Cannot use copyWith because it uses ?? which won't set nullable fields to null
    return PlaybackState(
      currentTrackId: null,
      currentTrackName: null,
      currentAlbumId: null,
      currentAlbumName: null,
      positionMs: 0,
      isPlaying: false,
      queueIds: const [],
      queueSnapshot: const [],
      currentQueueIndex: 0,
      repeatMode: 'off',
      shuffleEnabled: false,
      volume: volume, // Preserve volume setting
      scrollOffsets: scrollOffsets, // Preserve UI settings
      libraryTabIndex: libraryTabIndex,
      showVolumeBar: showVolumeBar,
      crossfadeEnabled: crossfadeEnabled,
      crossfadeDurationSeconds: crossfadeDurationSeconds,
      infiniteRadioEnabled: infiniteRadioEnabled,
      cacheTtlMinutes: cacheTtlMinutes,
      gaplessPlaybackEnabled: gaplessPlaybackEnabled,
    );
  }

  List<JellyfinTrack> toQueueTracks() {
    return queueSnapshot
        .map(JellyfinTrack.fromStorageJson)
        .toList(growable: false);
  }
}
