/// Pure helpers for building Jellyfin server URLs.
///
/// Jellyfin is frequently deployed behind a reverse proxy under a sub-path
/// (e.g. `https://example.com/jellyfin`). `Uri.resolve('/System/Info')`
/// treats the leading slash as absolute and silently drops that base path,
/// so every Jellyfin URL in the app must be built through [buildServerUri].
library;

/// Joins [baseUrl] (scheme, host, optional port and optional base path) with
/// the API [path] and optional [query] parameters.
///
/// - Base path is preserved: `https://h/jellyfin` + `/System/Info/Public`
///   → `https://h/jellyfin/System/Info/Public`.
/// - Leading/trailing/duplicate slashes on either side are ignored.
/// - An explicit port is preserved.
/// - Each path segment and every query key/value is percent-encoded.
/// - Any query or fragment on [baseUrl] is dropped.
/// - Null or empty [query] produces a URL without a `?`.
Uri buildServerUri(
  String baseUrl,
  String path, [
  Map<String, String>? query,
]) {
  final base = Uri.parse(baseUrl.trim());
  final segments = <String>[
    ...base.pathSegments.where((s) => s.isNotEmpty),
    ...path.split('/').where((s) => s.isNotEmpty),
  ];
  return Uri(
    scheme: base.scheme,
    userInfo: base.userInfo.isEmpty ? null : base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: segments,
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );
}

/// String form of [buildServerUri].
String buildServerUrl(
  String baseUrl,
  String path, [
  Map<String, String>? query,
]) =>
    buildServerUri(baseUrl, path, query).toString();

/// Normalizes a user-entered server URL: trims whitespace and trailing
/// slashes but KEEPS any base path (reverse-proxy sub-path).
String normalizeServerBaseUrl(String rawUrl) {
  var trimmed = rawUrl.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
