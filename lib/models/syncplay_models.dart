import '../jellyfin/jellyfin_track.dart';

/// Represents a SyncPlay group/session
class SyncPlayGroup {
  const SyncPlayGroup({
    required this.groupId,
    required this.groupName,
    required this.participants,
    required this.state,
    this.lastUpdatedAt,
  });

  final String groupId;
  final String groupName;
  final List<SyncPlayParticipant> participants;
  final SyncPlayState state;
  final DateTime? lastUpdatedAt;

  factory SyncPlayGroup.fromJson(Map<String, dynamic> json) {
    final participantsJson = json['Participants'] as List<dynamic>? ?? [];

    return SyncPlayGroup(
      groupId: json['GroupId'] as String? ?? '',
      groupName: json['GroupName'] as String? ?? 'Collaborative Playlist',
      participants: participantsJson
          .whereType<Map<String, dynamic>>()
          .map(SyncPlayParticipant.fromJson)
          .toList(),
      state: SyncPlayState.fromString(json['State'] as String?),
      lastUpdatedAt: json['LastUpdatedAt'] != null
          ? DateTime.tryParse(json['LastUpdatedAt'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'GroupId': groupId,
    'GroupName': groupName,
    'Participants': participants.map((p) => p.toJson()).toList(),
    'State': state.name,
    'LastUpdatedAt': lastUpdatedAt?.toIso8601String(),
  };

  SyncPlayGroup copyWith({
    String? groupId,
    String? groupName,
    List<SyncPlayParticipant>? participants,
    SyncPlayState? state,
    DateTime? lastUpdatedAt,
  }) {
    return SyncPlayGroup(
      groupId: groupId ?? this.groupId,
      groupName: groupName ?? this.groupName,
      participants: participants ?? this.participants,
      state: state ?? this.state,
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  /// Returns the group leader (Captain)
  SyncPlayParticipant? get leader {
    for (final p in participants) {
      if (p.isGroupLeader) return p;
    }
    return null;
  }

  /// Returns the number of active participants
  int get participantCount => participants.length;
}

/// Represents a participant in a SyncPlay session
class SyncPlayParticipant {
  const SyncPlayParticipant({
    required this.oderId,
    required this.userId,
    required this.username,
    this.userImageTag,
    required this.isGroupLeader,
    this.isBuffering = false,
    this.isReady = true,
  });

  final String oderId; // Unique order ID for this participant instance
  final String userId;
  final String username;
  final String? userImageTag;
  final bool isGroupLeader;
  final bool isBuffering;
  final bool isReady;

  factory SyncPlayParticipant.fromJson(Map<String, dynamic> json) {
    return SyncPlayParticipant(
      oderId: json['OderId'] as String? ?? json['UserId'] as String? ?? '',
      userId: json['UserId'] as String? ?? '',
      username: json['UserName'] as String? ?? 'Unknown',
      userImageTag: json['UserImageTag'] as String?,
      isGroupLeader: json['IsGroupLeader'] as bool? ?? false,
      isBuffering: json['IsBuffering'] as bool? ?? false,
      isReady: json['IsReady'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'OderId': oderId,
    'UserId': userId,
    'UserName': username,
    'UserImageTag': userImageTag,
    'IsGroupLeader': isGroupLeader,
    'IsBuffering': isBuffering,
    'IsReady': isReady,
  };

  SyncPlayParticipant copyWith({
    String? oderId,
    String? userId,
    String? username,
    String? userImageTag,
    bool? isGroupLeader,
    bool? isBuffering,
    bool? isReady,
  }) {
    return SyncPlayParticipant(
      oderId: oderId ?? this.oderId,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      userImageTag: userImageTag ?? this.userImageTag,
      isGroupLeader: isGroupLeader ?? this.isGroupLeader,
      isBuffering: isBuffering ?? this.isBuffering,
      isReady: isReady ?? this.isReady,
    );
  }

  /// Returns the role of this participant
  SyncPlayRole get role => isGroupLeader ? SyncPlayRole.captain : SyncPlayRole.sailor;
}

/// A track in the SyncPlay queue with attribution info
class SyncPlayTrack {
  const SyncPlayTrack({
    required this.track,
    required this.addedByUserId,
    required this.addedByUsername,
    this.addedByImageTag,
    required this.playlistItemId,
  });

  final JellyfinTrack track;
  final String addedByUserId;
  final String addedByUsername;
  final String? addedByImageTag;
  final String playlistItemId; // Unique ID for this queue item

  factory SyncPlayTrack.fromJson(
    Map<String, dynamic> json, {
    String? serverUrl,
    String? token,
    String? userId,
  }) {
    final trackJson = json['Item'] as Map<String, dynamic>? ?? json;

    return SyncPlayTrack(
      track: JellyfinTrack.fromJson(
        trackJson,
        serverUrl: serverUrl,
        token: token,
        userId: userId,
      ),
      addedByUserId: json['AddedByUserId'] as String? ?? '',
      addedByUsername: json['AddedByUserName'] as String? ?? 'Unknown',
      addedByImageTag: json['AddedByUserImageTag'] as String?,
      playlistItemId: json['PlaylistItemId'] as String? ?? trackJson['Id'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'Item': track.toStorageJson(),
    'AddedByUserId': addedByUserId,
    'AddedByUserName': addedByUsername,
    'AddedByUserImageTag': addedByImageTag,
    'PlaylistItemId': playlistItemId,
  };

  SyncPlayTrack copyWith({
    JellyfinTrack? track,
    String? addedByUserId,
    String? addedByUsername,
    String? addedByImageTag,
    String? playlistItemId,
  }) {
    return SyncPlayTrack(
      track: track ?? this.track,
      addedByUserId: addedByUserId ?? this.addedByUserId,
      addedByUsername: addedByUsername ?? this.addedByUsername,
      addedByImageTag: addedByImageTag ?? this.addedByImageTag,
      playlistItemId: playlistItemId ?? this.playlistItemId,
    );
  }
}

/// Current playback state of the SyncPlay session
enum SyncPlayState {
  idle,
  waiting,
  playing,
  paused,
  buffering;

  static SyncPlayState fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'playing':
        return SyncPlayState.playing;
      case 'paused':
        return SyncPlayState.paused;
      case 'waiting':
        return SyncPlayState.waiting;
      case 'buffering':
        return SyncPlayState.buffering;
      default:
        return SyncPlayState.idle;
    }
  }

  bool get isActive => this == playing || this == paused || this == buffering;
}

/// Role of a user in the SyncPlay session
enum SyncPlayRole {
  captain, // Host - plays audio
  sailor; // Guest - UI sync only

  bool get isCaptain => this == captain;
  bool get isSailor => this == sailor;
}

/// Full state of a SyncPlay session including queue and playback info
class SyncPlaySession {
  const SyncPlaySession({
    required this.group,
    required this.queue,
    required this.currentTrackIndex,
    required this.positionTicks,
    required this.role,
    this.isPaused = false,
    this.isBuffering = false,
    this.lastSyncTime,
  });

  final SyncPlayGroup group;
  final List<SyncPlayTrack> queue;
  final int currentTrackIndex;
  final int positionTicks; // Position in Jellyfin ticks (10,000 ticks = 1 ms)
  final SyncPlayRole role;
  final bool isPaused;
  final bool isBuffering;
  final DateTime? lastSyncTime;

  /// Get current track if available
  SyncPlayTrack? get currentTrack {
    if (currentTrackIndex >= 0 && currentTrackIndex < queue.length) {
      return queue[currentTrackIndex];
    }
    return null;
  }

  /// Get position as Duration
  Duration get position => Duration(microseconds: positionTicks ~/ 10);

  /// Check if this user is the captain
  bool get isCaptain => role == SyncPlayRole.captain;

  /// Get upcoming tracks (excluding current)
  List<SyncPlayTrack> get upNext {
    if (currentTrackIndex < 0 || currentTrackIndex >= queue.length - 1) {
      return const [];
    }
    return queue.sublist(currentTrackIndex + 1);
  }

  factory SyncPlaySession.fromJson(
    Map<String, dynamic> json, {
    String? serverUrl,
    String? token,
    String? userId,
    required SyncPlayRole role,
  }) {
    final groupJson = json['Group'] as Map<String, dynamic>? ?? json;
    final queueJson = json['Queue'] as List<dynamic>? ??
                      json['PlayQueue']?['Items'] as List<dynamic>? ?? [];

    return SyncPlaySession(
      group: SyncPlayGroup.fromJson(groupJson),
      queue: queueJson
          .whereType<Map<String, dynamic>>()
          .map((item) => SyncPlayTrack.fromJson(
                item,
                serverUrl: serverUrl,
                token: token,
                userId: userId,
              ))
          .toList(),
      currentTrackIndex: json['PlayingItemIndex'] as int? ??
                         json['PlayQueue']?['PlayingItemIndex'] as int? ?? -1,
      positionTicks: json['PositionTicks'] as int? ?? 0,
      role: role,
      isPaused: json['IsPaused'] as bool? ?? false,
      isBuffering: json['IsBuffering'] as bool? ?? false,
      lastSyncTime: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'Group': group.toJson(),
    'Queue': queue.map((t) => t.toJson()).toList(),
    'PlayingItemIndex': currentTrackIndex,
    'PositionTicks': positionTicks,
    'Role': role.name,
    'IsPaused': isPaused,
    'IsBuffering': isBuffering,
    'LastSyncTime': lastSyncTime?.toIso8601String(),
  };

  SyncPlaySession copyWith({
    SyncPlayGroup? group,
    List<SyncPlayTrack>? queue,
    int? currentTrackIndex,
    int? positionTicks,
    SyncPlayRole? role,
    bool? isPaused,
    bool? isBuffering,
    DateTime? lastSyncTime,
  }) {
    return SyncPlaySession(
      group: group ?? this.group,
      queue: queue ?? this.queue,
      currentTrackIndex: currentTrackIndex ?? this.currentTrackIndex,
      positionTicks: positionTicks ?? this.positionTicks,
      role: role ?? this.role,
      isPaused: isPaused ?? this.isPaused,
      isBuffering: isBuffering ?? this.isBuffering,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
    );
  }
}

/// Enum for queue operation modes
enum SyncPlayQueueMode {
  queue, // Add to end
  queueNext, // Add after current
  setCurrentItem, // Set specific item as current
}
