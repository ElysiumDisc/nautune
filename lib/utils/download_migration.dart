import 'dart:io';

/// One-time, idempotent move of the downloads folder from its legacy location
/// (`Documents/downloads`, iCloud-backed-up) to its new location
/// (`Application Support/downloads`).
///
/// Safe to interrupt: files are moved one at a time with `rename` (atomic on
/// the same volume) and, when a copy fallback is needed, copied to a
/// temporary name and renamed into place before the source is deleted. A
/// target file that already exists is therefore always complete, so a re-run
/// only has to delete the leftover source. A marker file in [to] is written
/// once everything has moved; later calls return immediately.
class DownloadMigration {
  DownloadMigration._();

  static const String markerName = '.migrated_from_documents';
  static const String _copySuffix = '.migrating';

  /// Returns true when the migration is complete (or nothing needed moving).
  /// Returns false if any file could not be moved; the legacy directory is
  /// left in place so the next call can retry.
  static Future<bool> migrate({
    required Directory from,
    required Directory to,
    void Function(String message)? log,
  }) async {
    final marker = File('${to.path}/$markerName');
    if (from.absolute.path == to.absolute.path) return true;
    try {
      if (await marker.exists()) return true;

      if (!await from.exists()) {
        await to.create(recursive: true);
        await marker.writeAsString(DateTime.now().toIso8601String());
        return true;
      }

      // Fast path: move the whole tree with one rename when the target does
      // not exist yet (same container volume on iOS).
      if (!await to.exists()) {
        await to.parent.create(recursive: true);
        try {
          await from.rename(to.path);
          await marker.writeAsString(DateTime.now().toIso8601String());
          log?.call('Moved downloads directory ${from.path} -> ${to.path}');
          return true;
        } on FileSystemException catch (e) {
          log?.call('Directory rename failed, falling back per-file: $e');
          await to.create(recursive: true);
        }
      }

      var allMoved = true;
      final files = <File>[];
      await for (final entity in from.list(recursive: true, followLinks: false)) {
        if (entity is File) files.add(entity);
      }

      final fromRoot = from.path.endsWith('/') ? from.path : '${from.path}/';
      for (final src in files) {
        try {
          // Stale partial downloads are not worth keeping.
          if (src.path.endsWith('.tmp') || src.path.endsWith(_copySuffix)) {
            await src.delete();
            continue;
          }
          final rel = src.path.startsWith(fromRoot)
              ? src.path.substring(fromRoot.length)
              : src.uri.pathSegments.last;
          final dest = File('${to.path}/$rel');
          if (await dest.exists()) {
            // Already moved (or copied and renamed into place) on a previous
            // run that was interrupted before deleting the source.
            await src.delete();
            continue;
          }
          await dest.parent.create(recursive: true);
          try {
            await src.rename(dest.path);
          } on FileSystemException {
            final staging = File('${dest.path}$_copySuffix');
            await src.copy(staging.path);
            await staging.rename(dest.path);
            await src.delete();
          }
        } catch (e) {
          allMoved = false;
          log?.call('Failed to migrate ${src.path}: $e');
        }
      }

      // Clean up leftover staging files from an interrupted copy.
      await for (final entity in to.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith(_copySuffix)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }

      if (!allMoved) return false;

      try {
        await from.delete(recursive: true);
      } catch (e) {
        log?.call('Could not remove legacy downloads directory: $e');
      }
      await marker.writeAsString(DateTime.now().toIso8601String());
      return true;
    } catch (e) {
      log?.call('Downloads migration failed: $e');
      return false;
    }
  }
}
