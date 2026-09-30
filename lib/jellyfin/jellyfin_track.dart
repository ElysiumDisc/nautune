
import '../models/transcode_codec.dart';
import 'jellyfin_auth_header.dart';
import 'server_uri.dart';

/// Containers (optionally `container|codec[|codec]`) that AVPlayer on iOS
/// decodes natively, in the format `/Audio/{id}/universal` expects for its
/// `container` parameter. Jellyfin reports MP4-family files with the
/// container string `mov,mp4,m4a,3gp,3g2,mj2`, which matches the `m4a`
/// entries. Ogg/WebM/Matroska (Opus, Vorbis, FLAC-in-Ogg), ASF (WMA), APE,
/// WavPack, DSD, … are deliberately absent so the server transcodes them.
const List<String> kAvPlayerDirectPlayContainers = [
  'mp3',
  'aac',
  'm4a|aac|alac',
  'm4b|aac|alac',
  'mp4|aac|alac',
  'flac',
  'alac',
  'wav',
  'aiff',
];

/// Lossy subset of [kAvPlayerDirectPlayContainers], used for bitrate-capped
/// quality levels (lossless files always exceed those caps anyway).
const List<String> kAvPlayerLossyContainers = [
  'mp3',
  'aac',
  'm4a|aac',
  'm4b|aac',
  'mp4|aac',
];

/// `maxStreamingBitrate` for "original" quality: high enough for 24/192
/// FLAC; the server still applies the user's remote bitrate limit.
const int kOriginalQualityMaxStreamingBitrate = 140000000;

const Set<String> _avPlayerUnsupportedContainers = {
  'ogg', 'oga', 'ogx', 'opus', 'webm', 'mkv', 'mka', 'matroska', 'asf',
  'wma', 'ape', 'wv', 'wavpack', 'dsf', 'dff', 'tta', 'mpc', 'spx', 'ra',
  'rm', 'amr', 'dts', 'mod', 'xm', 's3m', 'it',
};

const Set<String> _avPlayerUnsupportedCodecs = {
  'opus', 'vorbis', 'wmav1', 'wmav2', 'wmapro', 'wmalossless', 'wmavoice',
  'ape', 'wavpack', 'tta', 'musepack7', 'musepack8', 'speex', 'dts',
  'truehd', 'cook', 'ra_144', 'ra_288', 'dsd_lsbf', 'dsd_msbf',
  'dsd_lsbf_planar', 'dsd_msbf_planar',
};

