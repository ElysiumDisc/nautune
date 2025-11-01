class JellyfinTrack {
  JellyfinTrack({
    required this.id,
    required this.name,
    required this.album,
    required this.artists,
    this.runTimeTicks,
    this.primaryImageTag,
  });

  final String id;
  final String name;
  final String? album;
  final List<String> artists;
  final int? runTimeTicks;
  final String? primaryImageTag;

  factory JellyfinTrack.fromJson(Map<String, dynamic> json) {
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
}
