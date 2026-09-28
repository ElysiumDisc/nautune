import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Keeps Jellyfin start/stop reports that were recorded offline, so they
/// survive the app being killed before connectivity returns.
///
/// Events are stored per account ([accountKey] = server + user) so a queue is
/// never replayed under a different login.
abstract class PendingReportStore {
  Future<List<Map<String, dynamic>>> load(String accountKey);
  Future<void> save(String accountKey, List<Map<String, dynamic>> events);
}

class HivePendingReportStore implements PendingReportStore {
  static const _boxName = 'playback_report_queue';

  Future<Box<dynamic>> _box() async => Hive.isBoxOpen(_boxName)
      ? Hive.box<dynamic>(_boxName)
      : Hive.openBox<dynamic>(_boxName);

  @override
  Future<List<Map<String, dynamic>>> load(String accountKey) async {
    try {
      final raw = (await _box()).get(accountKey);
      if (raw is! List) return [];
      return [
        for (final e in raw)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      debugPrint('📡 Could not load queued playback reports: $e');
      return [];
    }
  }

  @override
  Future<void> save(String accountKey, List<Map<String, dynamic>> events) async {
    try {
      final box = await _box();
      if (events.isEmpty) {
        await box.delete(accountKey);
      } else {
        await box.put(accountKey, events);
      }
    } catch (e) {
      debugPrint('📡 Could not persist queued playback reports: $e');
    }
  }
}
