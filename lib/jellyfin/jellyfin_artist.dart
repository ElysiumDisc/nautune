class JellyfinArtist {
  JellyfinArtist({
    required this.id,
    required this.name,
    this.primaryImageTag,
    this.overview,
    this.genres,
    this.albumCount,
    this.songCount,
  });

  final String id;
  final String name;
  final String? primaryImageTag;
  final String? overview;
  final List<String>? genres;
  final int? albumCount;
  final int? songCount;

  factory JellyfinArtist.fromJson(Map<String, dynamic> json) {
    return JellyfinArtist(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
      overview: json['Overview'] as String?,
      genres: (json['Genres'] as List<dynamic>?)
          ?.map((g) => g.toString())
          .toList(),
      albumCount: json['ChildCount'] as int?,
      songCount: json['SongCount'] as int?,
    );
  }
}
