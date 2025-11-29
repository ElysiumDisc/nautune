import 'dart:math' as math;

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
    this.indexNumber,
    this.parentIndexNumber,
    this.albumId,
    this.albumPrimaryImageTag,
    this.parentThumbImageTag,
    this.isFavorite = false,
    this.streamUrlOverride,
    this.assetPathOverride,
    this.normalizationGain,
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
  final int? indexNumber;
  final int? parentIndexNumber;
  final String? albumId;
  final String? albumPrimaryImageTag;
  final String? parentThumbImageTag;
  final bool isFavorite;
  final String? streamUrlOverride;
  final String? assetPathOverride;
  final double? normalizationGain; // dB adjustment for ReplayGain

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
      indexNumber: json['IndexNumber'] as int?,
      parentIndexNumber: json['ParentIndexNumber'] as int?,
      albumId: json['AlbumId'] as String?,
      albumPrimaryImageTag: json['AlbumPrimaryImageTag'] as String?,
      parentThumbImageTag: json['ParentThumbImageTag'] as String?,
      isFavorite: (json['UserData'] as Map<String, dynamic>?)?['IsFavorite'] as bool? ?? false,
      streamUrlOverride: null,
      assetPathOverride: null,
      normalizationGain: json['NormalizationGain'] as double?,
    );
  }

  JellyfinTrack copyWith({
    String? id,
    String? name,
    String? album,
    List<String>? artists,
    int? runTimeTicks,
    String? primaryImageTag,
    String? serverUrl,
    String? token,
    String? userId,
    int? indexNumber,
    int? parentIndexNumber,
    String? albumId,
    String? albumPrimaryImageTag,
    String? parentThumbImageTag,
    bool? isFavorite,
    String? streamUrlOverride,
    String? assetPathOverride,
    double? normalizationGain,
  }) {
    return JellyfinTrack(
      id: id ?? this.id,
      name: name ?? this.name,
      album: album ?? this.album,
      artists: artists ?? this.artists,
      runTimeTicks: runTimeTicks ?? this.runTimeTicks,
      primaryImageTag: primaryImageTag ?? this.primaryImageTag,
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      userId: userId ?? this.userId,
      indexNumber: indexNumber ?? this.indexNumber,
      parentIndexNumber: parentIndexNumber ?? this.parentIndexNumber,
      albumId: albumId ?? this.albumId,
      albumPrimaryImageTag: albumPrimaryImageTag ?? this.albumPrimaryImageTag,
      parentThumbImageTag: parentThumbImageTag ?? this.parentThumbImageTag,
      isFavorite: isFavorite ?? this.isFavorite,
      streamUrlOverride: streamUrlOverride ?? this.streamUrlOverride,
      assetPathOverride: assetPathOverride ?? this.assetPathOverride,
      normalizationGain: normalizationGain ?? this.normalizationGain,
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

  /// Disc number reported by Jellyfin, if available.
  int? get discNumber => parentIndexNumber;

  /// Returns the best available track number for display.
  int effectiveTrackNumber(int fallback) {
    return indexNumber ?? fallback;
  }

  /// Returns the volume multiplier to apply for ReplayGain normalization.
  /// Returns 1.0 if no normalization gain is available.
  /// Formula: 10^(gain_dB / 20)
  double get replayGainMultiplier {
    if (normalizationGain == null) return 1.0;
    // Convert dB to linear volume multiplier
    // Clamp to reasonable range (0.1 to 2.0) to prevent extreme adjustments
    final multiplier = math.pow(10, normalizationGain! / 20).toDouble();
    return multiplier.clamp(0.1, 2.0);
  }

  /// Returns the most suitable image tag for artwork.
  String? get _effectiveImageTag =>
      primaryImageTag ?? albumPrimaryImageTag ?? parentThumbImageTag;

  /// Returns the item id to use for artwork lookups.
  String? get _artworkItemId {
    if (primaryImageTag != null) {
      return id;
    }
    if (albumPrimaryImageTag != null && albumId != null) {
      return albumId;
    }
    return parentThumbImageTag != null ? albumId ?? id : null;
  }

  /// Builds an artwork URL suitable for Image.network.
  String? artworkUrl({int maxWidth = 800}) {
    final tag = _effectiveImageTag;
    final itemId = _artworkItemId;
    if (serverUrl == null || token == null || tag == null || itemId == null) {
      return null;
    }
    final uri = Uri.parse(serverUrl!).resolve('/Items/$itemId/Images/Primary');
    final query = <String, String>{
      'quality': '90',
      'maxWidth': '$maxWidth',
      'api_key': token!,
      'tag': tag,
    };
    return uri.replace(queryParameters: query).toString();
  }

  /// Builds a waveform preview URL provided by Jellyfin.
  String? waveformImageUrl({int width = 900, int height = 120}) {
    if (serverUrl == null || token == null) {
      return null;
    }
    final uri = Uri.parse(serverUrl!).resolve('/Audio/$id/Waveform');
    final query = <String, String>{
      'width': '$width',
      'height': '$height',
      'api_key': token!,
    };
    return uri.replace(queryParameters: query).toString();
  }

  String? directDownloadUrl() {
    if (streamUrlOverride != null) {
      return streamUrlOverride;
    }
    if (serverUrl == null || token == null) {
      return null;
    }
    final uri = Uri.parse(serverUrl!).resolve('/Items/$id/Download');
    final query = <String, String>{
      'api_key': token!,
      'static': 'true',
    };
    return uri.replace(queryParameters: query).toString();
  }

  String? universalStreamUrl({
    required String deviceId,
    int maxBitrate = 192000,
    String audioCodec = 'mp3',
    String container = 'mp3',
  }) {
    if (streamUrlOverride != null) {
      return streamUrlOverride;
    }
    if (serverUrl == null || token == null || userId == null) {
      return null;
    }
    final uri = Uri.parse(serverUrl!).resolve('/Audio/$id/universal');
    final query = <String, String>{
      'UserId': userId!,
      'DeviceId': deviceId,
      'AudioCodec': audioCodec,
      'Container': container,
      'TranscodingProtocol': 'progressive',
      'TranscodingContainer': container,
      'MaxStreamingBitrate': '$maxBitrate',
      'MaxAudioChannels': '2',
      'StartTimeTicks': '0',
      'EnableRedirection': 'true',
      'api_key': token!,
    };
    return uri.replace(queryParameters: query).toString();
  }

  String streamUrl({
    required String deviceId,
    int maxBitrate = 192000,
  }) {
    final universal = universalStreamUrl(
      deviceId: deviceId,
      maxBitrate: maxBitrate,
    );
    if (universal != null) {
      return universal;
    }
    final direct = directDownloadUrl();
    if (direct != null) {
      return direct;
    }
    throw Exception('JellyfinTrack missing data for streaming URL');
  }

  String downloadUrl(String? baseUrl, String? authToken) {
    if (streamUrlOverride != null) {
      return streamUrlOverride!;
    }
    final url = baseUrl ?? serverUrl;
    final token = authToken ?? this.token;
    if (url == null || token == null) {
      throw Exception('Missing server URL or token for download');
    }
    final uri = Uri.parse(url).resolve('/Items/$id/Download');
    final query = <String, String>{
      'api_key': token,
    };
    return uri.replace(queryParameters: query).toString();
  }

  Map<String, dynamic> toStorageJson() {
    return {
      'id': id,
      'name': name,
      'album': album,
      'artists': artists,
      'runTimeTicks': runTimeTicks,
      'primaryImageTag': primaryImageTag,
      'serverUrl': serverUrl,
      'token': token,
      'userId': userId,
      'indexNumber': indexNumber,
      'parentIndexNumber': parentIndexNumber,
      'albumId': albumId,
      'albumPrimaryImageTag': albumPrimaryImageTag,
      'parentThumbImageTag': parentThumbImageTag,
      'isFavorite': isFavorite,
      'streamUrlOverride': streamUrlOverride,
      'assetPathOverride': assetPathOverride,
      'normalizationGain': normalizationGain,
    };
  }

  static JellyfinTrack fromStorageJson(Map<String, dynamic> json) {
    return JellyfinTrack(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      album: json['album'] as String?,
      artists: (json['artists'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      runTimeTicks: json['runTimeTicks'] as int?,
      primaryImageTag: json['primaryImageTag'] as String?,
      serverUrl: json['serverUrl'] as String?,
      token: json['token'] as String?,
      userId: json['userId'] as String?,
      indexNumber: json['indexNumber'] as int?,
      parentIndexNumber: json['parentIndexNumber'] as int?,
      albumId: json['albumId'] as String?,
      albumPrimaryImageTag: json['albumPrimaryImageTag'] as String?,
      parentThumbImageTag: json['parentThumbImageTag'] as String?,
      isFavorite: json['isFavorite'] as bool? ?? false,
      streamUrlOverride: json['streamUrlOverride'] as String?,
      assetPathOverride: json['assetPathOverride'] as String?,
      normalizationGain: json['normalizationGain'] as double?,
    );
  }

}
