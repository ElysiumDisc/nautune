class JellyfinAlbum {
  JellyfinAlbum({
    required this.id,
    required this.name,
    required this.artists,
    this.artistIds = const <String>[],
    this.productionYear,
    this.primaryImageTag,
    this.isFavorite = false,
    this.genres,
  });

  final String id;
  final String name;
  final List<String> artists;
  final List<String> artistIds;
  final int? productionYear;
  final String? primaryImageTag;
  final bool isFavorite;
  final List<String>? genres;

  factory JellyfinAlbum.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> extractArtistMaps(String key) {
      final raw = json[key];
      if (raw is List) {
        return raw.whereType<Map<String, dynamic>>().toList();
      }
      return const [];
    }

    final albumArtistMaps = extractArtistMaps('AlbumArtists');
    final artistItemMaps = extractArtistMaps('ArtistItems');

    final combinedArtistIds = <String>{
      for (final artist in albumArtistMaps)
        if (artist['Id'] is String) artist['Id'] as String,
      for (final artist in artistItemMaps)
        if (artist['Id'] is String) artist['Id'] as String,
    };

    return JellyfinAlbum(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      artists: (json['AlbumArtists'] as List<dynamic>?)
              ?.map((artist) =>
                  (artist as Map<String, dynamic>)['Name'] as String? ?? '')
              .where((name) => name.isNotEmpty)
              .toList() ??
          (json['Artists'] as List<dynamic>?)?.whereType<String>().toList() ??
          const [],
      artistIds: combinedArtistIds.toList(),
      productionYear: json['ProductionYear'] as int?,
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
      isFavorite: (json['UserData'] as Map<String, dynamic>?)?['IsFavorite'] as bool? ?? false,
      genres: (json['Genres'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          (json['GenreItems'] as List<dynamic>?)
              ?.map((g) => (g as Map<String, dynamic>)['Name'] as String?)
              .whereType<String>()
              .toList(),
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

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      'AlbumArtists': [
        for (final artist in artists) {'Name': artist},
      ],
      'ArtistItems': [
        for (final artistId in artistIds) {'Id': artistId},
      ],
      'ProductionYear': productionYear,
      if (primaryImageTag != null) 'ImageTags': {'Primary': primaryImageTag},
      'UserData': {'IsFavorite': isFavorite},
      if (genres != null) 'Genres': genres,
    };
  }
}
