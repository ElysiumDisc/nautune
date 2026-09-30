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
/// Records without a server or user (written before these were stored) are
/// treated as belonging to the current account.
bool downloadBelongsToSession({
  required String? recordServerUrl,
  required String? recordUserId,
  required String sessionServerUrl,
  required String? sessionUserId,
}) {
  if (recordServerUrl != null &&
      recordServerUrl.isNotEmpty &&
      !isSameServerUrl(recordServerUrl, sessionServerUrl)) {
    return false;
  }
  if (recordUserId != null &&
      recordUserId.isNotEmpty &&
      sessionUserId != null &&
      sessionUserId.isNotEmpty &&
      recordUserId != sessionUserId) {
    return false;
  }
  return true;
}

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
