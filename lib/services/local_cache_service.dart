import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'hive_init.dart';
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

  final Box<dynamic> _box;

  /// Ensures Hive is ready and returns a cache service instance.
  ///
  /// Never throws: main awaits this before the first frame, and the box only
  /// holds data that can be fetched again. A box that can't be opened is
  /// deleted and recreated; failing that, the cache lives in memory for
  /// this run.
  static Future<LocalCacheService> create() async {
    await ensureHiveInitialized();
    try {
      return LocalCacheService._(await Hive.openBox<dynamic>(_boxName));
    } catch (error) {
      debugPrint('LocalCacheService: cache box unreadable, recreating: $error');
    }
    try {
      await Hive.deleteBoxFromDisk(_boxName);
      return LocalCacheService._(await Hive.openBox<dynamic>(_boxName));
    } catch (error) {
      debugPrint('LocalCacheService: using an in-memory cache: $error');
      return LocalCacheService._(
        await Hive.openBox<dynamic>(_boxName, bytes: Uint8List(0)),
      );
    }
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
    return _decodeEach(raw, (json) => JellyfinLibrary.fromJson(json));
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
    return _decodeEach(raw, (json) => JellyfinAlbum.fromJson(json));
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
    return _decodeEach(raw, (json) => JellyfinArtist.fromJson(json));
  }

  Future<void> savePlaylists(String sessionKey, List<JellyfinPlaylist> data) {
    return _writeList(
      _k('playlists', sessionKey),
      data.map((e) => e.toJson()).toList(),
    );
  }

  Future<List<JellyfinPlaylist>?> readPlaylists(String sessionKey) async {
    final raw = _readList(_k('playlists', sessionKey));
    return _decodeEach(raw, (json) => JellyfinPlaylist.fromJson(json));
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
    return _decodeEach(raw, JellyfinTrack.fromStorageJson);
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
    return _decodeEach(raw, (json) => JellyfinAlbum.fromJson(json));
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

  /// Save album tracks for offline/cached viewing
  Future<void> saveAlbumTracks(
    String sessionKey, {
    required String albumId,
    required List<JellyfinTrack> data,
  }) {
    return _writeList(
      _k('album_tracks', sessionKey, albumId),
      data.map((e) => e.toStorageJson()).toList(),
    );
  }

  /// Read cached album tracks
  Future<List<JellyfinTrack>?> readAlbumTracks(
    String sessionKey, {
    required String albumId,
  }) async {
    final raw = _readList(_k('album_tracks', sessionKey, albumId));
    return _decodeEach(raw, JellyfinTrack.fromStorageJson);
  }

  /// Check if album tracks are cached
  bool hasAlbumTracks(String sessionKey, {required String albumId}) {
    final key = _k('album_tracks', sessionKey, albumId);
    return _box.containsKey(key);
  }

  /// Pre-cache tracks for all downloaded albums
  Future<void> cacheTracksForDownloadedAlbums(
    String sessionKey,
    Set<String> downloadedAlbumIds,
    Future<List<JellyfinTrack>> Function(String albumId) fetchTracks,
  ) async {
    for (final albumId in downloadedAlbumIds) {
      if (!hasAlbumTracks(sessionKey, albumId: albumId)) {
        try {
          final tracks = await fetchTracks(albumId);
          await saveAlbumTracks(sessionKey, albumId: albumId, data: tracks);
        } catch (e) {
          // Skip if fetch fails - we'll try again later
        }
      }
    }
  }

  Future<void> savePlayStats(
    String sessionKey,
    Map<String, dynamic> statsJson,
  ) {
    return _writeMap(
      _k('play_stats', sessionKey),
      statsJson,
    );
  }

  Future<Map<String, dynamic>?> readPlayStats(String sessionKey) async {
    return _readMap(_k('play_stats', sessionKey));
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

  /// Decodes each cached entry, skipping (not failing on) malformed ones,
  /// so one bad record can't discard the whole cached list.
  static List<T>? _decodeEach<T>(
    List<Map<String, dynamic>>? raw,
    T Function(Map<String, dynamic>) decode,
  ) {
    if (raw == null) return null;
    final out = <T>[];
    for (final json in raw) {
      try {
        out.add(decode(json));
      } catch (e) {
        debugPrint('LocalCacheService: skipping bad cached entry: $e');
      }
    }
    return out;
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

  Future<void> _writeMap(
    String key,
    Map<String, dynamic> payload,
  ) async {
    await _box.put(key, {
      _updatedAtKey: DateTime.now().millisecondsSinceEpoch,
      _payloadKey: payload,
    });
  }

  Map<String, dynamic>? _readMap(String key) {
    final raw = _box.get(key);
    if (raw is Map) {
      final payload = raw[_payloadKey];
      if (payload is Map) {
        return Map<String, dynamic>.from(payload);
      }
    }
    return null;
  }
}
