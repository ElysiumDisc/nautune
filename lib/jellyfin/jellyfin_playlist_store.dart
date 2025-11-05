import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'jellyfin_playlist.dart';

class JellyfinPlaylistStore {
  JellyfinPlaylistStore({SharedPreferences? preferences})
      : _preferences = preferences;

  static const _playlistsKey = 'nautune_jellyfin_playlists';

  SharedPreferences? _preferences;

  Future<SharedPreferences> _prefs() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  Future<List<JellyfinPlaylist>?> load() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_playlistsKey);
    if (raw == null) {
      return null;
    }

    try {
      final json = jsonDecode(raw) as List<dynamic>;
      return json
          .map((item) => JellyfinPlaylist.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      await prefs.remove(_playlistsKey);
      return null;
    }
  }

  Future<void> save(List<JellyfinPlaylist> playlists) async {
    final prefs = await _prefs();
    await prefs.setString(
      _playlistsKey,
      jsonEncode(playlists.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> clear() async {
    final prefs = await _prefs();
    await prefs.remove(_playlistsKey);
  }
}
