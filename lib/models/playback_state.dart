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
    };
  }

  factory PlaybackState.fromJson(Map<String, dynamic> json) {
    final rawOffsets = json['scrollOffsets'] as Map<String, dynamic>? ?? const {};
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
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      currentQueueIndex: json['currentQueueIndex'] as int? ?? 0,
      repeatMode: json['repeatMode'] as String? ?? 'off',
      shuffleEnabled: json['shuffleEnabled'] as bool? ?? false,
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      scrollOffsets: rawOffsets.map(
        (key, value) => MapEntry(key, (value as num).toDouble()),
      ),
      libraryTabIndex: json['libraryTabIndex'] as int? ?? 0,
      showVolumeBar: json['showVolumeBar'] as bool? ?? true,
      crossfadeEnabled: json['crossfadeEnabled'] as bool? ?? false,
      crossfadeDurationSeconds: json['crossfadeDurationSeconds'] as int? ?? 3,
      infiniteRadioEnabled: json['infiniteRadioEnabled'] as bool? ?? false,
      cacheTtlMinutes: json['cacheTtlMinutes'] as int? ?? 2,
    );
  }

  PlaybackState clearPlayback() {
    return copyWith(
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
    );
  }

  List<JellyfinTrack> toQueueTracks() {
    return queueSnapshot
        .map(JellyfinTrack.fromStorageJson)
        .toList(growable: false);
  }
}
