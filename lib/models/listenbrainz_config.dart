/// Configuration for ListenBrainz integration
class ListenBrainzConfig {
  /// ListenBrainz username
  final String username;

  /// User authentication token from ListenBrainz
  final String token;

  /// Whether scrobbling is enabled
  final bool scrobblingEnabled;

  /// Timestamp of last successful scrobble
  final DateTime? lastScrobbleTime;

  /// Number of tracks successfully scrobbled
  final int totalScrobbles;

  ListenBrainzConfig({
    required this.username,
    required this.token,
    this.scrobblingEnabled = true,
    this.lastScrobbleTime,
    this.totalScrobbles = 0,
  });

  /// Create a copy with updated values
  ListenBrainzConfig copyWith({
    String? username,
    String? token,
    bool? scrobblingEnabled,
    DateTime? lastScrobbleTime,
    int? totalScrobbles,
  }) {
    return ListenBrainzConfig(
      username: username ?? this.username,
      token: token ?? this.token,
      scrobblingEnabled: scrobblingEnabled ?? this.scrobblingEnabled,
      lastScrobbleTime: lastScrobbleTime ?? this.lastScrobbleTime,
      totalScrobbles: totalScrobbles ?? this.totalScrobbles,
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() => {
    'username': username,
    'token': token,
    'scrobblingEnabled': scrobblingEnabled,
    'lastScrobbleTime': lastScrobbleTime?.toIso8601String(),
    'totalScrobbles': totalScrobbles,
  };

  /// Create from JSON
  factory ListenBrainzConfig.fromJson(Map<String, dynamic> json) {
    return ListenBrainzConfig(
      username: json['username'] as String,
      token: json['token'] as String,
      scrobblingEnabled: json['scrobblingEnabled'] as bool? ?? true,
      lastScrobbleTime: json['lastScrobbleTime'] != null
          ? DateTime.tryParse(json['lastScrobbleTime'] as String)
          : null,
      totalScrobbles: json['totalScrobbles'] as int? ?? 0,
    );
  }
}

/// A recommendation from ListenBrainz
class ListenBrainzRecommendation {
  /// MusicBrainz Recording ID
  final String recordingMbid;

  /// Track name (may be null if not resolved)
  final String? trackName;

  /// Artist name (may be null if not resolved)
  final String? artistName;

  /// Album name (may be null if not resolved)
  final String? albumName;

  /// Recommendation score (0-1)
  final double score;

  /// Whether this track was matched to a Jellyfin library item
  final String? jellyfinTrackId;

  ListenBrainzRecommendation({
    required this.recordingMbid,
    this.trackName,
    this.artistName,
    this.albumName,
    required this.score,
    this.jellyfinTrackId,
  });

  /// Check if this recommendation is in the user's library
  bool get isInLibrary => jellyfinTrackId != null;

  /// Create a copy with Jellyfin match
  ListenBrainzRecommendation withJellyfinMatch(String trackId) {
    return ListenBrainzRecommendation(
      recordingMbid: recordingMbid,
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      score: score,
      jellyfinTrackId: trackId,
    );
  }

  /// Create from ListenBrainz API response
  factory ListenBrainzRecommendation.fromJson(Map<String, dynamic> json) {
    return ListenBrainzRecommendation(
      recordingMbid: json['recording_mbid'] as String,
      trackName: json['track_name'] as String?,
      artistName: json['artist_name'] as String?,
      albumName: json['album_name'] as String?,
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
