import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../jellyfin/jellyfin_credentials.dart';
import '../models/syncplay_models.dart';

/// WebSocket message types from Jellyfin SyncPlay
///
/// Jellyfin sends two main message types:
/// - SyncPlayGroupUpdate: Contains Data.Type field with GroupUpdateType values
/// - SyncPlayCommand: Contains Data.Command field with SendCommandType values
enum SyncPlayMessageType {
  // Group update types (from Data.Type in SyncPlayGroupUpdate messages)
  groupJoined,      // GroupJoined - sent when you successfully join a group
  groupLeft,        // GroupLeft - sent when you leave or are removed from group
  groupStateUpdate, // StateUpdate - sent for playback state changes
  userJoined,       // UserJoined - sent when another user joins
  userLeft,         // UserLeft - sent when another user leaves
  playQueueUpdate,  // PlayQueue - sent when queue changes
  notInGroup,       // NotInGroup - error: not in a group
  groupDoesNotExist, // GroupDoesNotExist - error: group doesn't exist
  libraryAccessDenied, // LibraryAccessDenied - error: no access

  // Playback commands (from Data.Command in SyncPlayCommand messages)
  unpause,          // Unpause command
  pause,            // Pause command
  stop,             // Stop command
  seek,             // Seek command

  // Keep-alive
  forceKeepAlive,
  keepAlive,

  // Unknown
  unknown;

  /// Parse from Jellyfin WebSocket message
  ///
  /// Jellyfin uses two-level structure:
  /// - MessageType: "SyncPlayGroupUpdate" or "SyncPlayCommand"
  /// - Data.Type or Data.Command: The actual sub-type
  static SyncPlayMessageType fromJson(Map<String, dynamic> json) {
    final messageType = json['MessageType'] as String?;
    final data = json['Data'];

    // Handle keep-alive messages
    if (messageType == 'ForceKeepAlive') return SyncPlayMessageType.forceKeepAlive;
    if (messageType == 'KeepAlive') return SyncPlayMessageType.keepAlive;

    // Handle SyncPlayGroupUpdate messages - look at Data.Type
    if (messageType == 'SyncPlayGroupUpdate') {
      if (data is Map<String, dynamic>) {
        final updateType = data['Type'] as String?;
        switch (updateType) {
          case 'UserJoined':
            return SyncPlayMessageType.userJoined;
          case 'UserLeft':
            return SyncPlayMessageType.userLeft;
          case 'GroupJoined':
            return SyncPlayMessageType.groupJoined;
          case 'GroupLeft':
            return SyncPlayMessageType.groupLeft;
          case 'StateUpdate':
            return SyncPlayMessageType.groupStateUpdate;
          case 'PlayQueue':
            return SyncPlayMessageType.playQueueUpdate;
          case 'NotInGroup':
            return SyncPlayMessageType.notInGroup;
          case 'GroupDoesNotExist':
            return SyncPlayMessageType.groupDoesNotExist;
          case 'LibraryAccessDenied':
            return SyncPlayMessageType.libraryAccessDenied;
          default:
            debugPrint('SyncPlayWebSocket: Unknown GroupUpdate Type: $updateType');
            return SyncPlayMessageType.unknown;
        }
      }
    }

    // Handle SyncPlayCommand messages - look at Data.Command
    if (messageType == 'SyncPlayCommand') {
      if (data is Map<String, dynamic>) {
        final command = data['Command'] as String?;
        switch (command) {
          case 'Unpause':
            return SyncPlayMessageType.unpause;
          case 'Pause':
            return SyncPlayMessageType.pause;
          case 'Stop':
            return SyncPlayMessageType.stop;
          case 'Seek':
            return SyncPlayMessageType.seek;
          default:
            debugPrint('SyncPlayWebSocket: Unknown SyncPlayCommand: $command');
            return SyncPlayMessageType.unknown;
        }
      }
    }

    return SyncPlayMessageType.unknown;
  }
}

/// A SyncPlay WebSocket message
class SyncPlayMessage {
  const SyncPlayMessage({
    required this.type,
    required this.data,
    required this.rawJson,
    this.messageId,
    this.groupId,
  });

  final SyncPlayMessageType type;
  final Map<String, dynamic> data;
  final Map<String, dynamic> rawJson;
  final String? messageId;
  final String? groupId;

  factory SyncPlayMessage.fromJson(Map<String, dynamic> json) {
    // Parse the type using the new two-level parser
    final type = SyncPlayMessageType.fromJson(json);

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

    // Extract GroupId if present (SyncPlayGroupUpdate messages have it at Data.GroupId)
    final groupId = data['GroupId'] as String?;

    return SyncPlayMessage(
      type: type,
      data: data,
      rawJson: json,
      messageId: json['MessageId'] as String?,
      groupId: groupId,
    );
  }

  @override
  String toString() => 'SyncPlayMessage(type: $type, groupId: $groupId)';
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
  static const int _maxReconnectAttempts = 10;
  static const Duration _keepAliveInterval = Duration(seconds: 20);

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
    debugPrint('SyncPlayWebSocket: Connecting to ${wsUrl.replaceAll(RegExp(r'api_key=[^&]+'), 'api_key=***')}');

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

