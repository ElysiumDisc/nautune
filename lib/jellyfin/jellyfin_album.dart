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
    this.playCount,
    this.sortName,
  });

  final String id;
  final String name;
  final List<String> artists;
  final List<String> artistIds;
  final int? productionYear;
  final String? primaryImageTag;
  final bool isFavorite;
  final List<String>? genres;
  final int? playCount;
  final String? sortName;

  /// Name used for alphabetical grouping. Falls back to display name.
  String get groupingName => sortName ?? name;

  factory JellyfinAlbum.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> extractArtistMaps(String key) {
      final raw = json[key];
      if (raw is List) {
        return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
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

    String extractArtistName(dynamic artist) {
      if (artist is Map) {
        final name = artist['Name'];
        return name is String ? name : '';
      }
      return '';
    }

    final artistsList = (json['AlbumArtists'] as List<dynamic>?)
            ?.map(extractArtistName)
            .where((name) => name.isNotEmpty)
            .toList() ??
        (json['Artists'] as List<dynamic>?)?.whereType<String>().toList() ??
        const <String>[];

    final imageTags = json['ImageTags'];
    final userData = json['UserData'];

    final genresList = (json['Genres'] as List<dynamic>?)
            ?.whereType<String>()
            .toList() ??
        (json['GenreItems'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((g) => g['Name'])
            .whereType<String>()
            .toList();

    // Parse play count from UserData
    int? playCount;
    if (userData is Map) {
      final pc = userData['PlayCount'];
      if (pc is int) {
        playCount = pc;
      } else if (pc is num) {
        playCount = pc.toInt();
      }
    }

    return JellyfinAlbum(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      artists: artistsList,
      artistIds: combinedArtistIds.toList(),
      productionYear: json['ProductionYear'] as int?,
      primaryImageTag: imageTags is Map ? (imageTags['Primary'] as String?) : null,
      isFavorite: userData is Map ? (userData['IsFavorite'] as bool? ?? false) : false,
      genres: genresList,
      playCount: playCount,
      sortName: json['SortName'] as String?,
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
      if (sortName != null) 'SortName': sortName,
    };
  }
}
