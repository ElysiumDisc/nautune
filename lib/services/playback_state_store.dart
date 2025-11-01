import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_state.dart';

class PlaybackStateStore {
  static const String _key = 'nautune_playback_state';

  Future<PlaybackState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_key);
    if (json == null) {
      return null;
    }
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      return PlaybackState.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(PlaybackState state) async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(state.toJson());
    await prefs.setString(_key, json);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
