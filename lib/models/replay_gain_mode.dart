/// How ReplayGain / Jellyfin normalization gain is applied to playback volume.
enum ReplayGainMode {
  /// Play files at their mastered loudness.
  off,

  /// Level every track to the same loudness (best for shuffle).
  track,

  /// Keep the loudness differences between tracks of one album, levelling
  /// albums against each other (best for full-album listening). Falls back to
  /// the track gain when the server has no album gain.
  album;

  String get label => switch (this) {
        ReplayGainMode.off => 'Off',
        ReplayGainMode.track => 'Track',
        ReplayGainMode.album => 'Album',
      };

  static ReplayGainMode fromName(String? name) => ReplayGainMode.values
      .firstWhere((m) => m.name == name, orElse: () => ReplayGainMode.track);
}
