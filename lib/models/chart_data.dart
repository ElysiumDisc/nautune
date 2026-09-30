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
  /// Version of the chart generator output. Bump whenever the generator
  /// changes in a way that should invalidate cached charts.
  static const int currentVersion = 2;

  /// Generator version this chart was built with (1 = pre-versioning).
  final int version;

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

  /// Notes actually hit across all plays
  final int totalNotesHit;

  const ChartData({
    this.version = currentVersion,
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
    this.totalNotesHit = 0,
  });

  /// Whether this chart was built by the current generator version.
  bool get isCurrentVersion => version == currentVersion;

  /// Number of notes that count toward accuracy (golden bonus notes excluded).
  int get scorableNoteCount => notes.where((n) => !n.isBonus).length;

  /// Create a copy with updated scores
  ChartData copyWithScore({
    int? highScore,
    int? maxMultiplier,
    int? playCount,
    int? totalNotesHit,
  }) =>
      ChartData(
        version: version,
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
        totalNotesHit: totalNotesHit ?? this.totalNotesHit,
      );

  /// Convert to JSON for caching
  Map<String, dynamic> toJson() => {
        'v': version,
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
        'hits': totalNotesHit,
      };

  /// Create from JSON
  factory ChartData.fromJson(Map<String, dynamic> json) => ChartData(
        version: json['v'] as int? ?? 1,
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
        totalNotesHit: json['hits'] as int? ?? 0,
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

/// Tracks which notes of a chart have been judged (hit, collected or missed)
/// during one play-through.
///
/// Every note is judged exactly once, so chord partners are never skipped and
/// auto-hits can't double count. [cursor] is the first unjudged note; all
/// notes before it are judged.
class ChartJudge {
  ChartJudge(this.notes) : _judged = List<bool>.filled(notes.length, false);

  /// Notes sorted by timestamp.
  final List<ChartNote> notes;
  final List<bool> _judged;
  int _cursor = 0;

  /// Index of the first unjudged note.
  int get cursor => _cursor;

  bool isJudged(int index) => _judged[index];

  /// Mark [index] as judged and move the cursor past judged notes.
  void markJudged(int index) {
    _judged[index] = true;
    while (_cursor < notes.length && _judged[_cursor]) {
      _cursor++;
    }
  }

  /// Earliest unjudged note in [lane] within [windowMs] of [nowMs], or -1.
  int findHittable(int lane, int nowMs, int windowMs, {bool includeBonus = true}) {
    for (int i = _cursor; i < notes.length; i++) {
      final note = notes[i];
      // Sorted by time: nothing later can be in the window.
      if (note.timestampMs > nowMs + windowMs) break;
      if (_judged[i] || note.lane != lane) continue;
      if (!includeBonus && note.isBonus) continue;
      if ((note.timestampMs - nowMs).abs() <= windowMs) return i;
    }
    return -1;
  }

  /// Judge every unjudged note whose late window ([windowMs]) has passed at
  /// [nowMs] and return their indices, oldest first.
  List<int> expire(int nowMs, int windowMs) {
    final expired = <int>[];
    for (int i = _cursor; i < notes.length; i++) {
      if (notes[i].timestampMs >= nowMs - windowMs) break;
      if (!_judged[i]) expired.add(i);
    }
    for (final i in expired) {
      markJudged(i);
    }
    return expired;
  }

  /// Unjudged notes that count toward accuracy (bonus notes excluded).
  int get remainingScorable {
    int count = 0;
    for (int i = _cursor; i < notes.length; i++) {
      if (!_judged[i] && !notes[i].isBonus) count++;
    }
    return count;
  }
}
