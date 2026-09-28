/// Pure path helpers for offline downloads.
///
/// Download records persist file paths *relative* to the downloads root so
/// they survive the iOS app-container UUID changing (reinstall, restore,
/// some updates). Legacy records stored absolute paths such as
/// `/var/mobile/Containers/Data/Application/<UUID>/Documents/downloads/x.flac`;
/// [toRelative] rebases those onto whatever the current root is.
class DownloadPaths {
  DownloadPaths._();

  /// Name of the downloads folder under the app's storage directory.
  static const String folderName = 'downloads';

  static const String _marker = '/$folderName/';

  /// Normalize separators to `/`.
  static String _normalize(String path) => path.replaceAll('\\', '/');

  static final RegExp _windowsDrive = RegExp(r'^[A-Za-z]:/');

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || _windowsDrive.hasMatch(path);

  static String _trimTrailingSlash(String path) =>
      path.length > 1 && path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path;

  /// Drop empty, `.` and `..` segments so a stored path can never escape the
  /// downloads root.
  static String _clean(String relative) {
    final parts = relative
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    return parts.join('/');
  }

  /// Convert a stored path (absolute legacy path or already-relative path) to
  /// a path relative to the downloads root.
  ///
  /// - Empty input stays empty (placeholder for not-yet-resolved queue items).
  /// - If [rootPath] is given and [storedPath] lives under it, the root prefix
  ///   is stripped.
  /// - Other absolute paths keep the portion after the last `/downloads/`
  ///   segment (e.g. `artwork/<albumId>.jpg`), or just the filename when no
  ///   such segment exists.
  /// - Relative input is returned cleaned.
  static String toRelative(String storedPath, {String? rootPath}) {
    if (storedPath.isEmpty) return '';
    final path = _normalize(storedPath);

    if (rootPath != null && rootPath.isNotEmpty) {
      final root = _trimTrailingSlash(_normalize(rootPath));
      if (path.startsWith('$root/')) {
        return _clean(path.substring(root.length + 1));
      }
    }

    if (!_isAbsolute(path)) return _clean(path);

    final idx = path.lastIndexOf(_marker);
    if (idx >= 0) {
      final rel = _clean(path.substring(idx + _marker.length));
      if (rel.isNotEmpty) return rel;
    }
    final slash = path.lastIndexOf('/');
    return _clean(slash >= 0 ? path.substring(slash + 1) : path);
  }

  /// Join a relative path onto [rootPath]. Empty relative stays empty.
  static String toAbsolute(String relativePath, String rootPath) {
    final rel = _clean(_normalize(relativePath));
    if (rel.isEmpty) return '';
    return '${_trimTrailingSlash(_normalize(rootPath))}/$rel';
  }

  /// Resolve any stored path (legacy absolute or relative) to an absolute
  /// path under the current [rootPath].
  static String resolve(String storedPath, String rootPath) =>
      toAbsolute(toRelative(storedPath, rootPath: rootPath), rootPath);
}
