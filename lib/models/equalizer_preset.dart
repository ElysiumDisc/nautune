/// Standard 10-band equalizer frequencies (Hz)
const List<int> kEqualizerFrequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// Human-readable frequency labels
const List<String> kEqualizerLabels = ['32', '64', '125', '250', '500', '1k', '2k', '4k', '8k', '16k'];

/// Equalizer preset with 10 band gains
class EqualizerPreset {
  final String id;
  final String name;
  final List<double> gains; // 10 values, -12.0 to +12.0 dB
  final bool isBuiltIn;

  const EqualizerPreset({
    required this.id,
    required this.name,
    required this.gains,
    this.isBuiltIn = false,
  });

  /// Create a flat (neutral) preset
  factory EqualizerPreset.flat() => const EqualizerPreset(
    id: 'flat',
    name: 'Flat',
    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    isBuiltIn: true,
  );

  /// Create preset from JSON
  factory EqualizerPreset.fromJson(Map<String, dynamic> json) => EqualizerPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    gains: (json['gains'] as List).map((e) => (e as num).toDouble()).toList(),
    isBuiltIn: json['isBuiltIn'] as bool? ?? false,
  );

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'gains': gains,
    'isBuiltIn': isBuiltIn,
  };

  /// Create a copy with modified gains
  EqualizerPreset copyWithGains(List<double> newGains) => EqualizerPreset(
    id: id,
    name: name,
    gains: newGains,
    isBuiltIn: isBuiltIn,
  );

  /// Create a custom copy with new name
  EqualizerPreset toCustom(String customId, String customName) => EqualizerPreset(
    id: customId,
    name: customName,
    gains: List.from(gains),
    isBuiltIn: false,
  );
}

/// Built-in equalizer presets
class BuiltInPresets {
  static const flat = EqualizerPreset(
    id: 'flat',
    name: 'Flat',
    gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    isBuiltIn: true,
  );

  static const bassBoost = EqualizerPreset(
    id: 'bass_boost',
    name: 'Bass Boost',
    gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
    isBuiltIn: true,
  );

  static const trebleBoost = EqualizerPreset(
    id: 'treble_boost',
    name: 'Treble Boost',
    gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6],
    isBuiltIn: true,
  );

  static const rock = EqualizerPreset(
    id: 'rock',
    name: 'Rock',
    gains: [4, 3, -1, -2, 0, 2, 4, 5, 5, 4],
    isBuiltIn: true,
  );

  static const pop = EqualizerPreset(
    id: 'pop',
    name: 'Pop',
    gains: [-1, 1, 3, 4, 3, 0, -1, 1, 2, 3],
    isBuiltIn: true,
  );

  static const jazz = EqualizerPreset(
    id: 'jazz',
    name: 'Jazz',
    gains: [3, 2, 0, 1, -1, -1, 0, 1, 3, 4],
    isBuiltIn: true,
  );

  static const classical = EqualizerPreset(
    id: 'classical',
    name: 'Classical',
    gains: [0, 0, 0, 0, 0, -1, -2, -2, -1, 2],
    isBuiltIn: true,
  );

  static const electronic = EqualizerPreset(
    id: 'electronic',
    name: 'Electronic',
    gains: [4, 4, 2, 0, -2, 1, 2, 4, 4, 4],
    isBuiltIn: true,
  );

  static const vocal = EqualizerPreset(
    id: 'vocal',
    name: 'Vocal',
    gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1],
    isBuiltIn: true,
  );

  static const hiphop = EqualizerPreset(
    id: 'hiphop',
    name: 'Hip-Hop',
    gains: [5, 4, 2, 1, -1, -1, 1, 0, 2, 3],
    isBuiltIn: true,
  );

  static const acoustic = EqualizerPreset(
    id: 'acoustic',
    name: 'Acoustic',
    gains: [3, 2, 1, 1, 2, 1, 2, 3, 2, 2],
    isBuiltIn: true,
  );

  static const loudness = EqualizerPreset(
    id: 'loudness',
    name: 'Loudness',
    gains: [5, 4, 1, 0, -1, -1, 0, 1, 4, 5],
    isBuiltIn: true,
  );

  /// All built-in presets
  static const List<EqualizerPreset> all = [
    flat,
    bassBoost,
    trebleBoost,
    rock,
    pop,
    jazz,
    classical,
    electronic,
    vocal,
    hiphop,
    acoustic,
    loudness,
  ];

  /// Get preset by ID
  static EqualizerPreset? getById(String id) {
    try {
      return all.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}
