/// Pure predicate used by `SmartPlaylistService.getTracksByAllTags`.
///
/// Returns true iff every entry in `normalizedQuery` (already lowercased
/// by the caller) is a substring of at least one entry in `trackTags`.
/// Case-insensitive on the track side; the query side is pre-normalised
/// once so the predicate doesn't allocate per-track.
///
/// Lives in its own file (no Hive/HTTP/Jellyfin imports) so it can be
/// unit-tested without bringing up the rest of the music subsystem.
bool trackMatchesAllTags(List<String>? trackTags, List<String> normalizedQuery) {
  if (trackTags == null || trackTags.isEmpty) return false;
  for (final nt in normalizedQuery) {
    var matched = false;
    for (final tt in trackTags) {
      if (tt.toLowerCase().contains(nt)) {
        matched = true;
        break;
      }
    }
    if (!matched) return false;
  }
  return true;
}
