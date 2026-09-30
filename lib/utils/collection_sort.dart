/// Client-side sort orders for favourites and playlists (the server returns
/// them in one fixed order).
library;

import '../jellyfin/jellyfin_playlist.dart';
import '../jellyfin/jellyfin_track.dart';

enum FavoritesSort {
  /// The server's order. The favorites request sorts by name, so this is
  /// labelled "Default" rather than claiming a date order. (The enum name
  /// stays `recent`: it's what users' saved preference holds.)
  recent('Default'),
  title('Title'),
  artist('Artist'),
  album('Album');

  const FavoritesSort(this.label);
  final String label;

  static FavoritesSort fromName(String? name) => FavoritesSort.values
      .firstWhere((s) => s.name == name, orElse: () => FavoritesSort.recent);
}

enum PlaylistSort {
  recent('Default'),
  name('Name'),
  size('Most Tracks');

  const PlaylistSort(this.label);
  final String label;

  static PlaylistSort fromName(String? name) => PlaylistSort.values
      .firstWhere((s) => s.name == name, orElse: () => PlaylistSort.recent);
}

int _compareText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

/// [tracks] in [sort] order; `recent` keeps the server's order.
List<JellyfinTrack> sortFavorites(List<JellyfinTrack> tracks, FavoritesSort sort) {
  if (sort == FavoritesSort.recent) return tracks;
  final sorted = List<JellyfinTrack>.of(tracks);
  switch (sort) {
    case FavoritesSort.title:
      sorted.sort((a, b) => _compareText(a.name, b.name));
    case FavoritesSort.artist:
      sorted.sort((a, b) {
        final c = _compareText(a.displayArtist, b.displayArtist);
        return c != 0 ? c : _compareText(a.album ?? '', b.album ?? '');
      });
    case FavoritesSort.album:
      sorted.sort((a, b) {
        final c = _compareText(a.album ?? '', b.album ?? '');
        return c != 0 ? c : (a.indexNumber ?? 0).compareTo(b.indexNumber ?? 0);
      });
    case FavoritesSort.recent:
      break;
  }
  return sorted;
}

/// [playlists] in [sort] order; `recent` keeps the server's order.
List<JellyfinPlaylist> sortPlaylists(List<JellyfinPlaylist> playlists, PlaylistSort sort) {
  if (sort == PlaylistSort.recent) return playlists;
  final sorted = List<JellyfinPlaylist>.of(playlists);
  switch (sort) {
    case PlaylistSort.name:
      sorted.sort((a, b) => _compareText(a.name, b.name));
    case PlaylistSort.size:
      sorted.sort((a, b) => b.trackCount.compareTo(a.trackCount));
    case PlaylistSort.recent:
      break;
  }
  return sorted;
}
