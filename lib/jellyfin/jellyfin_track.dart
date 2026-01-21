import 'dart:math' as math;

class JellyfinTrack {
  JellyfinTrack({
    required this.id,
    required this.name,
    required this.album,
    required this.artists,
    this.artistIds = const <String>[],
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
    this.playCount,
    this.streamUrlOverride,
    this.assetPathOverride,
    this.normalizationGain,
    this.container,
    this.codec,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.genres,
    this.providerIds,
  });

  final String id;
  final String name;
  final String? album;
  final List<String> artists;
  final List<String> artistIds;
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
  final int? playCount;
  final String? streamUrlOverride;
  final String? assetPathOverride;
  final double? normalizationGain; // dB adjustment for ReplayGain

  // Audio metadata from MediaStreams
  final String? container; // File format (FLAC, MP3, M4A, etc.)
  final String? codec; // Audio codec (flac, mp3, aac, opus, etc.)
  final int? bitrate; // Bitrate in bps
  final int? sampleRate; // Sample rate in Hz (44100, 48000, 96000, etc.)
  final int? bitDepth; // Bit depth (16, 24, 32)
  final int? channels; // Number of audio channels (1=mono, 2=stereo, 6=5.1, etc.)
  final List<String>? genres; // Track genres for stats
  final Map<String, String>? providerIds; // External IDs (MusicBrainzTrack, MusicBrainzArtist, etc.)

  factory JellyfinTrack.fromJson(Map<String, dynamic> json, {String? serverUrl, String? token, String? userId}) {
    final rawArtists = json['Artists'];
    final artistsList = (rawArtists is List) ? rawArtists.whereType<String>().toList() : <String>[];

    // Parse artist IDs from ArtistItems (similar to how albums do it)
    final rawArtistItems = json['ArtistItems'];
    final artistIdsList = <String>[];
    if (rawArtistItems is List) {
      for (final item in rawArtistItems) {
        if (item is Map && item['Id'] is String) {
          artistIdsList.add(item['Id'] as String);
        }
      }
    }

    final imageTags = json['ImageTags'];
    final primaryImageTag = imageTags is Map ? (imageTags['Primary'] is String ? imageTags['Primary'] as String : null) : null;

    final userData = json['UserData'];
    bool isFavorite = false;
    int? playCount;
    if (userData is Map) {
      final fav = userData['IsFavorite'];
      if (fav is bool) {
        isFavorite = fav;
      } else if (fav is num) {
        isFavorite = fav != 0;
      }
      final pc = userData['PlayCount'];
      if (pc is int) {
        playCount = pc;
      } else if (pc is num) {
        playCount = pc.toInt();
      }
    }

    final runTimeTicksVal = json['RunTimeTicks'];
    final runTimeTicks = runTimeTicksVal is int ? runTimeTicksVal : (runTimeTicksVal is num ? runTimeTicksVal.toInt() : null);

    final normVal = json['NormalizationGain'];
    final normalizationGain = normVal is num ? normVal.toDouble() : null;

    // Parse audio metadata from MediaStreams (first audio stream)
    String? container;
    String? codec;
    int? bitrate;
    int? sampleRate;
    int? bitDepth;
    int? channels;

    // small helper to parse ints from num or numeric strings
    int? parseInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // Container/format from top level
    final containerField = json['Container'];
    if (containerField is String) {
      container = containerField.toUpperCase(); // FLAC, MP3, M4A, etc.
    }

    // Audio stream metadata
    final mediaStreams = json['MediaStreams'];
    if (mediaStreams is List && mediaStreams.isNotEmpty) {
      // Find first audio stream
      final audioStream = mediaStreams.firstWhere(
        (stream) => stream is Map && stream['Type'] == 'Audio',
        orElse: () => null,
      );

      if (audioStream is Map) {
        codec = audioStream['Codec'] is String
            ? (audioStream['Codec'] as String).toUpperCase()
            : null;
        bitrate = parseInt(audioStream['BitRate']);
        sampleRate = parseInt(audioStream['SampleRate']);
        bitDepth = parseInt(audioStream['BitDepth']);
        channels = parseInt(audioStream['Channels']);
      }
    }
    // If MediaStreams is missing, these tracks may need re-scanning in Jellyfin
    // or the API doesn't support MediaStreams for certain item types

    // Parse genres
    final rawGenres = json['Genres'];
    final genresList = (rawGenres is List) ? rawGenres.whereType<String>().toList() : null;

    // Parse provider IDs (MusicBrainz, etc.)
    Map<String, String>? providerIds;
    final rawProviderIds = json['ProviderIds'];
    if (rawProviderIds is Map) {
      providerIds = {};
      rawProviderIds.forEach((key, value) {
        if (key is String && value is String) {
          providerIds![key] = value;
        }
      });
      if (providerIds.isEmpty) providerIds = null;
    }

    return JellyfinTrack(
      id: json['Id'] is String ? json['Id'] as String : '',
      name: json['Name'] is String ? json['Name'] as String : '',
      album: json['Album'] is String ? json['Album'] as String : null,
      artists: artistsList,
      artistIds: artistIdsList,
      runTimeTicks: runTimeTicks,
      primaryImageTag: primaryImageTag,
      serverUrl: serverUrl,
      token: token,
      userId: userId,
      indexNumber: json['IndexNumber'] is int ? json['IndexNumber'] as int : (json['IndexNumber'] is num ? (json['IndexNumber'] as num).toInt() : null),
      parentIndexNumber: json['ParentIndexNumber'] is int ? json['ParentIndexNumber'] as int : (json['ParentIndexNumber'] is num ? (json['ParentIndexNumber'] as num).toInt() : null),
      albumId: json['AlbumId'] is String ? json['AlbumId'] as String : null,
      albumPrimaryImageTag: json['AlbumPrimaryImageTag'] is String ? json['AlbumPrimaryImageTag'] as String : null,
      parentThumbImageTag: json['ParentThumbImageTag'] is String ? json['ParentThumbImageTag'] as String : null,
      isFavorite: isFavorite,
      playCount: playCount,
      streamUrlOverride: null,
      assetPathOverride: null,
      normalizationGain: normalizationGain,
      container: container,
      codec: codec,
      bitrate: bitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      genres: genresList,
      providerIds: providerIds,
    );
  }