      // Debug: log raw MessageType to see what server sends
      final rawType = json['MessageType'] as String?;
      if (rawType != null && rawType.contains('SyncPlay')) {
        debugPrint('SyncPlayWebSocket: RAW MessageType: $rawType');
      }

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
      _isConnected = false;
      _connectionStateController.add(false);
      _stopKeepAlive();
      _scheduleReconnect();
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
///
/// Jellyfin SyncPlayGroupUpdate messages have nested structure:
/// - data['GroupId']: The group ID
/// - data['Type']: The update type (UserJoined, StateUpdate, etc.)
/// - data['Data']: The actual payload (nested)
extension SyncPlayMessageExtensions on SyncPlayMessage {
  /// Get the nested Data payload (for SyncPlayGroupUpdate messages)
  Map<String, dynamic>? get nestedData {
    final nested = data['Data'];
    if (nested is Map<String, dynamic>) return nested;
    if (nested is Map) return nested.map((k, v) => MapEntry(k.toString(), v));
    return null;
  }

  /// Extract group info from GroupJoined messages
  /// The nested Data contains GroupInfoDto
  SyncPlayGroup? get groupState {
    if (type == SyncPlayMessageType.groupJoined) {
      final nested = nestedData;
      if (nested != null) {
        try {
          return SyncPlayGroup.fromJson(nested);
        } catch (e) {
          debugPrint('SyncPlayMessage: Failed to parse groupState: $e');
        }
      }
    }
    // For StateUpdate, the nested Data is GroupStateUpdate (different structure)
    if (type == SyncPlayMessageType.groupStateUpdate) {
      final nested = nestedData;
      if (nested != null) {
        try {
          // GroupStateUpdate has State, PositionTicks, etc. - create minimal group
          return SyncPlayGroup(
            groupId: groupId ?? '',
            groupName: '',
            participants: [],
            state: _parseState(nested['State'] as String?),
          );
        } catch (e) {
          debugPrint('SyncPlayMessage: Failed to parse state update: $e');
        }
      }
    }
    return null;
  }

  SyncPlayState _parseState(String? state) {
    switch (state) {
      case 'Playing':
        return SyncPlayState.playing;
      case 'Paused':
        return SyncPlayState.paused;
      case 'Waiting':
        return SyncPlayState.waiting;
      default:
        return SyncPlayState.idle;
    }
  }

  /// Extract user ID from UserJoined/UserLeft messages
  /// The nested Data is just a string (user ID)
  String? get joinedUserId {
    if (type == SyncPlayMessageType.userJoined ||
        type == SyncPlayMessageType.userLeft) {
      final nested = data['Data'];
      if (nested is String) return nested;
    }
    return null;
  }

  /// Extract participant from user joined/left messages
  /// Note: Jellyfin only sends user ID, not full participant info
  SyncPlayParticipant? get participant {
    final userId = joinedUserId;
    if (userId != null) {
      return SyncPlayParticipant(
        oderId: '', // Not provided by server
        userId: userId,
        username: userId, // Will need to fetch from sessions
        isGroupLeader: false,
      );
    }
    return null;
  }

  /// Extract position ticks from StateUpdate messages
  int? get positionTicks {
    // First check nested data (for StateUpdate)
    final nested = nestedData;
    if (nested != null) {
      return nested['PositionTicks'] as int?;
    }
    // Fall back to top-level data (for SyncPlayCommand)
    return data['PositionTicks'] as int?;
  }

  /// Extract whether playback is paused from StateUpdate
  bool get isPaused {
    final nested = nestedData;
    if (nested != null) {
      // First check explicit IsPaused field
      final explicitPaused = nested['IsPaused'] as bool?;
      if (explicitPaused != null) return explicitPaused;

      // Derive from State field if IsPaused not provided
      final state = nested['State'] as String?;
      if (state != null) {
        return state == 'Paused' || state == 'Idle' || state == 'Waiting';
      }
    }
    return data['IsPaused'] as bool? ?? false;
  }

  /// Extract playlist item ID from queue operations
  String? get playlistItemId {
    final nested = nestedData;
    if (nested != null) {
      return nested['PlaylistItemId'] as String?;
    }
    return data['PlaylistItemId'] as String?;
  }

  /// Extract item IDs from queue update
  /// Handles various formats: strings, integers, or objects with Id/ItemId fields
  List<String>? get itemIds {
    final nested = nestedData ?? data;
    final items = nested['Items'] as List<dynamic>?;
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
    final nested = nestedData;
    if (nested != null) {
      return nested['NewIndex'] as int?;
    }
    return data['NewIndex'] as int?;
  }

  /// Extract the playing item index
  int? get playingItemIndex {
    final nested = nestedData;
    if (nested != null) {
      return nested['PlayingItemIndex'] as int?;
    }
    return data['PlayingItemIndex'] as int?;
  }

  /// Extract the play queue data from PlayQueue updates
  /// Returns the queue items and playing index if present
  Map<String, dynamic>? get playQueue {
    // For PlayQueue type, the nested Data IS the queue
    if (type == SyncPlayMessageType.playQueueUpdate) {
      return nestedData;
    }

    // Also check for PlayQueue in various locations
    final nested = nestedData ?? data;
    final playQueue = nested['PlayQueue'] as Map<String, dynamic>?;
    if (playQueue != null) return playQueue;

    final playingQueue = nested['PlayingQueue'] as Map<String, dynamic>?;
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
