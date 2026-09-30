class JellyfinPlaylist {
  JellyfinPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    this.primaryImageTag,
    this.dateCreated,
  });

  final String id;
  final String name;
  final int trackCount;
  final String? primaryImageTag;

  /// When the server created the playlist (`DateCreated`), when known.
  final DateTime? dateCreated;

  factory JellyfinPlaylist.fromJson(Map<String, dynamic> json) {
    return JellyfinPlaylist(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      trackCount: json['ChildCount'] as int? ??
          json['SongCount'] as int? ??
          json['TotalRecordCount'] as int? ??
          json['ItemCount'] as int? ??
          0,
      // Hive returns nested maps as Map<dynamic, dynamic>: don't cast to
      // Map<String, dynamic> or cached playlists fail to load after restart.
      primaryImageTag: _primaryTag(json['ImageTags']),
      dateCreated: json['DateCreated'] is String
          ? DateTime.tryParse(json['DateCreated'] as String)
          : null,
    );
  }

  static String? _primaryTag(Object? tags) {
    if (tags is! Map) return null;
    final primary = tags['Primary'];
    return primary is String ? primary : null;
  }

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      'ChildCount': trackCount,
      'ImageTags': primaryImageTag != null ? {'Primary': primaryImageTag} : null,
      if (dateCreated != null) 'DateCreated': dateCreated!.toIso8601String(),
    };
  }
}
