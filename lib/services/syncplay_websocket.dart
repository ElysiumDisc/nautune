import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../jellyfin/jellyfin_credentials.dart';
import '../models/syncplay_models.dart';

/// WebSocket message types from Jellyfin SyncPlay
enum SyncPlayMessageType {
  // Session events
  groupJoined,
  groupLeft,
  groupStateUpdate,
  userJoined,
  userLeft,

  // Playback commands
  playPause,
  seek,
  setPlaylistItem,

  // Queue changes
  queueUpdate,
  playlistItemAdded,
  playlistItemRemoved,
  playlistItemMoved,

  // Sync events
  syncPlayReady,
  syncPlayBuffering,
  syncPlayPing,

  // Keep-alive
  forceKeepAlive,
  keepAlive,

  // Unknown
  unknown;

  static SyncPlayMessageType fromString(String? value) {
    switch (value) {
      case 'SyncPlayGroupJoined':
        return SyncPlayMessageType.groupJoined;
      case 'SyncPlayGroupLeft':
        return SyncPlayMessageType.groupLeft;
      case 'SyncPlayGroupState':
      case 'SyncPlayGroupUpdate':
        return SyncPlayMessageType.groupStateUpdate;
      case 'SyncPlayUserJoined':
        return SyncPlayMessageType.userJoined;
      case 'SyncPlayUserLeft':
        return SyncPlayMessageType.userLeft;
      case 'SyncPlayPlayPause':
        return SyncPlayMessageType.playPause;
      case 'SyncPlaySeek':
        return SyncPlayMessageType.seek;
      case 'SyncPlaySetPlaylistItem':
        return SyncPlayMessageType.setPlaylistItem;
      case 'SyncPlayQueueUpdate':
        return SyncPlayMessageType.queueUpdate;
      case 'SyncPlayPlaylistItemAdded':
        return SyncPlayMessageType.playlistItemAdded;
      case 'SyncPlayPlaylistItemRemoved':
        return SyncPlayMessageType.playlistItemRemoved;
      case 'SyncPlayPlaylistItemMoved':
        return SyncPlayMessageType.playlistItemMoved;
      case 'SyncPlayReady':
        return SyncPlayMessageType.syncPlayReady;
      case 'SyncPlayBuffering':
        return SyncPlayMessageType.syncPlayBuffering;
      case 'SyncPlayPing':
        return SyncPlayMessageType.syncPlayPing;
      case 'ForceKeepAlive':
        return SyncPlayMessageType.forceKeepAlive;
      case 'KeepAlive':
        return SyncPlayMessageType.keepAlive;
      default:
        return SyncPlayMessageType.unknown;
    }
  }
}

/// A SyncPlay WebSocket message
class SyncPlayMessage {
  const SyncPlayMessage({
    required this.type,
    required this.data,
    this.messageId,
  });

  final SyncPlayMessageType type;
  final Map<String, dynamic> data;
  final String? messageId;

  factory SyncPlayMessage.fromJson(Map<String, dynamic> json) {
    final messageType = json['MessageType'] as String?;

    // Handle case where Data might not be a Map (can be int, String, List, etc.)
    final messageData = json['Data'];
    final Map<String, dynamic> data;
    if (messageData is Map<String, dynamic>) {
      data = messageData;
    } else if (messageData is Map) {
      // Handle Map<dynamic, dynamic> by converting keys to strings
      data = messageData.map((k, v) => MapEntry(k.toString(), v));
    } else {
      data = <String, dynamic>{};
    }

    return SyncPlayMessage(
      type: SyncPlayMessageType.fromString(messageType),
      data: data,
      messageId: json['MessageId'] as String?,
    );
  }

  @override
  String toString() => 'SyncPlayMessage(type: $type, data: $data)';
}

/// Handles WebSocket connection to Jellyfin for real-time SyncPlay updates
class SyncPlayWebSocket {
  SyncPlayWebSocket({
    required this.serverUrl,
    required this.credentials,
    required this.deviceId,
  });

  final String serverUrl;
  final JellyfinCredentials credentials;
  final String deviceId;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isDisposed = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _keepAliveInterval = Duration(seconds: 30);