  JellyfinTrack copyWith({
    String? id,
    String? name,
    String? album,
    List<String>? artists,
    List<String>? artistIds,
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
    int? playCount,
    String? streamUrlOverride,
    String? assetPathOverride,
    double? normalizationGain,
    String? container,
    String? codec,
    int? bitrate,
    int? sampleRate,
    int? bitDepth,
    int? channels,
    List<String>? genres,
    Map<String, String>? providerIds,
  }) {
    return JellyfinTrack(
      id: id ?? this.id,
      name: name ?? this.name,
      album: album ?? this.album,
      artists: artists ?? this.artists,
      artistIds: artistIds ?? this.artistIds,
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
      playCount: playCount ?? this.playCount,
      streamUrlOverride: streamUrlOverride ?? this.streamUrlOverride,
      assetPathOverride: assetPathOverride ?? this.assetPathOverride,
      normalizationGain: normalizationGain ?? this.normalizationGain,
      container: container ?? this.container,
      codec: codec ?? this.codec,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      channels: channels ?? this.channels,
      genres: genres ?? this.genres,
      providerIds: providerIds ?? this.providerIds,
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

  /// Returns formatted audio quality info for display
  /// Example: "FLAC • 1411 kbps • 16-bit/44.1kHz • Stereo"
  String? get audioQualityInfo {
    final parts = <String>[];

    // Format (FLAC, MP3, AAC, etc.)
    if (container != null) {
      parts.add(container!);
    } else if (codec != null) {
      parts.add(codec!);
    }

    // Bitrate (in kbps)
    if (bitrate != null) {
      final kbps = (bitrate! / 1000).round();
      parts.add('$kbps kbps');
    }

    // Bit depth and sample rate
    if (bitDepth != null && sampleRate != null) {
      final khz = (sampleRate! / 1000).toStringAsFixed(1);
      parts.add('$bitDepth-bit/$khz kHz');
    } else if (sampleRate != null) {
      final khz = (sampleRate! / 1000).toStringAsFixed(1);
      parts.add('$khz kHz');
    } else if (bitDepth != null) {
      parts.add('$bitDepth-bit');
    }

    // Channel layout
    if (channels != null) {
      switch (channels!) {
        case 1:
          parts.add('Mono');
          break;
        case 2:
          parts.add('Stereo');
          break;
        case 6:
          parts.add('5.1');
          break;
        case 8:
          parts.add('7.1');
          break;
        default:
          parts.add('${channels}ch');
      }
    }

    return parts.isEmpty ? null : parts.join(' • ');
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
    int? audioBitrate,
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
    // Add AudioBitrate to force specific transcoding bitrate
    if (audioBitrate != null) {
      query['AudioBitrate'] = '$audioBitrate';
    }
    return uri.replace(queryParameters: query).toString();
  }

  /// Returns a URL that FORCES transcoding via the /Audio/{Id}/stream.{container} endpoint.
  /// This includes a "kitchen sink" of parameters to ensure strict bitrate limiting across Jellyfin versions.
  String? transcodedStreamUrl({
    required String deviceId,
    required int audioBitrate,
    String audioCodec = 'mp3',
    String container = 'mp3',
    String? playSessionId,
  }) {
    if (streamUrlOverride != null) {
      return streamUrlOverride;
    }
    if (serverUrl == null || token == null) {
      return null;
    }

    // Use /Audio/{Id}/stream.mp3 with explicit extension
    final uri = Uri.parse(serverUrl!).resolve('/Audio/$id/stream.$container');
    
    final query = <String, String>{
      // Force transcoding flags
      'Static': 'false', 
      'static': 'false',
      'MediaSourceId': id,
      'DeviceId': deviceId,
      'deviceId': deviceId,
      'api_key': token!,
      
      // Format specs
      'Container': container,
      'AudioCodec': audioCodec,
      'audioCodec': audioCodec,
      
      // Bitrate limits (providing all variations to ensure one hits)
      'AudioBitRate': '$audioBitrate',
      'audioBitrate': '$audioBitrate',
      'MaxStreamingBitrate': '$audioBitrate',
      'maxStreamingBitrate': '$audioBitrate',
      'bitrate': '$audioBitrate',
      
      // Channels
      'MaxAudioChannels': '2',
      'maxAudioChannels': '2',
      
      // Protocol
      'TranscodingProtocol': 'http',
      'TranscodingContainer': container,
    };

    // Link stream to playback session if provided
    if (playSessionId != null) {
      query['PlaySessionId'] = playSessionId;
    }

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
      'playCount': playCount,
      'streamUrlOverride': streamUrlOverride,
      'assetPathOverride': assetPathOverride,
      'normalizationGain': normalizationGain,
      'container': container,
      'codec': codec,
      'bitrate': bitrate,
      'sampleRate': sampleRate,
      'bitDepth': bitDepth,
      'channels': channels,
      'genres': genres,
    };
  }

  static JellyfinTrack fromStorageJson(Map<String, dynamic> json) {
    final rawArtists = json['artists'];
    final artistsList = (rawArtists is List) ? rawArtists.whereType<String>().toList() : <String>[];

    final runTimeTicksVal = json['runTimeTicks'];
    final runTimeTicks = runTimeTicksVal is int ? runTimeTicksVal : (runTimeTicksVal is num ? runTimeTicksVal.toInt() : null);

    final normVal = json['normalizationGain'];
    final normalizationGain = normVal is num ? normVal.toDouble() : null;

    final rawGenres = json['genres'];
    final genresList = (rawGenres is List) ? rawGenres.whereType<String>().toList() : null;

    return JellyfinTrack(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      album: json['album'] is String ? json['album'] as String : null,
      artists: artistsList,
      runTimeTicks: runTimeTicks,
      primaryImageTag: json['primaryImageTag'] is String ? json['primaryImageTag'] as String : null,
      serverUrl: json['serverUrl'] is String ? json['serverUrl'] as String : null,
      token: json['token'] is String ? json['token'] as String : null,
      userId: json['userId'] is String ? json['userId'] as String : null,
      indexNumber: json['indexNumber'] is int ? json['indexNumber'] as int : (json['indexNumber'] is num ? (json['indexNumber'] as num).toInt() : null),
      parentIndexNumber: json['parentIndexNumber'] is int ? json['parentIndexNumber'] as int : (json['parentIndexNumber'] is num ? (json['parentIndexNumber'] as num).toInt() : null),
      albumId: json['albumId'] is String ? json['albumId'] as String : null,
      albumPrimaryImageTag: json['albumPrimaryImageTag'] is String ? json['albumPrimaryImageTag'] as String : null,
      parentThumbImageTag: json['parentThumbImageTag'] is String ? json['parentThumbImageTag'] as String : null,
      isFavorite: json['isFavorite'] is bool ? json['isFavorite'] as bool : (json['isFavorite'] is num ? (json['isFavorite'] as num) != 0 : false),
      playCount: json['playCount'] is int ? json['playCount'] as int : (json['playCount'] is num ? (json['playCount'] as num).toInt() : null),
      streamUrlOverride: json['streamUrlOverride'] is String ? json['streamUrlOverride'] as String : null,
      assetPathOverride: json['assetPathOverride'] is String ? json['assetPathOverride'] as String : null,
      normalizationGain: normalizationGain,
      container: json['container'] is String ? json['container'] as String : null,
      codec: json['codec'] is String ? json['codec'] as String : null,
      bitrate: json['bitrate'] is int ? json['bitrate'] as int : (json['bitrate'] is num ? (json['bitrate'] as num).toInt() : null),
      sampleRate: json['sampleRate'] is int ? json['sampleRate'] as int : (json['sampleRate'] is num ? (json['sampleRate'] as num).toInt() : null),
      bitDepth: json['bitDepth'] is int ? json['bitDepth'] as int : (json['bitDepth'] is num ? (json['bitDepth'] as num).toInt() : null),
      channels: json['channels'] is int ? json['channels'] as int : (json['channels'] is num ? (json['channels'] as num).toInt() : null),
      genres: genresList,
    );
  }

}
