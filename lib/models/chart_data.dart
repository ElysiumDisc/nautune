// Chart data model for Frets on Fire rhythm game.
// Contains note positions, timing, and metadata for a song chart.

/// Bonus types for golden power-up notes
enum BonusType {
  /// Auto-hits all notes in one random lane for 5 seconds with lightning visual
  lightningLane,

  /// Protects combo from 1-2 misses (doesn't reset streak)
  shield,

  /// 2x score multiplier for 5 seconds (stacks with combo for up to 8x!)
  doublePoints,

  /// Instantly jump to max 4x multiplier
  multiplierBoost,

  /// Forgiving timing window for 3 seconds - slightly off hits still count
  noteMagnet,
}

/// A single note in the chart
class ChartNote {
  /// When the note should be hit (milliseconds from song start)
  final int timestampMs;

  /// Which lane (0-4 for 5 frets, like Guitar Hero)
  final int lane;

  /// Duration in ms for hold notes (null = tap note)
  final int? sustainMs;

  /// Frequency band that triggered this note (for visual styling)
  final FrequencyBand band;

  /// Whether this is a golden bonus note
  final bool isBonus;

  /// The type of bonus this note gives (only valid if isBonus is true)
  final BonusType? bonusType;

  const ChartNote({
    required this.timestampMs,
    required this.lane,
    this.sustainMs,
    this.band = FrequencyBand.lowMid,
    this.isBonus = false,
    this.bonusType,
  });

  /// Whether this is a hold note
  bool get isHoldNote => sustainMs != null && sustainMs! > 0;

  /// Convert to JSON for caching
  Map<String, dynamic> toJson() => {
        'ts': timestampMs,
        'l': lane,
        if (sustainMs != null) 's': sustainMs,
        'b': band.index,
        if (isBonus) 'bonus': true,
        if (bonusType != null) 'bt': bonusType!.index,
      };

  /// Create from JSON
  factory ChartNote.fromJson(Map<String, dynamic> json) => ChartNote(
        timestampMs: json['ts'] as int,
        lane: json['l'] as int,
        sustainMs: json['s'] as int?,
        band: FrequencyBand.values[json['b'] as int? ?? 1],
        isBonus: json['bonus'] as bool? ?? false,
        bonusType: json['bt'] != null ? BonusType.values[json['bt'] as int] : null,
      );
}

/// Frequency band for visual styling (5 bands for 5 frets)
enum FrequencyBand {
  subBass,    // Lane 0 - Green: Sub-bass (< 100Hz) - kick drums
  bass,       // Lane 1 - Red: Bass (100-300Hz) - bass guitar
  lowMid,     // Lane 2 - Yellow: Low-mid (300-1000Hz) - vocals/guitar body
  highMid,    // Lane 3 - Blue: High-mid (1000-4000Hz) - vocals/guitar highs
  treble,     // Lane 4 - Orange: Treble (> 4000Hz) - cymbals, hi-hats
}

/// Complete chart data for a track
class ChartData {
  /// Unique ID for this chart (track ID + difficulty)
  final String id;

  /// Track ID this chart was generated for
  final String trackId;

  /// Track name for display
  final String trackName;

  /// Artist name for display
  final String artistName;

  /// All notes in the chart, sorted by timestamp
  final List<ChartNote> notes;

  /// Detected BPM (beats per minute)
  final double bpm;

  /// Track duration in milliseconds
  final int durationMs;

  /// When this chart was generated
  final DateTime generatedAt;

  /// High score for this chart (0 if never played)
  final int highScore;

  /// Max multiplier achieved
  final int maxMultiplier;

  /// Number of times played
  final int playCount;

  const ChartData({
    required this.id,
    required this.trackId,
    required this.trackName,
    required this.artistName,
    required this.notes,
    required this.bpm,
    required this.durationMs,
    required this.generatedAt,
    this.highScore = 0,
    this.maxMultiplier = 1,
    this.playCount = 0,
  });

  /// Create a copy with updated scores
  ChartData copyWithScore({
    int? highScore,
    int? maxMultiplier,
    int? playCount,
  }) =>
      ChartData(
        id: id,
        trackId: trackId,
        trackName: trackName,
        artistName: artistName,
        notes: notes,
        bpm: bpm,
        durationMs: durationMs,
        generatedAt: generatedAt,
        highScore: highScore ?? this.highScore,
        maxMultiplier: maxMultiplier ?? this.maxMultiplier,
        playCount: playCount ?? this.playCount,
      );

  /// Convert to JSON for caching
  Map<String, dynamic> toJson() => {
        'id': id,
        'trackId': trackId,
        'trackName': trackName,
        'artistName': artistName,
        'notes': notes.map((n) => n.toJson()).toList(),
        'bpm': bpm,
        'durationMs': durationMs,
        'generatedAt': generatedAt.toIso8601String(),
        'highScore': highScore,
        'maxMultiplier': maxMultiplier,
        'playCount': playCount,
      };

  /// Create from JSON
  factory ChartData.fromJson(Map<String, dynamic> json) => ChartData(
        id: json['id'] as String,
        trackId: json['trackId'] as String,
        trackName: json['trackName'] as String,
        artistName: json['artistName'] as String,
        notes: (json['notes'] as List)
            .map((n) => ChartNote.fromJson(n as Map<String, dynamic>))
            .toList(),
        bpm: (json['bpm'] as num).toDouble(),
        durationMs: json['durationMs'] as int,
        generatedAt: DateTime.parse(json['generatedAt'] as String),
        highScore: json['highScore'] as int? ?? 0,
        maxMultiplier: json['maxMultiplier'] as int? ?? 1,
        playCount: json['playCount'] as int? ?? 0,
      );

  /// Formatted duration string
  String get formattedDuration {
    final minutes = durationMs ~/ 60000;
    final seconds = (durationMs % 60000) ~/ 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Formatted BPM string
  String get formattedBpm => '${bpm.round()} BPM';

  /// Formatted high score
  String get formattedHighScore {
    if (highScore >= 1000000) {
      return '${(highScore / 1000000).toStringAsFixed(1)}M';
    } else if (highScore >= 1000) {
      return '${(highScore / 1000).toStringAsFixed(1)}K';
    }
    return highScore.toString();
  }
}

/// Game session result
class GameResult {
  final int score;
  final int maxCombo;
  final int maxMultiplier;
  final int perfectHits;
  final int goodHits;
  final int missedNotes;
  final int totalNotes;
  final bool isNewHighScore;

  const GameResult({
    required this.score,
    required this.maxCombo,
    required this.maxMultiplier,
    required this.perfectHits,
    required this.goodHits,
    required this.missedNotes,
    required this.totalNotes,
    this.isNewHighScore = false,
  });

  /// Accuracy percentage (0.0 - 100.0)
  double get accuracy {
    if (totalNotes == 0) return 0;
    return ((perfectHits + goodHits) / totalNotes) * 100;
  }

  /// Grade based on accuracy
  String get grade {
    if (accuracy >= 95) return 'S';
    if (accuracy >= 90) return 'A';
    if (accuracy >= 80) return 'B';
    if (accuracy >= 70) return 'C';
    if (accuracy >= 60) return 'D';
    return 'F';
  }
}
