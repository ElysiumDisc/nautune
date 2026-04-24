import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

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
  static const _boxName = 'nautune_sync_queue';
  static const _queueKey = 'queue';

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<List<PendingPlaylistAction>> load() async {
    final box = await _box();
    final raw = box.get(_queueKey);
    if (raw == null) {
      return [];
    }

    try {
      final List<dynamic> list;
      if (raw is String) {
        list = jsonDecode(raw) as List<dynamic>;
      } else if (raw is List) {
        list = raw;
      } else {
        return [];
      }

      return list
          .map((item) {
            if (item is Map) {
              return PendingPlaylistAction.fromJson(Map<String, dynamic>.from(item));
            }
            return null;
          })
          .whereType<PendingPlaylistAction>()
          .toList();
    } catch (e) {
      debugPrint('❌ PlaylistSyncQueue: Failed to load queue: $e');
      return [];
    }
  }

  Future<void> save(List<PendingPlaylistAction> actions) async {
    final box = await _box();
    await box.put(
      _queueKey,
      actions.map((a) => a.toJson()).toList(),
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
    final box = await _box();
    await box.delete(_queueKey);
  }
}
