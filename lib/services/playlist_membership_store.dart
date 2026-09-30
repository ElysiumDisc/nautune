import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'hive_init.dart';

/// Ordered track ids of each playlist, as last fetched from the server.
///
/// Lets the offline library show a playlist as "its downloaded tracks, in
/// playlist order" — including tracks that were downloaded through an album
/// or one by one rather than through the playlist itself.
class PlaylistMembershipStore {
  PlaylistMembershipStore._();

  static final PlaylistMembershipStore instance = PlaylistMembershipStore._();

  static const _boxName = 'nautune_playlist_members';

  Future<Box<dynamic>>? _boxFuture;

  Future<Box<dynamic>> _box() => _boxFuture ??= () async {
        await ensureHiveInitialized();
        return Hive.isBoxOpen(_boxName)
            ? Hive.box<dynamic>(_boxName)
            : await Hive.openBox<dynamic>(_boxName);
      }();

  /// Remember [trackIds] (in playlist order) for [playlistId].
  Future<void> save(String playlistId, List<String> trackIds) async {
    try {
      final box = await _box();
      await box.put(playlistId, List<String>.of(trackIds));
    } catch (e) {
      _boxFuture = null;
      debugPrint('⚠️ PlaylistMembershipStore: save failed: $e');
    }
  }

  /// Track ids of [playlistId] in playlist order, or null if never fetched.
  Future<List<String>?> load(String playlistId) async {
    try {
      final box = await _box();
      final raw = box.get(playlistId);
      if (raw is List) return raw.whereType<String>().toList(growable: false);
    } catch (e) {
      _boxFuture = null;
      debugPrint('⚠️ PlaylistMembershipStore: load failed: $e');
    }
    return null;
  }

  /// Forget every playlist (e.g. on logout).
  Future<void> clear() async {
    try {
      final box = await _box();
      await box.clear();
    } catch (e) {
      _boxFuture = null;
      debugPrint('⚠️ PlaylistMembershipStore: clear failed: $e');
    }
  }

  Future<void> remove(String playlistId) async {
    try {
      final box = await _box();
      await box.delete(playlistId);
    } catch (e) {
      _boxFuture = null;
      debugPrint('⚠️ PlaylistMembershipStore: remove failed: $e');
    }
  }
}
