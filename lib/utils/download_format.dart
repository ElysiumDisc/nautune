/// Pure helpers for choosing the on-disk format of offline downloads.
///
/// iOS plays downloads through AVPlayer, which identifies local files largely
/// by their extension, so the saved file must carry the right one. AVPlayer
/// also cannot decode Ogg/Opus/Vorbis, WMA, APE, WavPack, Matroska, DSD, …;
/// such originals are downloaded as a server transcode instead (see
/// `DownloadService`), and [isOfflinePlayableExtension] flags legacy files.
class DownloadFormat {
  DownloadFormat._();

  /// Extension used when nothing in the response identifies the format.
  static const String fallbackExtension = 'flac';

  /// Audio extensions we recognise in a `Content-Disposition` filename.
  static const Set<String> knownAudioExtensions = {
    'mp3', 'm4a', 'm4b', 'mp4', 'aac', 'flac', 'alac', 'wav', 'aif', 'aiff',
    'aifc', 'caf', 'ogg', 'oga', 'opus', 'webm', 'mka', 'wma', 'ape', 'wv',
    'dsf', 'dff', 'tta', 'mpc', 'spx',
  };

  /// Extensions AVPlayer can open from a local file.
  static const Set<String> offlinePlayableExtensions = {
    'mp3', 'm4a', 'm4b', 'mp4', 'aac', 'flac', 'alac', 'wav', 'aif', 'aiff',
    'aifc', 'caf',
  };

  static const Map<String, String> _mimeToExtension = {
    'audio/flac': 'flac',
    'audio/x-flac': 'flac',
    'audio/mpeg': 'mp3',
    'audio/mp3': 'mp3',
    'audio/mpeg3': 'mp3',
    'audio/x-mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/m4a': 'm4a',
    'audio/x-m4a': 'm4a',
    'audio/x-m4b': 'm4b',
    'audio/alac': 'm4a',
    'audio/aac': 'aac',
    'audio/x-aac': 'aac',
    'audio/aacp': 'aac',
    'audio/wav': 'wav',
    'audio/x-wav': 'wav',
    'audio/wave': 'wav',
    'audio/vnd.wave': 'wav',
    'audio/aiff': 'aiff',
    'audio/x-aiff': 'aiff',
    'audio/x-caf': 'caf',
    'audio/ogg': 'ogg',
    'application/ogg': 'ogg',
    'audio/vorbis': 'ogg',
    'audio/opus': 'opus',
    'audio/webm': 'webm',
    'audio/x-matroska': 'mka',
    'audio/x-ms-wma': 'wma',
    'audio/ape': 'ape',
    'audio/x-ape': 'ape',
    'audio/x-monkeys-audio': 'ape',
    'audio/x-wavpack': 'wv',
    'audio/wavpack': 'wv',
    'audio/x-dsf': 'dsf',
    'audio/dsf': 'dsf',
  };

  static const Map<String, String> _containerToExtension = {
    'flac': 'flac',
    'mp3': 'mp3',
    'm4a': 'm4a',
    'm4b': 'm4b',
    'mp4': 'm4a',
    'mov': 'm4a',
    'aac': 'aac',
    'alac': 'm4a',
    'wav': 'wav',
    'aiff': 'aiff',
    'aif': 'aiff',
    'ogg': 'ogg',
    'oga': 'ogg',
    'opus': 'opus',
    'webm': 'webm',
    'mka': 'mka',
    'matroska': 'mka',
    'asf': 'wma',
    'wma': 'wma',
    'ape': 'ape',
    'wv': 'wv',
    'dsf': 'dsf',
  };

  /// Pick the file extension for a downloaded response, most specific
  /// signal first: the `Content-Disposition` filename (what
  /// `/Items/{id}/Download` sends), then the `Content-Type`, then the
  /// Jellyfin `Container` of the source item (only when the response is the
  /// original file, i.e. not a transcode), then [fallbackExtension].
  static String extensionFor({
    String? contentType,
    String? contentDisposition,
    String? container,
  }) {
    final fromName = _extensionFromDisposition(contentDisposition);
    if (fromName != null) return fromName;

    final mime = contentType?.split(';').first.trim().toLowerCase();
    if (mime != null && mime.isNotEmpty) {
      final mapped = _mimeToExtension[mime];
      if (mapped != null) return mapped;
    }

    if (container != null) {
      for (final part in container.toLowerCase().split(',')) {
        final mapped = _containerToExtension[part.trim()];
        if (mapped != null) return mapped;
      }
    }
    return fallbackExtension;
  }

  /// Whether AVPlayer can play a downloaded file with this [extension]
  /// (with or without a leading dot, any case).
  static bool isOfflinePlayableExtension(String extension) {
    var ext = extension.trim().toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);
    return offlinePlayableExtensions.contains(ext);
  }

  /// Extension of [path] (lowercase, without the dot), or '' if none.
  static String extensionOf(String path) {
    final slash = path.lastIndexOf('/');
    final name = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static String? _extensionFromDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    // Prefer RFC 5987 `filename*=UTF-8''name.ext`, then `filename="name.ext"`.
    final match = RegExp(r"filename\*\s*=\s*[^']*'[^']*'([^;]+)",
                caseSensitive: false)
            .firstMatch(header) ??
        RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false)
            .firstMatch(header);
    if (match == null) return null;
    final name = Uri.decodeComponent(match.group(1)!.trim());
    final ext = extensionOf(name);
    return knownAudioExtensions.contains(ext) ? ext : null;
  }

  /// Rough size estimate for a track from its bitrate (bits/s) and length
  /// (Jellyfin ticks, 10,000,000 per second). Null if either is unknown.
  static int? estimateBytes({int? bitrate, int? runTimeTicks}) {
    if (bitrate == null || bitrate <= 0) return null;
    if (runTimeTicks == null || runTimeTicks <= 0) return null;
    final seconds = runTimeTicks / 10000000;
    return (bitrate / 8 * seconds).round();
  }
}
