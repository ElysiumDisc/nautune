import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import 'audio_player_service.dart';

/// Persistent WebSocket connection to the Jellyfin server that makes this
/// Nautune instance "controllable" — i.e. another device running Helm Mode
/// can send play/pause/next/prev/seek commands that are received here.
///
/// On connect, it also registers session capabilities via
/// POST /Sessions/Capabilities/Full so the server knows we accept commands.
class RemoteControlService extends ChangeNotifier {
  RemoteControlService({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
    required String deviceId,
    required JellyfinService jellyfinService,
    required AudioPlayerService audioPlayerService,
  })  : _client = client,
        _credentials = credentials,
        _deviceId = deviceId,
        _jellyfinService = jellyfinService,
        _audioPlayerService = audioPlayerService;

  final JellyfinClient _client;
  final JellyfinCredentials _credentials;
  final String _deviceId;
  final JellyfinService _jellyfinService;
  final AudioPlayerService _audioPlayerService;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isDisposed = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 15;
  static const Duration _keepAliveInterval = Duration(seconds: 20);

  bool get isConnected => _isConnected;

  /// Connect to the Jellyfin WebSocket and register capabilities.
  Future<void> connect() async {
    if (_isConnected || _isConnecting || _isDisposed) return;

    _isConnecting = true;

    try {
      // Register capabilities first so the server knows we accept commands
      await _client.reportCapabilities(_credentials);
      debugPrint('RemoteControl: Capabilities registered');
    } catch (e) {
      debugPrint('RemoteControl: Failed to register capabilities: $e');
      // Continue anyway — WebSocket might still work
    }

    try {
      await _establishConnection();
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _establishConnection() async {
    if (_isDisposed) return;

    final wsUrl = _buildWebSocketUrl();
    debugPrint('RemoteControl: Connecting to WebSocket...');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
      await _channel!.ready;

      _isConnected = true;
      _reconnectAttempts = 0;
      notifyListeners();
      debugPrint('RemoteControl: Connected');

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      _startKeepAlive();
    } catch (e) {
      debugPrint('RemoteControl: Connection failed: $e');
      _isConnected = false;
      if (!_isDisposed) {
        _scheduleReconnect();
      }
    }
  }

  String _buildWebSocketUrl() {
    var url = _client.serverUrl;
    if (url.startsWith('https://')) {
      url = url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'ws://');
    }

    final uri = Uri.parse(url).resolve('/socket');
    return uri.replace(queryParameters: {
      'api_key': _credentials.accessToken,
      'deviceId': _deviceId,
    }).toString();
  }

  void _onMessage(dynamic message) {
    try {
      final jsonStr = message is String
          ? message
          : utf8.decode(message as List<int>);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final messageType = json['MessageType'] as String?;

      switch (messageType) {
        case 'ForceKeepAlive':
        case 'KeepAlive':
          _sendKeepAlive();
          break;

        case 'Playstate':
          _handlePlaystateCommand(json['Data'] as Map<String, dynamic>?);
          break;

        case 'Play':
          _handlePlayCommand(json['Data'] as Map<String, dynamic>?);
          break;

        case 'GeneralCommand':
          _handleGeneralCommand(json['Data'] as Map<String, dynamic>?);
          break;

        // Ignore SyncPlay messages — handled by SyncPlayWebSocket
        case 'SyncPlayGroupUpdate':
        case 'SyncPlayCommand':
          break;

        default:
          if (messageType != null &&
              !const {'Sessions', 'UserDataChanged', 'LibraryChanged', 'ScheduledTasksInfo', 'ActivityLogEntry'}
                  .contains(messageType)) {
            debugPrint('RemoteControl: Unhandled message type: $messageType');
          }
          break;
      }
    } catch (e) {
      debugPrint('RemoteControl: Failed to parse message: $e');
    }
  }

  /// Handle Playstate commands: Pause, Unpause, PlayPause, NextTrack,
  /// PreviousTrack, Seek, Stop.
  void _handlePlaystateCommand(Map<String, dynamic>? data) {
    if (data == null) return;

    final command = data['Command'] as String?;
    debugPrint('RemoteControl: Playstate command: $command');

    switch (command) {
      case 'PlayPause':
        if (_audioPlayerService.isPlaying) {
          _audioPlayerService.pause();
        } else {
          _audioPlayerService.resume();
        }
        break;

      case 'Pause':
        _audioPlayerService.pause();
        break;

      case 'Unpause':
        _audioPlayerService.resume();
        break;

      case 'NextTrack':
        _audioPlayerService.skipToNext();
        break;

      case 'PreviousTrack':
        _audioPlayerService.skipToPrevious();
        break;

      case 'Seek':
        final ticks = data['SeekPositionTicks'] as int?;
        if (ticks != null) {
          final position = Duration(microseconds: ticks ~/ 10);
          _audioPlayerService.seek(position);
        }
        break;

      case 'Stop':
        _audioPlayerService.stop();
        break;

      case 'Rewind':
        _seekRelative(const Duration(seconds: -15));
        break;

      case 'FastForward':
        _seekRelative(const Duration(seconds: 15));
        break;
    }
  }

