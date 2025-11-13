import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import '../jellyfin/jellyfin_album.dart';
import '../jellyfin/jellyfin_artist.dart';
import '../jellyfin/jellyfin_library.dart';
import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_session.dart';
import '../jellyfin/jellyfin_track.dart';

/// Handles persistent caching for Jellyfin metadata needed at startup.
class LocalCacheService {
  LocalCacheService._(this._box);

  static const _boxName = 'nautune_cache';
  static const _payloadKey = 'payload';
  static const _updatedAtKey = 'updatedAt';

  static bool _hiveInitialized = false;

  final Box<dynamic> _box;

  /// Ensures Hive is ready and returns a cache service instance.
  static Future<LocalCacheService> create() async {
    if (!_hiveInitialized) {
      await Hive.initFlutter();
      _hiveInitialized = true;
    }
    final box = await Hive.openBox<dynamic>(_boxName);
    return LocalCacheService._(box);
  }

  String cacheKeyForSession(JellyfinSession session) {
    return '${session.serverUrl}|${session.credentials.userId}';
  }

  Future<void> clearForSession(String sessionKey) async {
    final keys = _box.keys.where(
      (key) => key is String && key.contains('|$sessionKey'),
    );
    await _box.deleteAll(keys);
  }

  Future<void> saveLibraries(String sessionKey, List<JellyfinLibrary> data) {
    return _writeList(
      _k('libraries', sessionKey),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinLibrary>?> readLibraries(String sessionKey) async {
    final raw = _readList(_k('libraries', sessionKey));
    return raw?.map((json) => JellyfinLibrary.fromJson(json)).toList();
  }

  Future<void> saveAlbums(
    String sessionKey, {
    required String libraryId,
    required List<JellyfinAlbum> data,
  }) {
    return _writeList(
      _k('albums', sessionKey, libraryId),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinAlbum>?> readAlbums(
    String sessionKey, {
    required String libraryId,
  }) async {
    final raw = _readList(_k('albums', sessionKey, libraryId));
    return raw?.map((json) => JellyfinAlbum.fromJson(json)).toList();
  }

  Future<void> saveArtists(
    String sessionKey, {
    required String libraryId,
    required List<JellyfinArtist> data,
  }) {
    return _writeList(
      _k('artists', sessionKey, libraryId),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinArtist>?> readArtists(
    String sessionKey, {
    required String libraryId,
  }) async {
    final raw = _readList(_k('artists', sessionKey, libraryId));
    return raw?.map((json) => JellyfinArtist.fromJson(json)).toList();
  }

  Future<void> savePlaylists(String sessionKey, List<JellyfinPlaylist> data) {
    return _writeList(
      _k('playlists', sessionKey),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinPlaylist>?> readPlaylists(String sessionKey) async {
    final raw = _readList(_k('playlists', sessionKey));
    return raw?.map((json) => JellyfinPlaylist.fromJson(json)).toList();
  }

  Future<void> saveRecentTracks(
    String sessionKey, {
    required String libraryId,
    required List<JellyfinTrack> data,
  }) {
    return _writeList(
      _k('recent_tracks', sessionKey, libraryId),
      data.map((e) => e.toStorageJson()).toList(),
    );
  }

  Future<List<JellyfinTrack>?> readRecentTracks(
    String sessionKey, {
    required String libraryId,
  }) async {
    final raw = _readList(_k('recent_tracks', sessionKey, libraryId));
    return raw?.map(JellyfinTrack.fromStorageJson).toList();
  }

  Future<void> saveRecentlyAddedAlbums(
    String sessionKey, {
    required String libraryId,
    required List<JellyfinAlbum> data,
  }) {
    return _writeList(
      _k('recently_added', sessionKey, libraryId),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinAlbum>?> readRecentlyAddedAlbums(
    String sessionKey, {
    required String libraryId,
  }) async {
    final raw = _readList(_k('recently_added', sessionKey, libraryId));
    return raw?.map((json) => JellyfinAlbum.fromJson(json)).toList();
  }

  Future<void> saveGenres(
    String sessionKey, {
    required String libraryId,
    required List<Map<String, dynamic>> data,
  }) {
    return _writeList(_k('genres', sessionKey, libraryId), data);
  }

  List<Map<String, dynamic>>? readGenres(
    String sessionKey, {
    required String libraryId,
  }) {
    return _readList(_k('genres', sessionKey, libraryId));
  }

  String _k(String namespace, String sessionKey, [String? libraryId]) {
    if (libraryId == null) {
      return '$namespace|$sessionKey';
    }
    return '$namespace|$sessionKey|$libraryId';
  }

  Future<void> _writeList(
    String key,
    List<Map<String, dynamic>> payload,
  ) async {
    await _box.put(key, {
      _updatedAtKey: DateTime.now().millisecondsSinceEpoch,
      _payloadKey: payload,
    });
  }

  List<Map<String, dynamic>>? _readList(String key) {
    final raw = _box.get(key);
    if (raw is Map && raw[_payloadKey] is List) {
      return (raw[_payloadKey] as List)
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    return null;
  }
}
