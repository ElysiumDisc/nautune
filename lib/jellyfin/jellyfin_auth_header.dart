/// Jellyfin authorization helpers (modern, non-legacy form).
///
/// Jellyfin 10.7+ accepts `Authorization: MediaBrowser Client="…", …,
/// Token="…"`. The legacy `X-Emby-Authorization`, `X-Emby-Token`,
/// `X-MediaBrowser-Token` headers and the `api_key` query parameter are gated
/// behind `ServerConfiguration.EnableLegacyAuthorization` on newer servers,
/// so the app must not rely on them.
library;

import 'package:flutter/foundation.dart';

import '../app_version.dart';

/// Client name reported to Jellyfin.
const String kJellyfinClientName = 'Nautune';

/// Query parameter carrying the access token for URLs that cannot send
/// headers (AVPlayer streams, system image loaders, CarPlay artwork).
///
/// Not described in the OpenAPI spec (its only security scheme is the
/// `Authorization` header), but read unconditionally by the server's
/// `AuthorizationContext` (10.9 → 12.1), unlike `api_key`, which is only
/// honoured when `EnableLegacyAuthorization` is on (off by default in 12.0).
const String kJellyfinApiKeyQueryParam = 'ApiKey';

/// Header name for the modern Jellyfin authorization scheme.
const String kJellyfinAuthorizationHeader = 'Authorization';

/// Builds the value of the `Authorization` header.
///
/// Values are percent-encoded (like the official Jellyfin SDKs) so quotes,
/// commas and non-ASCII characters can't break the header grammar. The
/// server (`AuthorizationContext.GetParts`, 10.7 → 12.1) splits on `"`/`,`
/// with no backslash escaping and runs every value through
/// `WebUtility.UrlDecode`, which also turns a literal `+` into a space — so
/// encoding is required for correctness, not just safety: an unencoded
/// version `8.9.7+1` would be recorded as `8.9.7 1`, while `8.9.7%2B1`
/// round-trips. Empty fields are omitted, so [token] is left out when
/// null/empty (e.g. before login).
String buildJellyfinAuthorization({
  required String client,
  required String device,
  required String deviceId,
  required String version,
  String? token,
}) {
  final parts = <String, String>{
    'Client': client,
    'Device': device,
    'DeviceId': deviceId,
    'Version': version,
    'Token': token ?? '',
  }..removeWhere((_, value) => value.isEmpty);
  final encoded = parts.entries
      .map((e) => '${e.key}="${Uri.encodeComponent(e.value)}"')
      .join(', ');
  return 'MediaBrowser $encoded';
}

/// App-level convenience: the `Authorization` header value using Nautune's
/// client name, the current platform as device name and the app version.
String nautuneAuthorization({required String deviceId, String? token}) {
  return buildJellyfinAuthorization(
    client: kJellyfinClientName,
    device: defaultTargetPlatform.name,
    deviceId: deviceId,
    version: AppVersion.current,
    token: token,
  );
}

/// Header map containing just the authorization header.
Map<String, String> nautuneAuthHeaders({
  required String deviceId,
  String? token,
}) {
  return {
    kJellyfinAuthorizationHeader:
        nautuneAuthorization(deviceId: deviceId, token: token),
  };
}
