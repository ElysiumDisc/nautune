class JellyfinAlbum {
  JellyfinAlbum({
    required this.id,
    required this.name,
    required this.artists,
    this.productionYear,
    this.primaryImageTag,
    this.isFavorite = false,
  });

  final String id;
  final String name;
  final List<String> artists;
  final int? productionYear;
  final String? primaryImageTag;
  final bool isFavorite;

  factory JellyfinAlbum.fromJson(Map<String, dynamic> json) {
    return JellyfinAlbum(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      artists: (json['AlbumArtists'] as List<dynamic>?)
              ?.map((artist) =>
                  (artist as Map<String, dynamic>)['Name'] as String? ?? '')
              .where((name) => name.isNotEmpty)
              .toList() ??
          (json['Artists'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      productionYear: json['ProductionYear'] as int?,
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
      isFavorite: (json['UserData'] as Map<String, dynamic>?)?['IsFavorite'] as bool? ?? false,
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
}
