class JellyfinPlaylist {
  JellyfinPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    this.primaryImageTag,
  });

  final String id;
  final String name;
  final int trackCount;
  final String? primaryImageTag;

  factory JellyfinPlaylist.fromJson(Map<String, dynamic> json) {
    return JellyfinPlaylist(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      trackCount: json['ChildCount'] as int? ??
          json['SongCount'] as int? ??
          json['TotalRecordCount'] as int? ??
          json['ItemCount'] as int? ??
          0,
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      'ChildCount': trackCount,
      'ImageTags': primaryImageTag != null ? {'Primary': primaryImageTag} : null,
    };
  }
}
