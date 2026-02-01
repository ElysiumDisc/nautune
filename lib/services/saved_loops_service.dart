import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// Represents a saved A-B loop for a track
class SavedLoop {
  final String id;
  final String trackId;
  final String trackName;
  final int startMs;
  final int endMs;
  final String? name;
  final DateTime createdAt;
  final String? filePath; // Path to extracted audio file

  SavedLoop({
    required this.id,
    required this.trackId,
    required this.trackName,
    required this.startMs,
    required this.endMs,
    this.name,
    required this.createdAt,
    this.filePath,
  });

  String get formattedStart => _formatDuration(Duration(milliseconds: startMs));
  String get formattedEnd => _formatDuration(Duration(milliseconds: endMs));
  String get displayName => name ?? '$trackName ($formattedStart - $formattedEnd)';
  Duration get startDuration => Duration(milliseconds: startMs);
  Duration get endDuration => Duration(milliseconds: endMs);

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Get filename-safe time format (e.g., "0m30s-1m45s")
  String get fileTimeFormat {
    String formatTime(Duration d) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '${m}m${s}s';
    }
    return '${formatTime(startDuration)}-${formatTime(endDuration)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'trackId': trackId,
        'trackName': trackName,
        'startMs': startMs,
        'endMs': endMs,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'filePath': filePath,
      };

  factory SavedLoop.fromJson(Map<String, dynamic> json) => SavedLoop(
        id: json['id'] as String,
        trackId: json['trackId'] as String,
        trackName: json['trackName'] as String? ?? 'Unknown',
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        name: json['name'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        filePath: json['filePath'] as String?,
      );
}

/// Service for persisting A-B loops per track
class SavedLoopsService extends ChangeNotifier {
  static final SavedLoopsService _instance = SavedLoopsService._internal();
  factory SavedLoopsService() => _instance;
  SavedLoopsService._internal();

  static const String _boxName = 'nautune_saved_loops';
  static const String _loopsFolderName = 'loops';
  Box<dynamic>? _box;

  // In-memory cache: trackId -> list of saved loops
  final Map<String, List<SavedLoop>> _loopsCache = {};

  Future<void> initialize() async {
    if (_box != null) return;
    _box = await Hive.openBox<dynamic>(_boxName);
    await _loadAllLoops();
    debugPrint('🔁 SavedLoopsService: Initialized with ${_loopsCache.length} tracks');
  }

