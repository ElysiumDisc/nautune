import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PendingPlaylistAction {
  PendingPlaylistAction({
    required this.type,
    required this.payload,
    required this.timestamp,
  });

  final String type; // 'create', 'update', 'delete', 'add', 'favorite'
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  factory PendingPlaylistAction.fromJson(Map<String, dynamic> json) {
    return PendingPlaylistAction(
      type: json['type'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'payload': payload,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

class PlaylistSyncQueue {
  PlaylistSyncQueue({SharedPreferences? preferences})
      : _preferences = preferences;

  static const _queueKey = 'nautune_playlist_sync_queue';

  SharedPreferences? _preferences;

  Future<SharedPreferences> _prefs() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  Future<List<PendingPlaylistAction>> load() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_queueKey);
    if (raw == null) {
      return [];
    }

    try {
      final json = jsonDecode(raw) as List<dynamic>;
      return json
          .map((item) => PendingPlaylistAction.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      await prefs.remove(_queueKey);
      return [];
    }
  }

  Future<void> save(List<PendingPlaylistAction> actions) async {
    final prefs = await _prefs();
    await prefs.setString(
      _queueKey,
      jsonEncode(actions.map((a) => a.toJson()).toList()),
    );
  }

  Future<void> add(PendingPlaylistAction action) async {
    final actions = await load();
    actions.add(action);
    await save(actions);
  }

  Future<void> remove(PendingPlaylistAction action) async {
    final actions = await load();
    actions.removeWhere((a) => 
      a.type == action.type && 
      a.timestamp == action.timestamp
    );
    await save(actions);
  }

  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_queueKey);
  }
}
