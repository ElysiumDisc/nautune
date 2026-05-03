class JellyfinArtist {
  JellyfinArtist({
    required this.id,
    required this.name,
    this.primaryImageTag,
    this.overview,
    this.genres,
    this.albumCount,
    this.songCount,
    this.playCount,
    this.providerIds,
    this.sortName,
  });

  final String id;
  final String name;
  final String? primaryImageTag;
  final String? overview;
  final List<String>? genres;
  final int? albumCount;
  final int? songCount;
  final int? playCount;
  final Map<String, String>? providerIds;
  final String? sortName;

  /// Name used for alphabetical grouping. Falls back to display name.
  String get groupingName => sortName ?? name;

  factory JellyfinArtist.fromJson(Map<String, dynamic> json) {
    final imageTags = json['ImageTags'];
    final primaryImageTag = imageTags is Map ? (imageTags['Primary'] is String ? imageTags['Primary'] as String : null) : null;

    final rawGenres = json['Genres'];
    final genresList = (rawGenres is List) ? rawGenres.whereType<String>().toList() : null;

    final albumCountVal = json['ChildCount'];
    final albumCount = albumCountVal is int ? albumCountVal : (albumCountVal is num ? albumCountVal.toInt() : null);

    final songCountVal = json['SongCount'];
    final songCount = songCountVal is int ? songCountVal : (songCountVal is num ? songCountVal.toInt() : null);

    // Parse play count from UserData
    int? playCount;
    final userData = json['UserData'];
    if (userData is Map) {
      final pc = userData['PlayCount'];
      if (pc is int) {
        playCount = pc;
      } else if (pc is num) {
        playCount = pc.toInt();
      }
    }

    // Parse provider IDs (MusicBrainz, etc.)
    Map<String, String>? providerIds;
    final rawProviderIds = json['ProviderIds'];
    if (rawProviderIds is Map) {
      providerIds = {};
      rawProviderIds.forEach((key, value) {
        if (key is String && value != null) {
          providerIds![key] = value.toString();
        }
      });
      if (providerIds.isEmpty) providerIds = null;
    }

    return JellyfinArtist(
      id: json['Id'] is String ? json['Id'] as String : '',
      name: json['Name'] is String ? json['Name'] as String : '',
      primaryImageTag: primaryImageTag,
      overview: json['Overview'] is String ? json['Overview'] as String : null,
      genres: genresList,
      albumCount: albumCount,
      songCount: songCount,
      playCount: playCount,
      providerIds: providerIds,
      sortName: json['SortName'] is String ? json['SortName'] as String : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      if (primaryImageTag != null) 'ImageTags': {'Primary': primaryImageTag},
      'Overview': overview,
      if (genres != null) 'Genres': genres,
      'ChildCount': albumCount,
      'SongCount': songCount,
      if (providerIds != null) 'ProviderIds': providerIds,
      if (sortName != null) 'SortName': sortName,
    };
  }
}