  // Message stream
  final _messageController = StreamController<SyncPlayMessage>.broadcast();
  Stream<SyncPlayMessage> get messageStream => _messageController.stream;

  // Connection state stream
  final _connectionStateController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  bool get isConnected => _isConnected;

  /// Connect to the Jellyfin WebSocket
  Future<void> connect() async {
    if (_isConnected || _isConnecting) {
      debugPrint('SyncPlayWebSocket: Already connected or connecting');
      return;
    }

    _isConnecting = true;
    _reconnectAttempts = 0;

    try {
      await _establishConnection();
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _establishConnection() async {
    if (_isDisposed) return;

    final wsUrl = _buildWebSocketUrl();
    debugPrint('SyncPlayWebSocket: Connecting to $wsUrl');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // Wait for connection to be established
      await _channel!.ready;

      _isConnected = true;
      if (!_isDisposed) {
        _connectionStateController.add(true);
      }
      debugPrint('SyncPlayWebSocket: Connected successfully');

      // Listen for messages
      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      // Start keep-alive timer
      _startKeepAlive();

      // Reset reconnect attempts on successful connection
      _reconnectAttempts = 0;
    } catch (error) {
      debugPrint('SyncPlayWebSocket: Connection failed: $error');
      _isConnected = false;
      if (!_isDisposed) {
        _connectionStateController.add(false);
        _scheduleReconnect();
      }
    }
  }

  String _buildWebSocketUrl() {
    // Convert HTTP(S) URL to WS(S) URL
    var url = serverUrl;
    if (url.startsWith('https://')) {
      url = url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'ws://');
    }

    // Build the WebSocket URL with authentication
    final uri = Uri.parse(url).resolve('/socket');
    return uri.replace(queryParameters: {
      'api_key': credentials.accessToken,
      'deviceId': deviceId,
    }).toString();
  }

  void _onMessage(dynamic message) {
    try {
      final jsonStr = message is String ? message : utf8.decode(message as List<int>);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final syncPlayMessage = SyncPlayMessage.fromJson(json);

      // Handle keep-alive internally
      if (syncPlayMessage.type == SyncPlayMessageType.forceKeepAlive ||
          syncPlayMessage.type == SyncPlayMessageType.keepAlive) {
        _sendKeepAlive();
        return;
      }

      // Filter for SyncPlay-related messages
      if (_isSyncPlayMessage(syncPlayMessage.type) && !_isDisposed) {
        debugPrint('SyncPlayWebSocket: Received ${syncPlayMessage.type}');
        _messageController.add(syncPlayMessage);
      }
    } catch (error) {
      debugPrint('SyncPlayWebSocket: Failed to parse message: $error');
    }
  }

  bool _isSyncPlayMessage(SyncPlayMessageType type) {
    return type != SyncPlayMessageType.unknown &&
           type != SyncPlayMessageType.forceKeepAlive &&
           type != SyncPlayMessageType.keepAlive;
  }

  void _onError(Object error) {
    debugPrint('SyncPlayWebSocket: Error: $error');
    _handleDisconnection();
  }

  void _onDone() {
    debugPrint('SyncPlayWebSocket: Connection closed');
    _handleDisconnection();
  }

  void _handleDisconnection() {
    _isConnected = false;
    _stopKeepAlive();
    if (!_isDisposed) {
      _connectionStateController.add(false);
      _scheduleReconnect();
    }
  }

  void _startKeepAlive() {
    _stopKeepAlive();
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (_) {
      _sendKeepAlive();
    });
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  void _sendKeepAlive() {
    send({'MessageType': 'KeepAlive'});
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('SyncPlayWebSocket: Max reconnect attempts reached');
      return;
    }

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s
    final delay = Duration(seconds: 1 << _reconnectAttempts);
    debugPrint('SyncPlayWebSocket: Reconnecting in ${delay.inSeconds}s (attempt ${_reconnectAttempts + 1})');

