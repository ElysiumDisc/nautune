import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

class PendingPlaylistAction {
  PendingPlaylistAction({
    required this.type,
    required this.payload,
    required this.timestamp,
    String? id,
  }) : id = id ?? _generateId();

  final String id;
  final String type; // 'create', 'update', 'delete', 'add', 'favorite'
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  factory PendingPlaylistAction.fromJson(Map<String, dynamic> json) {
    return PendingPlaylistAction(
      id: json['id'] as String?,
      type: json['type'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'payload': payload,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  static final _rng = Random();
  static String _generateId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final r = _rng.nextInt(0x7fffffff);
    return '$ts-$r';
  }
}

class PlaylistSyncQueue {
  static const _boxName = 'nautune_sync_queue';
  static const _queueKey = 'queue';

  // Serializes load-modify-save cycles so a UI-driven `add` can't lose its
  // entry to a concurrent `remove` running in the sync drain loop, or vice
  // versa. Hive itself is single-threaded, but the load → mutate → save
  // sequence has multiple await points where another caller can interleave.
  Future<void> _mutationChain = Future.value();

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  /// Run [body] under the mutation lock. Subsequent calls queue.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    final previous = _mutationChain;
    _mutationChain = previous.then((_) async {
      try {
        completer.complete(await body());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
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

  Future<void> add(PendingPlaylistAction action) {
    return _serialize(() async {
      final actions = await load();
      actions.add(action);
      await save(actions);
    });
  }

  Future<void> remove(PendingPlaylistAction action) {
    return _serialize(() async {
      final actions = await load();
      // Match by stable id so two actions with the same (type, timestamp) —
      // possible when the user fires them in the same millisecond — don't
      // both get removed when only one syncs.
      actions.removeWhere((a) => a.id == action.id);
      await save(actions);
    });
  }

  Future<void> clear() {
    return _serialize(() async {
      final box = await _box();
      await box.delete(_queueKey);
    });
  }
}
