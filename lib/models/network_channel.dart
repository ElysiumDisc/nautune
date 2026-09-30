/// Data model for a channel on the Other People Network radio.
class NetworkChannel {
  final int number;
  final String name;
  final String artist;
  final String audioFile;
  final String? imageFile;

  /// False when the recording is gone from the server. The channel stays on
  /// the dial but plays nothing ("signal lost") and is never downloaded.
  final bool available;

  const NetworkChannel({
    required this.number,
    required this.name,
    required this.artist,
    required this.audioFile,
    this.imageFile,
    this.available = true,
  });

  /// Returns the full audio URL for streaming.
  String get audioUrl =>
      'https://www.other-people.network/audio/${Uri.encodeComponent(audioFile)}';

  /// Returns the full image URL, or null if no image is available.
  String? get imageUrl => imageFile != null
      ? 'https://www.other-people.network/images/${Uri.encodeComponent(imageFile!)}'
      : null;
}
