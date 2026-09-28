/// Codec the server transcodes to when a track can't be streamed as-is
/// (above the quality cap, or a format AVPlayer can't decode).
enum TranscodeCodec {
  /// MP3: universally compatible, seeks reliably in progressive streams.
  mp3('mp3', 'mp3', 'MP3'),

  /// AAC (ADTS): better sound than MP3 at the same bitrate.
  aac('aac', 'aac', 'AAC');

  const TranscodeCodec(this.audioCodec, this.container, this.label);

  /// `audioCodec` query value for Jellyfin.
  final String audioCodec;

  /// Output container / `transcodingContainer` value.
  final String container;

  final String label;

  static TranscodeCodec fromName(String? name) => TranscodeCodec.values
      .firstWhere((c) => c.name == name, orElse: () => TranscodeCodec.mp3);
}
