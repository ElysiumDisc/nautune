import '../jellyfin/jellyfin_track.dart';
import '../models/download_item.dart';

/// Sort orders for the offline library.
enum OfflineLibrarySort {
  name('Name'),
  recent('Recently downloaded'),
  artist('Artist');

  const OfflineLibrarySort(this.label);
  final String label;
}

/// Downloaded tracks of one album.
class OfflineAlbumGroup {
  OfflineAlbumGroup({
    required this.key,
    required this.albumId,
    required this.name,
    required this.artist,
    required this.year,
    required this.imageTag,
    required this.items,
  });

  /// Grouping key: album id, else album name.
  final String key;
  final String? albumId;
  final String name;
  final String artist;
  final int? year;
  final String? imageTag;

  /// Sorted by disc then track number.
  final List<DownloadItem> items;

  List<JellyfinTrack> get tracks =>
      items.map((d) => d.track).toList(growable: false);

  int get totalBytes =>
      items.fold(0, (sum, d) => sum + (d.fileSizeBytes ?? d.totalBytes ?? 0));

  DateTime get latestDownload => items
      .map((d) => d.completedAt ?? d.queuedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Downloaded albums of one artist.
class OfflineArtistGroup {
  OfflineArtistGroup({required this.name, required this.albums});

  final String name;
  final List<OfflineAlbumGroup> albums;

  int get trackCount => albums.fold(0, (sum, a) => sum + a.items.length);

  List<JellyfinTrack> get tracks =>
      [for (final album in albums) ...album.tracks];

  DateTime get latestDownload => albums
      .map((a) => a.latestDownload)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// Case-insensitive match of [query] against track, album and artist names
/// (every credited artist, not just the first). An empty query matches
/// everything.
bool offlineItemMatches(DownloadItem item, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final track = item.track;
  return track.name.toLowerCase().contains(q) ||
      (track.album ?? '').toLowerCase().contains(q) ||
      track.displayArtist.toLowerCase().contains(q) ||
      track.artists.any((a) => a.toLowerCase().contains(q));
}

/// Every credited artist of [track] as (id, name), for building offline
/// artist lists: a collaboration belongs to each of its artists, under the
/// artist's own name (not `displayArtist`'s "A & 1 more"). The id is the
/// Jellyfin artist id when the server sent one per artist, else the name.
List<({String id, String name})> offlineTrackArtists(JellyfinTrack track) {
  final names = track.artists;
  final ids = track.artistIds;
  if (names.isEmpty) {
    const unknown = 'Unknown Artist';
    return [(id: ids.isNotEmpty ? ids.first : unknown, name: unknown)];
  }
  return [
    for (var i = 0; i < names.length; i++)
      (
        id: ids.length == names.length
            ? ids[i]
            : (i == 0 && ids.isNotEmpty ? ids.first : names[i]),
        name: names[i],
      ),
  ];
}

int _compareText(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

int _compareTrackOrder(DownloadItem a, DownloadItem b) {
  final discA = a.track.discNumber ?? 0;
  final discB = b.track.discNumber ?? 0;
  if (discA != discB) return discA.compareTo(discB);
  final idxA = a.track.indexNumber ?? 0;
  final idxB = b.track.indexNumber ?? 0;
  if (idxA != idxB) return idxA.compareTo(idxB);
  return _compareText(a.track.name, b.track.name);
}

/// Group completed downloads into albums (by album id, so same-name albums
/// stay separate), filtered by [query] and ordered by [sort].
List<OfflineAlbumGroup> groupOfflineAlbums(
  Iterable<DownloadItem> downloads, {
  String query = '',
  OfflineLibrarySort sort = OfflineLibrarySort.name,
}) {
  final groups = <String, List<DownloadItem>>{};
  for (final item in downloads) {
    if (!item.isCompleted || !offlineItemMatches(item, query)) continue;
    final key = item.track.albumId ?? item.track.album ?? 'Unknown Album';
    groups.putIfAbsent(key, () => <DownloadItem>[]).add(item);
  }

  final albums = groups.entries.map((entry) {
    final items = entry.value..sort(_compareTrackOrder);
    final first = items.first.track;
    return OfflineAlbumGroup(
      key: entry.key,
      albumId: first.albumId,
      name: first.album ?? 'Unknown Album',
      artist: first.displayArtist,
      year: first.productionYear,
      imageTag: first.albumPrimaryImageTag,
      items: items,
    );
  }).toList();

  switch (sort) {
    case OfflineLibrarySort.name:
      albums.sort((a, b) => _compareText(a.name, b.name));
    case OfflineLibrarySort.recent:
      albums.sort((a, b) => b.latestDownload.compareTo(a.latestDownload));
    case OfflineLibrarySort.artist:
      albums.sort((a, b) {
        final byArtist = _compareText(a.artist, b.artist);
        if (byArtist != 0) return byArtist;
        final yearA = a.year ?? 0;
        final yearB = b.year ?? 0;
        if (yearA != yearB) return yearA.compareTo(yearB);
        return _compareText(a.name, b.name);
      });
  }
  return albums;
}

/// Group completed downloads by artist, each with its albums (sorted by
/// year then name). Artists are ordered by name, or by most recent download
/// for [OfflineLibrarySort.recent].
List<OfflineArtistGroup> groupOfflineArtists(
  Iterable<DownloadItem> downloads, {
  String query = '',
  OfflineLibrarySort sort = OfflineLibrarySort.name,
}) {
  final byArtist = <String, List<DownloadItem>>{};
  for (final item in downloads) {
    if (!item.isCompleted || !offlineItemMatches(item, query)) continue;
    byArtist
        .putIfAbsent(item.track.displayArtist, () => <DownloadItem>[])
        .add(item);
  }

  final artists = byArtist.entries.map((entry) {
    final albums = groupOfflineAlbums(entry.value)
      ..sort((a, b) {
        final yearA = a.year ?? 0;
        final yearB = b.year ?? 0;
        if (yearA != yearB) return yearA.compareTo(yearB);
        return _compareText(a.name, b.name);
      });
    return OfflineArtistGroup(name: entry.key, albums: albums);
  }).toList();

  if (sort == OfflineLibrarySort.recent) {
    artists.sort((a, b) => b.latestDownload.compareTo(a.latestDownload));
  } else {
    artists.sort((a, b) => _compareText(a.name, b.name));
  }
  return artists;
}
