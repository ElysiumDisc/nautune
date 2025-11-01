class JellyfinTrack {
  JellyfinTrack({
    required this.id,
    required this.name,
    required this.album,
    required this.artists,
    this.runTimeTicks,
    this.primaryImageTag,
    this.serverUrl,
    this.token,
    this.userId,
  });

  final String id;
  final String name;
  final String? album;
  final List<String> artists;
  final int? runTimeTicks;
  final String? primaryImageTag;
  final String? serverUrl;
  final String? token;
  final String? userId;

  factory JellyfinTrack.fromJson(Map<String, dynamic> json, {String? serverUrl, String? token, String? userId}) {
    return JellyfinTrack(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      album: json['Album'] as String?,
      artists: (json['Artists'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      runTimeTicks: json['RunTimeTicks'] as int?,
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
      serverUrl: serverUrl,
      token: token,
      userId: userId,
    );
  }

  String get displayArtist {
    if (artists.isEmpty) {
      return 'Unknown Artist';
    }
    if (artists.length == 1) {
      return artists.first;
    }
    return '${artists.first} & ${artists.length - 1} more';
  }

  Duration? get duration {
    final ticks = runTimeTicks;
    if (ticks == null) {
      return null;
    }
    return Duration(microseconds: ticks ~/ 10);
  }

  String get streamUrl {
    if (serverUrl == null || token == null) {
      throw Exception('JellyfinTrack missing serverUrl or token for streaming');
    }
    // Use direct streaming without transcoding for better compatibility
    return '$serverUrl/Items/$id/Download?api_key=$token';
  }
}
