/// Data model for the Essential Mix Easter egg track.
class EssentialMixTrack {
  /// Unique identifier for this track
  final String id = 'essential-mix-soulwax-2017';

  /// Track name
  final String name = 'Essential Mix';

  /// Artist name
  final String artist = 'Soulwax / 2ManyDJs';

  /// Album name
  final String album = 'BBC Radio 1 Essential Mix';

  /// Original broadcast date (May 20, 2017)
  final String dateString = '2017-05-20';

  /// Get the date as DateTime
  DateTime get date => DateTime(2017, 5, 20);

  /// Approximate duration (~2 hours)
  final Duration duration = const Duration(hours: 2);

  /// Audio stream URL from Internet Archive
  final String audioUrl =
      'https://archive.org/download/2017-05-20-soulwax-2manydjs-essential-mix/2017-05-20%20-%20Soulwax_2manydjs%20-%20Essential%20Mix.mp3';

  /// Artwork URL (YouTube thumbnail)
  final String artworkUrl = 'https://i.ytimg.com/vi/FWQu0D-oXg0/sddefault.jpg';

  /// Credit for the audio source
  final String credit = 'Internet Archive (archive.org)';

  /// File size in bytes as served by archive.org (233.6 MiB)
  final int fileSizeBytes = 244958622;

  const EssentialMixTrack();

  /// Format duration as human-readable string
  String get formattedDuration {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  /// Format file size as human-readable string
  String get formattedFileSize {
    final mb = fileSizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