  /// Get the loops directory path
  Future<Directory> getLoopsDirectory() async {
    final Directory baseDir;
    if (Platform.isLinux || Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      baseDir = Directory(path.join(home, 'Documents', 'nautune', _loopsFolderName));
    } else {
      final docsDir = await getApplicationDocumentsDirectory();
      baseDir = Directory(path.join(docsDir.path, _loopsFolderName));
    }

    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }
    return baseDir;
  }

  Future<void> _loadAllLoops() async {
    if (_box == null) return;
    _loopsCache.clear();

    for (final key in _box!.keys) {
      if (key is String) {
        final data = _box!.get(key);
        if (data is List) {
          final loops = <SavedLoop>[];
          for (final item in data) {
            if (item is Map) {
              try {
                loops.add(SavedLoop.fromJson(Map<String, dynamic>.from(item)));
              } catch (e) {
                debugPrint('🔁 SavedLoopsService: Error parsing loop: $e');
              }
            }
          }
          if (loops.isNotEmpty) {
            _loopsCache[key] = loops;
          }
        }
      }
    }
  }

  /// Get all saved loops for a track
  List<SavedLoop> getLoopsForTrack(String trackId) {
    return List.unmodifiable(_loopsCache[trackId] ?? []);
  }

  /// Get all saved loops across all tracks
  List<SavedLoop> getAllLoops() {
    final allLoops = <SavedLoop>[];
    for (final loops in _loopsCache.values) {
      allLoops.addAll(loops);
    }
    allLoops.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return allLoops;
  }

  /// Check if a track has any saved loops
  bool hasLoops(String trackId) {
    return _loopsCache[trackId]?.isNotEmpty ?? false;
  }

  /// Generate a filename for the loop
  /// Format: {TrackName}_{Start}-{End}_{Date}.{ext}
  String generateLoopFilename(String trackName, Duration start, Duration end, String extension) {
    // Sanitize track name for filename
    final safeName = trackName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .substring(0, trackName.length.clamp(0, 50));

    String formatTime(Duration d) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '${m}m${s}s';
    }

    final timeRange = '${formatTime(start)}-${formatTime(end)}';
    final date = DateTime.now().toIso8601String().split('T').first; // YYYY-MM-DD

    return '${safeName}_${timeRange}_$date.$extension';
  }

  /// Save a new loop for a track (metadata only, no audio extraction yet)
  Future<SavedLoop> saveLoop({
    required String trackId,
    required String trackName,
    required Duration start,
    required Duration end,
    String? name,
    String? sourceFilePath,
  }) async {
    await initialize();

    final now = DateTime.now();
    final id = '${trackId}_${now.millisecondsSinceEpoch}';

    String? savedFilePath;

    // If source file provided, copy the metadata (audio extraction would need ffmpeg)
    // For now, we just store the loop points - audio extraction can be added later

    final loop = SavedLoop(
      id: id,
      trackId: trackId,
      trackName: trackName,
      startMs: start.inMilliseconds,
      endMs: end.inMilliseconds,
      name: name,
      createdAt: now,
      filePath: savedFilePath,
    );

    final loops = _loopsCache[trackId] ?? [];
    loops.add(loop);
    _loopsCache[trackId] = loops;

    await _persistTrackLoops(trackId);
    notifyListeners();

    debugPrint('🔁 SavedLoopsService: Saved loop "${loop.displayName}"');
    return loop;
  }

  /// Delete a saved loop
  Future<void> deleteLoop(String trackId, String loopId) async {
    await initialize();

    final loops = _loopsCache[trackId];
    if (loops == null) return;

    // Find loop to get file path
    final loop = loops.where((l) => l.id == loopId).firstOrNull;
    if (loop?.filePath != null) {
      try {
        final file = File(loop!.filePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('🔁 SavedLoopsService: Error deleting loop file: $e');
      }
    }

    loops.removeWhere((l) => l.id == loopId);
    if (loops.isEmpty) {
      _loopsCache.remove(trackId);
      await _box?.delete(trackId);
    } else {
      await _persistTrackLoops(trackId);
    }

    notifyListeners();
    debugPrint('🔁 SavedLoopsService: Deleted loop $loopId');
  }

  /// Delete all loops for a track
  Future<void> deleteAllLoopsForTrack(String trackId) async {
    await initialize();

    final loops = _loopsCache[trackId];
    if (loops != null) {
      for (final loop in loops) {
        if (loop.filePath != null) {
          try {
            final file = File(loop.filePath!);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (e) {
            debugPrint('🔁 SavedLoopsService: Error deleting loop file: $e');
          }
        }
      }
    }

    _loopsCache.remove(trackId);
    await _box?.delete(trackId);
    notifyListeners();

    debugPrint('🔁 SavedLoopsService: Deleted all loops for track $trackId');
  }

  Future<void> _persistTrackLoops(String trackId) async {
    final loops = _loopsCache[trackId];
    if (loops == null || loops.isEmpty) {
      await _box?.delete(trackId);
    } else {
      await _box?.put(trackId, loops.map((l) => l.toJson()).toList());
    }
  }

  /// Get total count of saved loops
  int get totalLoopCount {
    return _loopsCache.values.fold(0, (sum, loops) => sum + loops.length);
  }

  /// Get storage info for loops folder
  Future<Map<String, dynamic>> getStorageInfo() async {
    final dir = await getLoopsDirectory();
    int fileCount = 0;
    int totalSize = 0;

    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          fileCount++;
          totalSize += await entity.length();
        }
      }
    }

    return {
      'path': dir.path,
      'fileCount': fileCount,
      'totalSizeBytes': totalSize,
      'totalSizeMB': (totalSize / (1024 * 1024)).toStringAsFixed(2),
      'savedLoopsCount': totalLoopCount,
    };
  }
}
