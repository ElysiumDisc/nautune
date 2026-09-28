import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_playlist.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/utils/collection_sort.dart';

JellyfinTrack _t(String name, String artist, String album, int n) => JellyfinTrack(
      id: name,
      name: name,
      album: album,
      artists: [artist],
      indexNumber: n,
    );

void main() {
  final tracks = [
    _t('b song', 'Zed', 'Alpha', 2),
    _t('A song', 'amy', 'Beta', 1),
    _t('c song', 'Zed', 'Alpha', 1),
  ];

  test('recent keeps server order', () {
    expect(sortFavorites(tracks, FavoritesSort.recent), same(tracks));
  });

  test('title, artist and album orders (case-insensitive)', () {
    expect(sortFavorites(tracks, FavoritesSort.title).map((t) => t.name),
        ['A song', 'b song', 'c song']);
    expect(sortFavorites(tracks, FavoritesSort.artist).first.name, 'A song');
    expect(sortFavorites(tracks, FavoritesSort.album).map((t) => t.name),
        ['c song', 'b song', 'A song']);
  });

  test('playlists by name and size', () {
    final p = [
      JellyfinPlaylist(id: '1', name: 'rock', trackCount: 3),
      JellyfinPlaylist(id: '2', name: 'Chill', trackCount: 10),
    ];
    expect(sortPlaylists(p, PlaylistSort.name).first.name, 'Chill');
    expect(sortPlaylists(p, PlaylistSort.size).first.trackCount, 10);
  });
}