  /// Handle Play commands: PlayNow, PlayNext, PlayLast (play specific items).
  Future<void> _handlePlayCommand(Map<String, dynamic>? data) async {
    if (data == null) return;

    final playCommand = data['PlayCommand'] as String?;
    final itemIdsRaw = data['ItemIds'] as List<dynamic>?;
    final startIndex = data['StartIndex'] as int?;
    final startPositionTicks = data['StartPositionTicks'] as int?;

    if (itemIdsRaw == null || itemIdsRaw.isEmpty) return;

    final itemIds = itemIdsRaw.map((e) => e.toString()).toList();
    debugPrint('RemoteControl: Play command: $playCommand, ${itemIds.length} items');

    try {
      // Resolve item IDs to tracks
      final tracks = <JellyfinTrack>[];
      for (final id in itemIds) {
        final track = await _jellyfinService.getTrack(id);
        if (track != null) tracks.add(track);
      }

      if (tracks.isEmpty) return;

      switch (playCommand) {
        case 'PlayNow':
          final startAt = (startIndex != null && startIndex < tracks.length)
              ? startIndex
              : 0;
          await _audioPlayerService.playTrack(
            tracks[startAt],
            queueContext: tracks.length > 1
                ? List.from(tracks)
                : null,
          );
          // Seek to start position if provided
          if (startPositionTicks != null && startPositionTicks > 0) {
            await _audioPlayerService.seek(
              Duration(microseconds: startPositionTicks ~/ 10),
            );
          }
          break;

        case 'PlayNext':
          _audioPlayerService.playNext(List.from(tracks));
          break;

        case 'PlayLast':
          _audioPlayerService.addToQueue(List.from(tracks));
          break;
      }
    } catch (e) {
      debugPrint('RemoteControl: Failed to handle Play command: $e');
    }
  }

  /// Handle GeneralCommand: SetVolume, Mute, Unmute, ToggleMute.
  void _handleGeneralCommand(Map<String, dynamic>? data) {
    if (data == null) return;

    final name = data['Name'] as String?;
    final arguments = data['Arguments'] as Map<String, dynamic>?;
    debugPrint('RemoteControl: GeneralCommand: $name');

    switch (name) {
      case 'SetVolume':
        final volume = arguments?['Volume'];
        if (volume != null) {
          final v = double.tryParse(volume.toString());
          if (v != null) {
            _audioPlayerService.setVolume(v / 100.0);
          }
        }
        break;

      // Mute/unmute would need volume tracking; log for now
      case 'Mute':
      case 'Unmute':
      case 'ToggleMute':
        debugPrint('RemoteControl: $name not yet implemented');
        break;
    }
  }

  void _seekRelative(Duration offset) {
    final current = _audioPlayerService.currentPosition;
    final target = current + offset;
    _audioPlayerService.seek(
      target.isNegative ? Duration.zero : target,
    );
  }

  // ============ Connection management ============

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (_) {
      _sendKeepAlive();
    });
  }

  void _sendKeepAlive() {
    if (_channel == null || !_isConnected) return;
    try {
      _channel!.sink.add(jsonEncode({'MessageType': 'KeepAlive'}));
    } catch (e) {
      debugPrint('RemoteControl: Failed to send KeepAlive: $e');
    }
  }

  void _onError(Object error) {
    debugPrint('RemoteControl: WebSocket error: $error');
    _handleDisconnection();
  }

  void _onDone() {
    debugPrint('RemoteControl: WebSocket closed');
    _handleDisconnection();
  }

  void _handleDisconnection() {
    _isConnected = false;
    _keepAliveTimer?.cancel();
    if (!_isDisposed) {
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('RemoteControl: Max reconnect attempts reached');
      return;
    }

    final delay = Duration(seconds: 1 << _reconnectAttempts.clamp(0, 5));
    debugPrint('RemoteControl: Reconnecting in ${delay.inSeconds}s '
        '(attempt ${_reconnectAttempts + 1})');

    _reconnectTimer = Timer(delay, () async {
      _reconnectAttempts++;
      _isConnecting = false; // Allow re-entry
      await _establishConnection();
    });
  }

  /// Disconnect from the WebSocket.
  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectAttempts = _maxReconnectAttempts;

    await _subscription?.cancel();
    _subscription = null;

    await _channel?.sink.close();
    _channel = null;

    _isConnected = false;
    _isConnecting = false;

    if (!_isDisposed) {
      notifyListeners();
    }

    debugPrint('RemoteControl: Disconnected');
  }

  @override
  void dispose() {
    _isDisposed = true;
    disconnect();
    super.dispose();
  }
}