/// Whether AVPlayer can decode a file with this Jellyfin `Container`
/// (possibly a comma list such as `mov,mp4,m4a,3gp,3g2,mj2`) and audio
/// `Codec`. Case-insensitive. Unknown/missing metadata returns true.
bool isAvPlayerNativeAudio({String? container, String? codec}) {
  final c = codec?.trim().toLowerCase();
  if (c != null && c.isNotEmpty && _avPlayerUnsupportedCodecs.contains(c)) {
    return false;
  }
  final containers = (container ?? '')
      .toLowerCase()
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);
  return !containers.any(_avPlayerUnsupportedContainers.contains);
}

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
    String? token,
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
    this.albumNormalizationGain,
    this.container,
    this.codec,
    this.bitrate,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.genres,
    this.providerIds,
    this.tags,
    this.productionYear,
    this.playlistItemId,
  }) : _token = token;

  /// Resolves the current session's access token for a track that was
  /// restored from storage without one (tokens are not persisted). Set by
  /// `JellyfinService` whenever its session changes; returns null when
  /// [serverUrl]/[userId] don't belong to the active session.
  static String? Function(String? serverUrl, String? userId)?
      sessionTokenResolver;

  final String id;
  final String name;
  final String? album;
  final List<String> artists;
  final List<String> artistIds;
  final int? runTimeTicks;
  final String? primaryImageTag;
  final String? serverUrl;
  final String? _token;

  /// Access token for stream/artwork URLs: the token this track was built
  /// with, or — for tracks restored from storage, which never persist the
  /// token — the active session's token (resolved lazily at use time, so a
  /// queue restored before the session is ready still works once it is).
  String? get token => _token ?? sessionTokenResolver?.call(serverUrl, userId);
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
  final double? albumNormalizationGain; // album-level dB adjustment

  // Audio metadata from MediaStreams
  final String? container; // File format (FLAC, MP3, M4A, etc.)
  final String? codec; // Audio codec (flac, mp3, aac, opus, etc.)
  final int? bitrate; // Bitrate in bps
  final int? sampleRate; // Sample rate in Hz (44100, 48000, 96000, etc.)
  final int? bitDepth; // Bit depth (16, 24, 32)
  final int? channels; // Number of audio channels (1=mono, 2=stereo, 6=5.1, etc.)
  final List<String>? genres; // Track genres for stats
  final Map<String, String>? providerIds; // External IDs (MusicBrainzTrack, MusicBrainzArtist, etc.)
  final List<String>? tags; // User tags from Jellyfin for smart playlist filtering
  final int? productionYear; // Album production year, persisted for offline display
  /// This entry's `PlaylistItemId` when the track came from a playlist's
  /// items (older servers need it, not the item id, to move/remove entries).
  final String? playlistItemId;

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
    final albumNormVal = json['AlbumNormalizationGain'];
    final albumNormalizationGain =
        albumNormVal is num ? albumNormVal.toDouble() : null;

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
        if (key is String && value != null) {
          // Convert any value to String (Jellyfin may return non-String types)
          providerIds![key] = value.toString();
        }
      });
      if (providerIds.isEmpty) providerIds = null;
    }

    // Parse tags (user-defined tags for smart playlist filtering)
    final rawTags = json['Tags'];
    final tagsList = (rawTags is List) ? rawTags.whereType<String>().toList() : null;

    // Production year (from album metadata included on track items)
    final productionYearVal = json['ProductionYear'];
    final productionYear = productionYearVal is int ? productionYearVal : (productionYearVal is num ? productionYearVal.toInt() : null);

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
      albumNormalizationGain: albumNormalizationGain,
      container: container,
      codec: codec,
      bitrate: bitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      genres: genresList,
      providerIds: providerIds,
      tags: tagsList,
      productionYear: productionYear,
      playlistItemId: json['PlaylistItemId'] is String
          ? json['PlaylistItemId'] as String
          : null,
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
    double? albumNormalizationGain,
    String? container,
    String? codec,
    int? bitrate,
    int? sampleRate,
    int? bitDepth,
    int? channels,
    List<String>? genres,
    Map<String, String>? providerIds,
    List<String>? tags,
    int? productionYear,
    String? playlistItemId,
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
      token: token ?? _token,
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
      albumNormalizationGain:
          albumNormalizationGain ?? this.albumNormalizationGain,
      container: container ?? this.container,
      codec: codec ?? this.codec,
      bitrate: bitrate ?? this.bitrate,
      sampleRate: sampleRate ?? this.sampleRate,
      bitDepth: bitDepth ?? this.bitDepth,
      channels: channels ?? this.channels,
      genres: genres ?? this.genres,
      providerIds: providerIds ?? this.providerIds,
      tags: tags ?? this.tags,
      productionYear: productionYear ?? this.productionYear,
      playlistItemId: playlistItemId ?? this.playlistItemId,
    );
  }

  /// Artist credit for scrobbling (Last.fm / ListenBrainz): every artist,
  /// comma-separated, or null when unknown. Unlike [displayArtist] this is
  /// never a UI abbreviation ("A & 1 more") or a placeholder.
  String? get scrobbleArtist => scrobbleArtistFor(artists);

  /// Pure form of [scrobbleArtist]. Also repairs single-string credits that
  /// were persisted from [displayArtist] ("A & 2 more" → "A").
  static String? scrobbleArtistFor(List<String> artists) {
    final names = [
      for (final a in artists)
        if (a.trim().isNotEmpty) a.trim(),
    ];
    if (names.isEmpty) return null;
    if (names.length == 1) {
      final single = names.first
          .replaceFirst(RegExp(r' & \d+ more$'), '')
          .trim();
      if (single.isEmpty || single == 'Unknown Artist') return null;
      return single;
    }
    return names.join(', ');
  }

  /// Artist for Last.fm: the primary (first) artist only. Last.fm treats a
  /// joined credit ("A, B") as one artist that doesn't exist, so
  /// featured artists are left out there; ListenBrainz keeps
  /// [scrobbleArtist], the full credit.
  String? get lastFmArtist => lastFmArtistFor(artists);

  /// Pure form of [lastFmArtist].
  static String? lastFmArtistFor(List<String> artists) {
    for (final a in artists) {
      if (a.trim().isEmpty) continue;
      return scrobbleArtistFor([a]);
    }
    return null;
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
    final base = serverUrl!;
    final path = '/Items/$itemId/Images/Primary';
    final query = <String, String>{
      'quality': '90',
      'maxWidth': '$maxWidth',
      kJellyfinApiKeyQueryParam: token!,
      'tag': tag,
    };
    return buildServerUrl(base, path, query);
  }

  /// Builds a waveform preview URL provided by Jellyfin.
  ///
  /// Jellyfin API note: `/Audio/{id}/Waveform` is not in the 10.11.9 or 12.1.0
  /// OpenAPI specs (docs/jellyfin-openapi-12.1.json) but is served by Jellyfin 10.9+ (provider plugin or built-in,
  /// depending on server config). Nautune falls back to its own extracted
  /// waveforms via `WaveformService` when the server 404s, so this URL is
  /// safe to call even if unavailable.
  String? waveformImageUrl({int width = 900, int height = 120}) {
    if (serverUrl == null || token == null) {
      return null;
    }
    final base = serverUrl!;
    final path = '/Audio/$id/Waveform';
    final query = <String, String>{
      'width': '$width',
      'height': '$height',
      kJellyfinApiKeyQueryParam: token!,
    };
    return buildServerUrl(base, path, query);
  }

  /// Raw-file URL (`GET /Items/{id}/Download`).
  ///
  /// Suitable for *downloads* only. Not recommended for playback: the
  /// endpoint requires the user's "Allow media downloading" permission (403
  /// otherwise), writes a "user downloaded …" entry to the server activity
  /// log on every request, and hands AVPlayer formats it can't decode
  /// (Opus/Vorbis/WMA/APE…). Use [originalQualityStreamUrl] for lossless
  /// streaming instead.
  String? directDownloadUrl() {
    if (streamUrlOverride != null) {
      return streamUrlOverride;
    }
    if (serverUrl == null || token == null) {
      return null;
    }
    final base = serverUrl!;
    final path = '/Items/$id/Download';
    // `/Items/{id}/Download` takes no query parameters besides the token.
    final query = <String, String>{
      kJellyfinApiKeyQueryParam: token!,
    };
    return buildServerUrl(base, path, query);
  }

  /// `GET /Audio/{id}/universal` — the server compares the file against the
  /// [containers] the client can play natively (`container` or
  /// `container|codec[|codec]` entries) and [maxBitrate]; it serves the
  /// original file when it fits and otherwise transcodes to
  /// [transcodingContainer]/[audioCodec] as a single progressive HTTP
  /// response. `transcodingProtocol` is always `http`: `hls` would return an
  /// m3u8 playlist and `progressive` is not a valid `MediaStreamProtocol`
  /// value (the server rejects the request with 400).
  ///
  /// [container] is kept for backwards compatibility: when [containers] is
  /// null, `[container]` is used as the direct-play list, and it is also the
  /// default [transcodingContainer].
  String? universalStreamUrl({
    required String deviceId,
    int maxBitrate = 192000,
    int? audioBitrate,
    String audioCodec = 'mp3',
    String container = 'mp3',
    List<String>? containers,
    String? transcodingContainer,
  }) {
    if (streamUrlOverride != null) {
      return streamUrlOverride;
    }
    if (serverUrl == null || token == null || userId == null) {
      return null;
    }
    final base = serverUrl!;
    final path = '/Audio/$id/universal';
    final query = <String, String>{
      'userId': userId!,
      'deviceId': deviceId,
      'container': (containers ?? [container]).join(','),
      'audioCodec': audioCodec,
      'transcodingContainer': transcodingContainer ?? container,
      'transcodingProtocol': 'http',
      'maxStreamingBitrate': '$maxBitrate',
      'maxAudioChannels': '2',
      'startTimeTicks': '0',
      'enableRedirection': 'true',
      kJellyfinApiKeyQueryParam: token!,
    };
    // Explicit encoder bitrate when transcoding (defaults to maxBitrate).
    if (audioBitrate != null) {
      query['audioBitRate'] = '$audioBitrate';
    }
    return buildServerUrl(base, path, query);
  }

  /// Lossless-first stream URL for iOS/AVPlayer.
  ///
  /// Uses `/Audio/{id}/universal` with every container/codec AVPlayer
  /// decodes natively ([kAvPlayerDirectPlayContainers]) and a very high
  /// bitrate cap, so FLAC/ALAC/MP3/AAC/WAV files are streamed untouched
  /// (static, Range-seekable) while formats AVPlayer can't open
  /// (Opus, Vorbis, FLAC-in-Ogg, WMA, APE, …) are transcoded server-side to
  /// [transcodeCodec] (MP3 by default) instead of silently failing. Unlike
  /// [directDownloadUrl] it needs no download permission and doesn't spam
  /// the server activity log.
  String? originalQualityStreamUrl({
    required String deviceId,
    int transcodeBitrate = 320000,
    TranscodeCodec transcodeCodec = TranscodeCodec.mp3,
  }) {
    return universalStreamUrl(
      deviceId: deviceId,
      maxBitrate: kOriginalQualityMaxStreamingBitrate,
      audioBitrate: transcodeBitrate,
      audioCodec: transcodeCodec.audioCodec,
      containers: kAvPlayerDirectPlayContainers,
      transcodingContainer: transcodeCodec.container,
    );
  }

  /// Bitrate-capped stream URL: the file is served as-is when it is already
  /// in a lossy format AVPlayer plays and at or below [maxBitrate] (e.g. a
  /// 256 kbps AAC under a 320 kbps cap — no pointless re-encode), otherwise
  /// transcoded to [transcodeCodec] (MP3 by default) at [maxBitrate].
  String? cappedStreamUrl({
    required String deviceId,
    required int maxBitrate,
    TranscodeCodec transcodeCodec = TranscodeCodec.mp3,
  }) {
    return universalStreamUrl(
      deviceId: deviceId,
      maxBitrate: maxBitrate,
      audioBitrate: maxBitrate,
      audioCodec: transcodeCodec.audioCodec,
      containers: kAvPlayerLossyContainers,
      transcodingContainer: transcodeCodec.container,
    );
  }

  /// Whether AVPlayer can decode this track's original file, judged from
  /// the `Container`/`Codec` metadata Jellyfin returned. Unknown metadata
  /// returns true (let the server/AVPlayer decide; the universal endpoint
  /// still guards against unsupported formats).
  bool get isAvPlayerNativeFormat =>
      isAvPlayerNativeAudio(container: container, codec: codec);

  /// Returns a URL that FORCES transcoding via
  /// `/Audio/{id}/stream.{container}` (`static=false`), linked to
  /// [playSessionId] so the server kills the ffmpeg job when the matching
  /// `/Sessions/Playing/Stopped` report arrives.
  ///
  /// Only spec parameters are sent (ASP.NET binds query keys
  /// case-insensitively, so duplicate spellings only produced multi-valued
  /// parameters). `maxStreamingBitrate`, `transcodingProtocol` and
  /// `transcodingContainer` are not parameters of this endpoint; the output
  /// format comes from the `.{container}` path segment and [audioCodec].
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

    final base = serverUrl!;
    final path = '/Audio/$id/stream.$container';

    final query = <String, String>{
      'static': 'false',
      'mediaSourceId': id,
      'deviceId': deviceId,
      'audioCodec': audioCodec,
      'audioBitRate': '$audioBitrate',
      'maxAudioChannels': '2',
      kJellyfinApiKeyQueryParam: token!,
    };

    // Link stream to playback session if provided
    if (playSessionId != null) {
      query['playSessionId'] = playSessionId;
    }

    return buildServerUrl(base, path, query);
  }

  String streamUrl({
    required String deviceId,
    int maxBitrate = 192000,
  }) {
    final universal = cappedStreamUrl(
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
    final base = url;
    final path = '/Items/$id/Download';
    final query = <String, String>{
      kJellyfinApiKeyQueryParam: token,
    };
    return buildServerUrl(base, path, query);
  }

  Map<String, dynamic> toStorageJson() {
    return {
      'id': id,
      'name': name,
      'album': album,
      'artists': artists,
      'artistIds': artistIds,
      'runTimeTicks': runTimeTicks,
      'primaryImageTag': primaryImageTag,
      'serverUrl': serverUrl,
      // The access token is deliberately NOT persisted (these boxes are
      // unencrypted and iCloud-backed-up); [token] re-resolves it from the
      // active session via [sessionTokenResolver].
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
      'albumNormalizationGain': albumNormalizationGain,
      'container': container,
      'codec': codec,
      'bitrate': bitrate,
      'sampleRate': sampleRate,
      'bitDepth': bitDepth,
      'channels': channels,
      'genres': genres,
      'tags': tags,
      'productionYear': productionYear,
      if (providerIds != null) 'providerIds': providerIds,
      if (playlistItemId != null) 'playlistItemId': playlistItemId,
    };
  }

  static JellyfinTrack fromStorageJson(Map<String, dynamic> json) {
    final rawArtists = json['artists'];
    final artistsList = (rawArtists is List) ? rawArtists.whereType<String>().toList() : <String>[];

    final rawArtistIds = json['artistIds'];
    final artistIdsList = (rawArtistIds is List) ? rawArtistIds.whereType<String>().toList() : <String>[];

    final runTimeTicksVal = json['runTimeTicks'];
    final runTimeTicks = runTimeTicksVal is int ? runTimeTicksVal : (runTimeTicksVal is num ? runTimeTicksVal.toInt() : null);

    final normVal = json['normalizationGain'];
    final normalizationGain = normVal is num ? normVal.toDouble() : null;
    final albumNormVal = json['albumNormalizationGain'];
    final albumNormalizationGain =
        albumNormVal is num ? albumNormVal.toDouble() : null;

    final rawGenres = json['genres'];
    final genresList = (rawGenres is List) ? rawGenres.whereType<String>().toList() : null;

    final rawTags = json['tags'];
    final tagsList = (rawTags is List) ? rawTags.whereType<String>().toList() : null;

    final productionYearVal = json['productionYear'];
    final productionYear = productionYearVal is int ? productionYearVal : (productionYearVal is num ? productionYearVal.toInt() : null);

    final rawProviderIds = json['providerIds'];
    final providerIds = rawProviderIds is Map
        ? <String, String>{
            for (final e in rawProviderIds.entries)
              if (e.key is String && e.value != null) e.key as String: '${e.value}',
          }
        : null;

    return JellyfinTrack(
      id: json['id'] is String ? json['id'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      album: json['album'] is String ? json['album'] as String : null,
      artists: artistsList,
      artistIds: artistIdsList,
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
      albumNormalizationGain: albumNormalizationGain,
      container: json['container'] is String ? json['container'] as String : null,
      codec: json['codec'] is String ? json['codec'] as String : null,
      bitrate: json['bitrate'] is int ? json['bitrate'] as int : (json['bitrate'] is num ? (json['bitrate'] as num).toInt() : null),
      sampleRate: json['sampleRate'] is int ? json['sampleRate'] as int : (json['sampleRate'] is num ? (json['sampleRate'] as num).toInt() : null),
      bitDepth: json['bitDepth'] is int ? json['bitDepth'] as int : (json['bitDepth'] is num ? (json['bitDepth'] as num).toInt() : null),
      channels: json['channels'] is int ? json['channels'] as int : (json['channels'] is num ? (json['channels'] as num).toInt() : null),
      genres: genresList,
      tags: tagsList,
      productionYear: productionYear,
      providerIds: (providerIds == null || providerIds.isEmpty) ? null : providerIds,
      playlistItemId: json['playlistItemId'] is String ? json['playlistItemId'] as String : null,
    );
  }

}
