/// Pure checks applied to offline downloads: response validation,
/// transcode completeness, account matching and storage-scan reuse.
library;

import '../jellyfin/server_uri.dart';

/// MIME types that are never audio. A download answered with one of these
/// (a reverse-proxy login page, a JSON error body, …) must not be saved as
/// a finished track.
const Set<String> _nonAudioMimeTypes = {
  'application/json',
  'application/problem+json',
  'application/xml',
  'application/xhtml+xml',
  'application/javascript',
};

/// Whether a `200 OK` download response with [contentType] may hold audio.
/// Unknown or missing types are accepted (servers differ); text, image and
/// structured-document types are rejected.
bool isAcceptableDownloadContentType(String? contentType) {
  final mime = contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (mime.isEmpty) return true;
  if (mime.startsWith('text/') || mime.startsWith('image/')) return false;
  return !_nonAudioMimeTypes.contains(mime);
}

/// Jellyfin ticks per second.
const int _ticksPerSecond = 10000000;

/// Whether a downloaded file whose decoded length is [probedTicks] looks cut
/// short compared with the server's [expectedTicks] (a transcode that ended
/// early). Small differences (encoder padding, VBR estimates) are ignored:
/// the file must be under 90% of the expected length and at least 5 s short.
bool isLikelyTruncated({required int probedTicks, required int expectedTicks}) {
  if (probedTicks <= 0 || expectedTicks <= 0) return false;
  final missing = expectedTicks - probedTicks;
  return probedTicks < expectedTicks * 0.9 && missing >= 5 * _ticksPerSecond;
}

/// Whether a download recorded for [recordServerUrl] / [recordUserId]
/// belongs to the signed-in account ([sessionServerUrl] / [sessionUserId]).
///
/// The user id decides when both sides have one: Jellyfin user ids are
/// unique GUIDs, so the same user reached through another address (the
/// server moved from a LAN IP to a domain) keeps its downloads. A record
/// without a user id falls back to comparing server addresses; records
/// without either (written before these were stored) belong to the current
/// account.
bool downloadBelongsToSession({
  required String? recordServerUrl,
  required String? recordUserId,
  required String sessionServerUrl,
  required String? sessionUserId,
}) {
  final hasRecordUser = recordUserId != null && recordUserId.isNotEmpty;
  final hasSessionUser = sessionUserId != null && sessionUserId.isNotEmpty;
  if (hasRecordUser && hasSessionUser) return recordUserId == sessionUserId;
  if (recordServerUrl != null &&
      recordServerUrl.isNotEmpty &&
      !isSameServerUrl(recordServerUrl, sessionServerUrl)) {
    return false;
  }
  return true;
}

/// Whether a `206 Partial Content` response with [contentRange] (e.g.
/// `bytes 1000-4999/5000`) continues a partial download of [offset] bytes
/// of a [totalBytes]-byte file, i.e. runs from [offset] to the end of the
/// same-sized file. Anything else must not be appended to the partial file.
bool continuesPartialDownload({
  required String? contentRange,
  required int offset,
  required int totalBytes,
}) {
  if (contentRange == null || offset <= 0 || totalBytes <= offset) return false;
  final match = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+)\s*$', caseSensitive: false)
      .firstMatch(contentRange);
  if (match == null) return false;
  final start = int.parse(match[1]!);
  final end = int.parse(match[2]!);
  final total = int.parse(match[3]!);
  return start == offset && total == totalBytes && end == totalBytes - 1;
}

/// Query parameters that carry an access token.
final RegExp _secretQueryParam = RegExp(
  r'([?&;](?:api_?key|x-emby-token|x-mediabrowser-token|access_?token|token)=)'
  r'''[^&#\s,;'")\]]+''',
  caseSensitive: false,
);

/// [error] as text that is safe to log or persist: access tokens in URLs
/// (the `ApiKey=` query parameter of download/stream/artwork URLs, which
/// `http`'s `ClientException` and dart:io's `HttpException` messages
/// include) are replaced with `<redacted>`.
String redactSecrets(Object? error) => '$error'.replaceAllMapped(
      _secretQueryParam,
      (m) => '${m[1]}<redacted>',
    );

/// Whether the expensive part of a storage-stats scan (audio cache, waveform
/// and chart directories) can be reused instead of rescanning.
///
/// A new request for the same [currentRevision] as the last scan is an
/// explicit refresh (the screen asked again after an action), so it rescans.
/// A request caused by downloads changing (a different revision) reuses a
/// scan younger than [maxAge]: finishing a track doesn't change those
/// directories.
bool canReuseStorageScan({
  required bool hasScan,
  required int scanRevision,
  required int currentRevision,
  required Duration age,
  required Duration maxAge,
}) {
  if (!hasScan) return false;
  if (scanRevision == currentRevision) return false;
  return age < maxAge;
}
