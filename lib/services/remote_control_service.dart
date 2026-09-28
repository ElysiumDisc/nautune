import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_auth_header.dart';
import '../jellyfin/server_uri.dart';

/// A command another Jellyfin client (the web dashboard, a phone app) sent to
/// this session over the server's websocket.
sealed class RemoteCommand {
  const RemoteCommand();
}

/// Transport: `PlayPause`, `Pause`, `Unpause`, `Stop`, `NextTrack`,
/// `PreviousTrack`, `Seek` (with [seekPosition]), `Rewind`, `FastForward`.
class RemotePlaystate extends RemoteCommand {
  const RemotePlaystate(this.command, {this.seekPosition});
  final String command;
  final Duration? seekPosition;
}

/// Play items: `PlayNow`, `PlayNext`, `PlayLast`, `PlayShuffle`,
/// `PlayInstantMix`.
class RemotePlay extends RemoteCommand {
  const RemotePlay(this.itemIds, this.playCommand, {this.startIndex = 0});
  final List<String> itemIds;
  final String playCommand;
  final int startIndex;
}

/// A general command, e.g. `SetVolume` {Volume: 0-100}, `SetRepeatMode`
/// {RepeatMode: RepeatNone|RepeatAll|RepeatOne}, `SetShuffleQueue`
/// {ShuffleMode: Sorted|Shuffle}, `ToggleMute`, `VolumeUp`, `VolumeDown`.
class RemoteGeneral extends RemoteCommand {
  const RemoteGeneral(this.name, this.arguments);
  final String name;
  final Map<String, String> arguments;
}

/// The server asks for a keep-alive every [interval].
class RemoteKeepAlive extends RemoteCommand {
  const RemoteKeepAlive(this.interval);
  final Duration interval;
}

/// Parse one websocket message; null for messages Nautune ignores.
RemoteCommand? parseRemoteMessage(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final type = decoded['MessageType'];
  final data = decoded['Data'];
  switch (type) {
    case 'ForceKeepAlive':
      final seconds = data is num ? data.toInt() : 60;
      return RemoteKeepAlive(Duration(seconds: seconds));
    case 'Playstate':
      if (data is! Map || data['Command'] is! String) return null;
      final ticks = data['SeekPositionTicks'];
      return RemotePlaystate(
        data['Command'] as String,
        seekPosition: ticks is num ? Duration(microseconds: ticks.toInt() ~/ 10) : null,
      );
    case 'Play':
      if (data is! Map) return null;
      final ids = data['ItemIds'];
      if (ids is! List || ids.isEmpty) return null;
      final start = data['StartIndex'];
      return RemotePlay(
        [for (final id in ids) if (id is String) id],
        data['PlayCommand'] is String ? data['PlayCommand'] as String : 'PlayNow',
        startIndex: start is num ? start.toInt() : 0,
      );
    case 'GeneralCommand':
      if (data is! Map || data['Name'] is! String) return null;
      final args = data['Arguments'];
      return RemoteGeneral(data['Name'] as String, {
        if (args is Map)
          for (final e in args.entries) '${e.key}': '${e.value}',
      });
  }
  return null;
}

/// Commands advertised to the server, so the dashboard shows the controls.
const List<String> kRemoteSupportedCommands = [
  'SetVolume',
  'VolumeUp',
  'VolumeDown',
  'Mute',
  'Unmute',
  'ToggleMute',
  'SetRepeatMode',
  'SetShuffleQueue',
  'PlayState',
  'Play',
  'PlayNext',
];

/// Lets other Jellyfin clients control Nautune: registers the session as
/// remote-controllable and listens on the server websocket, reconnecting
/// with backoff until [stop] is called.
class RemoteControlService {
  RemoteControlService({
    required this.serverUrl,
    required this.accessToken,
    required this.deviceId,
    required this.onCommand,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String serverUrl;
  final String accessToken;
  final String deviceId;
  final void Function(RemoteCommand command) onCommand;
  final http.Client _http;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _keepAlive;
  Timer? _reconnect;
  bool _running = false;
  int _failures = 0;

  bool get isConnected => _socket != null;

  /// Websocket URL for [serverUrl] (keeps reverse-proxy base paths).
  @visibleForTesting
  static Uri socketUri(String serverUrl, String token, String deviceId) {
    final http = buildServerUri(serverUrl, '/socket', {
      kJellyfinApiKeyQueryParam: token,
      'deviceId': deviceId,
    });
    return http.replace(scheme: http.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _registerCapabilities();
    await _connect();
  }

  void stop() {
    _running = false;
    _reconnect?.cancel();
    _reconnect = null;
    _closeSocket();
  }

  Map<String, String> get _headers => {
        kJellyfinAuthorizationHeader:
            nautuneAuthorization(deviceId: deviceId, token: accessToken),
        'Content-Type': 'application/json',
      };

  Future<void> _registerCapabilities() async {
    try {
      await _http
          .post(
            buildServerUri(serverUrl, '/Sessions/Capabilities/Full'),
            headers: _headers,
            body: jsonEncode({
              'PlayableMediaTypes': ['Audio'],
              'SupportedCommands': kRemoteSupportedCommands,
              'SupportsMediaControl': true,
              'SupportsPersistentIdentifier': true,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('🎛️ Remote control: capabilities not registered: $e');
    }
  }

  Future<void> _connect() async {
    if (!_running) return;
    try {
      final socket = await WebSocket.connect(
        socketUri(serverUrl, accessToken, deviceId).toString(),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _failures = 0;
      debugPrint('🎛️ Remote control connected');
      _subscription = socket.listen(
        (message) {
          if (message is! String) return;
          final command = parseRemoteMessage(message);
          if (command is RemoteKeepAlive) {
            _startKeepAlive(command.interval);
          } else if (command != null) {
            onCommand(command);
          }
        },
        onDone: _scheduleReconnect,
        onError: (Object e) => _scheduleReconnect(),
        cancelOnError: true,
      );
      // Ask the server for its keep-alive interval.
      _send('KeepAlive');
    } catch (e) {
      debugPrint('🎛️ Remote control connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _send(String messageType) {
    try {
      _socket?.add(jsonEncode({'MessageType': messageType}));
    } catch (_) {}
  }

  void _startKeepAlive(Duration serverInterval) {
    _keepAlive?.cancel();
    final half = serverInterval ~/ 2;
    _keepAlive = Timer.periodic(
      half < const Duration(seconds: 5) ? const Duration(seconds: 5) : half,
      (_) => _send('KeepAlive'),
    );
  }

  void _closeSocket() {
    _keepAlive?.cancel();
    _keepAlive = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
  }

  void _scheduleReconnect() {
    _closeSocket();
    if (!_running || _reconnect != null) return;
    _failures++;
    final seconds = (5 * (1 << (_failures - 1).clamp(0, 4))).clamp(5, 60);
    _reconnect = Timer(Duration(seconds: seconds), () {
      _reconnect = null;
      unawaited(_connect());
    });
  }
}
