import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/order_by_ids.dart';

class PendingPlaylistAction {
  PendingPlaylistAction({
    required this.type,
    required this.payload,
    required this.timestamp,
    String? id,
    this.attempts = 0,
    this.maybeApplied = false,
  }) : id = id ?? _generateId();

  final String id;
  final String type; // 'create', 'update', 'delete', 'add', 'favorite'
  final Map<String, dynamic> payload;
  final DateTime timestamp;

  /// Failed attempts the server answered with an error (5xx) so far; network
  /// failures don't count (see [decidePendingActionFailure]).
  final int attempts;

  /// A previous attempt may have been applied by the server even though it
  /// failed from the app's point of view (timed out or broke after being
  /// sent, or a 5xx). Used to avoid re-creating a playlist, and (for `add`)
  /// re-adding the chunk that was in flight.
  final bool maybeApplied;

  PendingPlaylistAction copyWith({
    int? attempts,
    bool? maybeApplied,
    Map<String, dynamic>? payload,
  }) =>
      PendingPlaylistAction(
        id: id,
        type: type,
        payload: payload ?? this.payload,
        timestamp: timestamp,
        attempts: attempts ?? this.attempts,
        maybeApplied: maybeApplied ?? this.maybeApplied,
      );

  factory PendingPlaylistAction.fromJson(Map<String, dynamic> json) {
    return PendingPlaylistAction(
      id: json['id'] as String?,
      type: json['type'] as String,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      timestamp: DateTime.parse(json['timestamp'] as String),
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      maybeApplied: json['maybeApplied'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'payload': payload,
      'timestamp': timestamp.toIso8601String(),
      'attempts': attempts,
      if (maybeApplied) 'maybeApplied': true,
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

  /// Queue [action]. A favorite toggle replaces any queued toggle for the
  /// same item (only the last state matters, and replaying stale toggles in
  /// a different order could leave the wrong state on the server).
  Future<void> add(PendingPlaylistAction action) {
    return _serialize(() async {
      final actions = await load();
      if (action.type == 'favorite') {
        final itemId = action.payload['itemId'];
        actions.removeWhere(
          (a) => a.type == 'favorite' && a.payload['itemId'] == itemId,
        );
      }
      actions.add(action);
      await save(actions);
    });
  }

  /// Replace the stored action with the same id (e.g. to bump [attempts]).
  Future<void> update(PendingPlaylistAction action) {
    return _serialize(() async {
      final actions = await load();
      final index = actions.indexWhere((a) => a.id == action.id);
      if (index < 0) return;
      actions[index] = action;
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

/// Outcome of a failed sync attempt for a queued action.
@immutable
class PendingActionFailureDecision {
  const PendingActionFailureDecision({required this.drop, required this.attempts});

  /// Remove the action from the queue (it can never succeed, or is too old).
  final bool drop;

  /// The action's new [PendingPlaylistAction.attempts] when kept.
  final int attempts;
}

/// Server errors (5xx) tolerated before a queued action is given up.
const int kMaxPendingActionServerErrors = 8;

/// A queued action that still fails after this long is given up.
const Duration kPendingActionMaxAge = Duration(days: 90);

/// Decides what happens to a queued action whose sync attempt failed.
///
/// - Rejected by the server (4xx other than 401/408/429) or malformed
///   ([invalidPayload]): dropped, retrying can never succeed.
/// - Server error (5xx): counted; dropped after
///   [kMaxPendingActionServerErrors].
/// - Anything else (no response: network error, timeout; 401/408/429): kept
///   and not counted, so flaky connectivity can't make edits disappear.
/// - Kept actions older than [kPendingActionMaxAge] are dropped.
PendingActionFailureDecision decidePendingActionFailure({
  required int attempts,
  required DateTime queuedAt,
  required DateTime now,
  int? httpStatus,
  bool invalidPayload = false,
}) {
  final status = httpStatus;
  final rejected = invalidPayload ||
      (status != null &&
          status >= 400 &&
          status < 500 &&
          status != 401 &&
          status != 408 &&
          status != 429);
  if (rejected) {
    return PendingActionFailureDecision(drop: true, attempts: attempts + 1);
  }
  final serverError = status != null && status >= 500;
  final next = serverError ? attempts + 1 : attempts;
  final drop = (serverError && next >= kMaxPendingActionServerErrors) ||
      now.difference(queuedAt) > kPendingActionMaxAge;
  return PendingActionFailureDecision(drop: drop, attempts: next);
}

/// Whether a retried "create playlist" action was already applied by an
/// earlier attempt: only when that attempt may have reached the server
/// ([maybeApplied]) and a playlist named [name] was created on the server
/// at or after [queuedAt]. When unsure it returns false: a duplicate
/// playlist is better than a lost one.
bool retriedCreateAlreadyApplied({
  required bool maybeApplied,
  required String name,
  required DateTime queuedAt,
  required Iterable<({String name, DateTime? created})> serverPlaylists,
}) {
  if (!maybeApplied) return false;
  return serverPlaylists.any((p) =>
      p.name == name && p.created != null && !p.created!.isBefore(queuedAt));
}

/// Payload key of an `add` action: how many of its `itemIds` the server
/// already accepted (chunks are sent in order), so a retry resumes after
/// them instead of adding them again.
const String kAddActionSentCountKey = 'sentCount';

/// Ids of a queued `add` [payload] still to send, after the chunks already
/// accepted ([kAddActionSentCountKey]).
List<String> remainingAddIds(Map<String, dynamic> payload) {
  final ids = (payload['itemIds'] as List).cast<String>();
  final sent = (payload[kAddActionSentCountKey] as num?)?.toInt() ?? 0;
  return ids.sublist(sent.clamp(0, ids.length));
}

/// How many leading ids of [remaining] a previous attempt that may have
/// reached the server ([maybeApplied]) already added: the first chunk (the
/// one in flight, sent as one request of up to [chunkSize] ids) when every
/// id of it is in the playlist ([playlistItemIds]). Otherwise 0 — when
/// unsure, a duplicate beats a lost song.
int appliedLeadingChunk({
  required bool maybeApplied,
  required List<String> remaining,
  required Set<String> playlistItemIds,
  int chunkSize = kMaxIdsPerRequest,
}) {
  if (!maybeApplied || remaining.isEmpty) return 0;
  final chunk = remaining.take(chunkSize).toList();
  return chunk.every(playlistItemIds.contains) ? chunk.length : 0;
}
