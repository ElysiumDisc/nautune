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

/// Source of a ListenBrainz recommendation
enum RecommendationSource { cfRecommendation, lbRadio, freshRelease }

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

  /// MusicBrainz Release ID (for fetching album art from Cover Art Archive)
  final String? releaseMbid;

  /// Recommendation score (0-1)
  final double score;

  /// Whether this track was matched to a Jellyfin library item
  final String? jellyfinTrackId;

  /// Source of this recommendation
  final RecommendationSource source;

  ListenBrainzRecommendation({
    required this.recordingMbid,
    this.trackName,
    this.artistName,
    this.albumName,
    this.releaseMbid,
    required this.score,
    this.jellyfinTrackId,
    this.source = RecommendationSource.cfRecommendation,
  });

  /// Check if this recommendation is in the user's library
  bool get isInLibrary => jellyfinTrackId != null;

  /// Get Cover Art Archive URL for album artwork (250px)
  String? get coverArtUrl => releaseMbid != null
      ? 'https://coverartarchive.org/release/$releaseMbid/front-250'
      : null;

  /// Create a copy with Jellyfin match
  ListenBrainzRecommendation withJellyfinMatch(String trackId) {
    return ListenBrainzRecommendation(
      recordingMbid: recordingMbid,
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      releaseMbid: releaseMbid,
      score: score,
      jellyfinTrackId: trackId,
      source: source,
    );
  }

  /// Create from ListenBrainz API response
  factory ListenBrainzRecommendation.fromJson(Map<String, dynamic> json) {
    return ListenBrainzRecommendation(
      recordingMbid: json['recording_mbid'] as String,
      trackName: json['track_name'] as String?,
      artistName: json['artist_name'] as String?,
      albumName: json['album_name'] as String?,
      releaseMbid: json['release_mbid'] as String?,
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// A popular track from ListenBrainz global popularity data
class PopularTrack {
  final String recordingMbid;
  final String recordingName;
  final String? artistName;
  final List<String>? artistMbids;
  final String? releaseMbid;
  final String? releaseName;
  final int totalListenCount;
  final int totalUserCount;
  final int? lengthMs;
  final int? caaId;

  PopularTrack({
    required this.recordingMbid,
    required this.recordingName,
    this.artistName,
    this.artistMbids,
    this.releaseMbid,
    this.releaseName,
    required this.totalListenCount,
    required this.totalUserCount,
    this.lengthMs,
    this.caaId,
  });

  /// Get cover art URL from Cover Art Archive
  String? get coverArtUrl => releaseMbid != null
      ? 'https://coverartarchive.org/release/$releaseMbid/front-250'
      : null;

  Duration? get duration =>
      lengthMs != null ? Duration(milliseconds: lengthMs!) : null;

  factory PopularTrack.fromJson(Map<String, dynamic> json) {
    final artistMbids = json['artist_mbids'];
    List<String>? artistMbidsList;
    if (artistMbids is List) {
      artistMbidsList = artistMbids.whereType<String>().toList();
    }

    return PopularTrack(
      recordingMbid: json['recording_mbid'] as String? ?? '',
      recordingName: json['recording_name'] as String? ?? '',
      artistName: json['artist_name'] as String?,
      artistMbids: artistMbidsList,
      releaseMbid: json['release_mbid'] as String?,
      releaseName: json['release_name'] as String?,
      totalListenCount: (json['total_listen_count'] as num?)?.toInt() ?? 0,
      totalUserCount: (json['total_user_count'] as num?)?.toInt() ?? 0,
      lengthMs: (json['length'] as num?)?.toInt(),
      caaId: (json['caa_id'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'recording_mbid': recordingMbid,
    'recording_name': recordingName,
    'artist_name': artistName,
    'artist_mbids': artistMbids,
    'release_mbid': releaseMbid,
    'release_name': releaseName,
    'total_listen_count': totalListenCount,
    'total_user_count': totalUserCount,
    'length': lengthMs,
    'caa_id': caaId,
  };
}

/// A fresh release from ListenBrainz (recent releases from artists the user listens to)
class FreshRelease {
  final String releaseMbid;
  final String releaseName;
  final String artistCreditName;
  final List<String> artistMbids;
  final String? releaseDate;
  final String? releaseGroupPrimaryType;
  final int? caaId;
  final String? caaReleaseMbid;

  FreshRelease({
    required this.releaseMbid,
    required this.releaseName,
    required this.artistCreditName,
    this.artistMbids = const [],
    this.releaseDate,
    this.releaseGroupPrimaryType,
    this.caaId,
    this.caaReleaseMbid,
  });

  /// Get cover art URL from Cover Art Archive
  String? get coverArtUrl {
    final mbid = caaReleaseMbid ?? releaseMbid;
    return 'https://coverartarchive.org/release/$mbid/front-250';
  }

  /// Convert to a ListenBrainzRecommendation for unified display
  ListenBrainzRecommendation toRecommendation() {
    return ListenBrainzRecommendation(
      recordingMbid: releaseMbid,
      trackName: null,
      artistName: artistCreditName,
      albumName: releaseName,
      releaseMbid: caaReleaseMbid ?? releaseMbid,
      score: 0.0,
      source: RecommendationSource.freshRelease,
    );
  }

  factory FreshRelease.fromJson(Map<String, dynamic> json) {
    final artistMbids = json['artist_mbids'];
    List<String> artistMbidsList = [];
    if (artistMbids is List) {
      artistMbidsList = artistMbids.whereType<String>().toList();
    }

    return FreshRelease(
      releaseMbid: json['release_mbid'] as String? ?? '',
      releaseName: json['release_name'] as String? ?? '',
      artistCreditName: json['artist_credit_name'] as String? ?? '',
      artistMbids: artistMbidsList,
      releaseDate: json['release_date'] as String?,
      releaseGroupPrimaryType: json['release_group_primary_type'] as String?,
      caaId: (json['caa_id'] as num?)?.toInt(),
      caaReleaseMbid: json['caa_release_mbid'] as String?,
    );
  }
}
