import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'jellyfin_playlist.dart';

class JellyfinPlaylistStore {
  static const _boxName = 'nautune_playlists';
  static const _playlistsKey = 'playlists';

  Future<Box> _box() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  Future<List<JellyfinPlaylist>?> load() async {
    final box = await _box();
    final raw = box.get(_playlistsKey);
    if (raw == null) {
      return null;
    }

    try {
      // Hive might store as List<dynamic> if saved as List
      // If we save as json encoded string (legacy), we decode.
      // We'll support both for migration robustness, but prefer structured if possible.
      // Let's stick to the pattern of checking type.
      
      final List<dynamic> list;
      if (raw is String) {
        list = jsonDecode(raw) as List<dynamic>;
      } else if (raw is List) {
        list = raw;
      } else {
        return null;
      }

      return list
          .map((item) {
            if (item is Map) {
              return JellyfinPlaylist.fromJson(Map<String, dynamic>.from(item));
            }
            return null;
          })
          .whereType<JellyfinPlaylist>()
          .toList();
    } catch (e) {
      debugPrint('⚠️ JellyfinPlaylistStore: Failed to parse playlists: $e');
      return null;
    }
  }

  Future<void> save(List<JellyfinPlaylist> playlists) async {
    final box = await _box();
    // Store as List of Maps for better Hive usage
    await box.put(
      _playlistsKey,
      playlists.map((p) => p.toJson()).toList(),
    );
  }

  Future<void> clear() async {
    final box = await _box();
    await box.delete(_playlistsKey);
  }
}