    _reconnectTimer = Timer(delay, () async {
      _reconnectAttempts++;
      await _establishConnection();
    });
  }

  /// Send a message to the WebSocket
  void send(Map<String, dynamic> message) {
    if (!_isConnected || _channel == null) {
      debugPrint('SyncPlayWebSocket: Cannot send - not connected');
      return;
    }

    try {
      final jsonStr = jsonEncode(message);
      _channel!.sink.add(jsonStr);
    } catch (error) {
      debugPrint('SyncPlayWebSocket: Failed to send message: $error');
    }
  }

  /// Disconnect from the WebSocket
  Future<void> disconnect() async {
    debugPrint('SyncPlayWebSocket: Disconnecting...');

    _stopKeepAlive();
    _reconnectTimer?.cancel();
    _reconnectAttempts = _maxReconnectAttempts; // Prevent reconnection

    await _subscription?.cancel();
    _subscription = null;

    await _channel?.sink.close();
    _channel = null;

    _isConnected = false;
    _isConnecting = false;

    // Only add to controller if not disposed
    if (!_isDisposed) {
      _connectionStateController.add(false);
    }

    debugPrint('SyncPlayWebSocket: Disconnected');
  }

  /// Dispose of all resources
  void dispose() {
    // Set disposed flag FIRST to prevent race conditions
    _isDisposed = true;
    disconnect();
    _messageController.close();
    _connectionStateController.close();
  }
}

/// Extension to extract typed data from SyncPlay messages
extension SyncPlayMessageExtensions on SyncPlayMessage {
  /// Extract group state from the message data
  SyncPlayGroup? get groupState {
    if (type == SyncPlayMessageType.groupStateUpdate ||
        type == SyncPlayMessageType.groupJoined) {
      try {
        return SyncPlayGroup.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Extract participant from user joined/left messages
  SyncPlayParticipant? get participant {
    if (type == SyncPlayMessageType.userJoined ||
        type == SyncPlayMessageType.userLeft) {
      try {
        return SyncPlayParticipant.fromJson(data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Extract position ticks from seek/play messages
  int? get positionTicks {
    return data['PositionTicks'] as int?;
  }

  /// Extract whether playback is paused
  bool get isPaused {
    return data['IsPaused'] as bool? ?? false;
  }

  /// Extract playlist item ID from queue operations
  String? get playlistItemId {
    return data['PlaylistItemId'] as String?;
  }

  /// Extract item IDs from queue update
  /// Handles various formats: strings, integers, or objects with Id/ItemId fields
  List<String>? get itemIds {
    final items = data['Items'] as List<dynamic>?;
    if (items == null) return null;

    return items.map((item) {
      if (item is String) {
        return item;
      } else if (item is int) {
        return item.toString();
      } else if (item is Map) {
        // Try common ID field names
        return (item['Id'] ?? item['ItemId'] ?? item['id'] ?? item['itemId'])?.toString();
      }
      return null;
    }).whereType<String>().toList();
  }

  /// Extract the new index for move operations
  int? get newIndex {
    return data['NewIndex'] as int?;
  }

  /// Extract the playing item index
  int? get playingItemIndex {
    return data['PlayingItemIndex'] as int?;
  }

  /// Extract the play queue data from group state updates
  /// Returns the queue items and playing index if present
  Map<String, dynamic>? get playQueue {
    // Check for PlayQueue in the data (Jellyfin sends this on join)
    final playQueue = data['PlayQueue'] as Map<String, dynamic>?;
    if (playQueue != null) return playQueue;

    // Also check for PlayingQueue (alternative format)
    final playingQueue = data['PlayingQueue'] as Map<String, dynamic>?;
    if (playingQueue != null) return playingQueue;

    return null;
  }

  /// Extract queue item IDs from PlayQueue
  List<String>? get playQueueItemIds {
    final queue = playQueue;
    if (queue == null) return null;

    final items = queue['Items'] as List<dynamic>?;
    if (items == null) return null;

    return items.map((item) {
      if (item is String) return item;
      if (item is Map) {
        return (item['Id'] ?? item['ItemId'] ?? item['PlaylistItemId'])?.toString();
      }
      return null;
    }).whereType<String>().toList();
  }
}
