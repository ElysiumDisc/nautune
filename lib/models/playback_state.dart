class PlaybackState {
  PlaybackState({
    this.currentTrackId,
    this.currentTrackName,
    this.currentAlbumId,
    this.currentAlbumName,
    this.positionMs = 0,
    this.isPlaying = false,
    this.queueIds = const [],
    this.currentQueueIndex = 0,
  });

  final String? currentTrackId;
  final String? currentTrackName;
  final String? currentAlbumId;
  final String? currentAlbumName;
  final int positionMs;
  final bool isPlaying;
  final List<String> queueIds;
  final int currentQueueIndex;

  bool get hasTrack => currentTrackId != null;

  PlaybackState copyWith({
    String? currentTrackId,
    String? currentTrackName,
    String? currentAlbumId,
    String? currentAlbumName,
    int? positionMs,
    bool? isPlaying,
    List<String>? queueIds,
    int? currentQueueIndex,
  }) {
    return PlaybackState(
      currentTrackId: currentTrackId ?? this.currentTrackId,
      currentTrackName: currentTrackName ?? this.currentTrackName,
      currentAlbumId: currentAlbumId ?? this.currentAlbumId,
      currentAlbumName: currentAlbumName ?? this.currentAlbumName,
      positionMs: positionMs ?? this.positionMs,
      isPlaying: isPlaying ?? this.isPlaying,
      queueIds: queueIds ?? this.queueIds,
      currentQueueIndex: currentQueueIndex ?? this.currentQueueIndex,
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
      'currentQueueIndex': currentQueueIndex,
    };
  }

  factory PlaybackState.fromJson(Map<String, dynamic> json) {
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
      currentQueueIndex: json['currentQueueIndex'] as int? ?? 0,
    );
  }

  PlaybackState clear() {
    return PlaybackState();
  }
}
