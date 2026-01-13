import 'jellyfin_credentials.dart';

class JellyfinSession {
  JellyfinSession({
    required this.serverUrl,
    required this.username,
    required this.credentials,
    required this.deviceId,
    this.selectedLibraryId,
    this.selectedLibraryName,
    this.isDemo = false,
  });

  final String serverUrl;
  final String username;
  final JellyfinCredentials credentials;
  final String deviceId;
  final String? selectedLibraryId;
  final String? selectedLibraryName;
  final bool isDemo;

  static const _unset = Object();

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'credentials': credentials.toJson(),
      'deviceId': deviceId,
      'selectedLibraryId': selectedLibraryId,
      'selectedLibraryName': selectedLibraryName,
      'isDemo': isDemo,
    };
  }

  factory JellyfinSession.fromJson(Map<String, dynamic> json) {
    final rawCredentials =
        json['credentials'] as Map<String, dynamic>? ?? <String, dynamic>{};

    return JellyfinSession(
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      credentials: JellyfinCredentials.fromJson(rawCredentials),
      deviceId: json['deviceId'] as String? ?? 'unknown-device',
      selectedLibraryId: json['selectedLibraryId'] as String?,
      selectedLibraryName: json['selectedLibraryName'] as String?,
      isDemo: json['isDemo'] as bool? ?? false,
    );
  }

  JellyfinSession copyWith({
    String? serverUrl,
    String? username,
    JellyfinCredentials? credentials,
    String? deviceId,
    Object? selectedLibraryId = _unset,
    Object? selectedLibraryName = _unset,
    bool? isDemo,
  }) {
    return JellyfinSession(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      credentials: credentials ?? this.credentials,
      deviceId: deviceId ?? this.deviceId,
      selectedLibraryId: selectedLibraryId == _unset
          ? this.selectedLibraryId
          : selectedLibraryId as String?,
      selectedLibraryName: selectedLibraryName == _unset
          ? this.selectedLibraryName
          : selectedLibraryName as String?,
      isDemo: isDemo ?? this.isDemo,
    );
  }
}
