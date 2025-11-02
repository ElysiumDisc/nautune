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
}
