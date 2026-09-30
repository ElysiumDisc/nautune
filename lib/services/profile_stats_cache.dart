import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'hive_init.dart';

/// Memory + disk cache for the Profile dashboard's server-derived stats.
///
/// Holds display fields only (names, counts, image tags) — never tracks
/// serialised with `toStorageJson()`, which carry the access token. The single
/// entry is tagged with the user / server / library it was computed for, so
/// another account or library never sees it. [clear] removes it on logout.
class ProfileStatsCache {
  ProfileStatsCache._();

  static const _boxName = 'profile_stats_cache';
  static const _cacheKey = 'stats';
  static const _scopeField = '_scope';
  static const _timeField = '_cacheTime';

  /// How long cached stats are shown before refreshing from the server.
  static const validity = Duration(minutes: 5);

  static Box<dynamic>? _box;
  static Map<String, dynamic>? _memory;
  static String? _memoryScope;
  static DateTime? _memoryTime;

  /// Cache scope for a user on a server, in one library.
  static String scopeFor({
    required String userId,
    required String serverUrl,
    required String libraryId,
  }) =>
      '$userId|$serverUrl|$libraryId';

  static Future<Box<dynamic>> _open() async {
    final box = _box;
    if (box != null && box.isOpen) return box;
    await ensureHiveInitialized();
    return _box = await Hive.openBox<dynamic>(_boxName);
  }

  static bool _isFresh(DateTime? time) =>
      time != null && DateTime.now().difference(time) < validity;

  /// Fresh stats for [scope], or null. An entry for another scope (or from
  /// before entries were scoped) is deleted.
  static Future<Map<String, dynamic>?> load(String scope) async {
    if (_memoryScope == scope && _isFresh(_memoryTime)) return _memory;

    final box = await _open();
    final raw = box.get(_cacheKey);
    if (raw == null) return null;

    try {
      final data = Map<String, dynamic>.from(
        raw is String ? jsonDecode(raw) as Map : raw as Map,
      );
      if (data[_scopeField] != scope) {
        await box.delete(_cacheKey);
        return null;
      }
      final saved = data[_timeField] as int?;
      final time =
          saved == null ? null : DateTime.fromMillisecondsSinceEpoch(saved);
      if (!_isFresh(time)) return null;

      _memory = data;
      _memoryScope = scope;
      _memoryTime = time;
      return data;
    } catch (e) {
      debugPrint('ProfileStatsCache: Error loading cache: $e');
      await box.delete(_cacheKey);
      return null;
    }
  }

  /// Stores [stats] (JSON-encodable display fields) for [scope].
  static Future<void> save(String scope, Map<String, dynamic> stats) async {
    final now = DateTime.now();
    final data = <String, dynamic>{
      ...stats,
      _scopeField: scope,
      _timeField: now.millisecondsSinceEpoch,
    };
    _memory = data;
    _memoryScope = scope;
    _memoryTime = now;
    final box = await _open();
    await box.put(_cacheKey, jsonEncode(data));
  }

  /// Removes the cache from memory and disk. Call on logout.
  static Future<void> clear() async {
    _memory = null;
    _memoryScope = null;
    _memoryTime = null;
    _box = null;
    try {
      await ensureHiveInitialized();
      await Hive.deleteBoxFromDisk(_boxName);
    } catch (e) {
      debugPrint('ProfileStatsCache: Failed to clear cache: $e');
    }
  }
}
