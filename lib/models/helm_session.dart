/// Represents a remote Jellyfin session that can be controlled via Helm Mode.
class HelmSession {
  const HelmSession({
    required this.sessionId,
    required this.deviceName,
    required this.clientName,
    required this.userName,
    this.nowPlayingItemName,
    this.nowPlayingArtist,
    this.isPaused = false,
    this.positionTicks = 0,
    this.runtimeTicks = 0,
  });

  final String sessionId;
  final String deviceName;
  final String clientName;
  final String userName;
  final String? nowPlayingItemName;
  final String? nowPlayingArtist;
  final bool isPaused;
  final int positionTicks;
  final int runtimeTicks;

  /// Whether this session is currently playing something.
  bool get hasNowPlaying => nowPlayingItemName != null;

  /// Current position as a Duration.
  Duration get position => Duration(microseconds: positionTicks ~/ 10);

  /// Total runtime as a Duration.
  Duration get runtime => Duration(microseconds: runtimeTicks ~/ 10);

  /// Parse from the Jellyfin /Sessions response JSON.
  factory HelmSession.fromSessionJson(Map<String, dynamic> json) {
    final nowPlaying = json['NowPlayingItem'] as Map<String, dynamic>?;
    final playState = json['PlayState'] as Map<String, dynamic>?;

    return HelmSession(
      sessionId: json['Id'] as String? ?? '',
      deviceName: json['DeviceName'] as String? ?? 'Unknown Device',
      clientName: json['Client'] as String? ?? 'Unknown Client',
      userName: json['UserName'] as String? ?? '',
      nowPlayingItemName: nowPlaying?['Name'] as String?,
      nowPlayingArtist: (nowPlaying?['Artists'] as List<dynamic>?)?.join(', '),
      isPaused: playState?['IsPaused'] as bool? ?? false,
      positionTicks: playState?['PositionTicks'] as int? ?? 0,
      runtimeTicks: nowPlaying?['RunTimeTicks'] as int? ?? 0,
    );
  }

  HelmSession copyWith({
    String? nowPlayingItemName,
    String? nowPlayingArtist,
    bool? isPaused,
    int? positionTicks,
    int? runtimeTicks,
  }) {
    return HelmSession(
      sessionId: sessionId,
      deviceName: deviceName,
      clientName: clientName,
      userName: userName,
      nowPlayingItemName: nowPlayingItemName ?? this.nowPlayingItemName,
      nowPlayingArtist: nowPlayingArtist ?? this.nowPlayingArtist,
      isPaused: isPaused ?? this.isPaused,
      positionTicks: positionTicks ?? this.positionTicks,
      runtimeTicks: runtimeTicks ?? this.runtimeTicks,
    );
  }

  @override
  String toString() => 'HelmSession($deviceName, $clientName, $userName)';
}
