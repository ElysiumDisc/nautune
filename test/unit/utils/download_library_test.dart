import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/models/download_item.dart';
import 'package:nautune/utils/download_library.dart';

DownloadItem _dl(
  String id, {
  required String album,
  String? albumId,
  String artist = 'Artist',
  int? index,
  int? disc,
  int? year,
  DateTime? completedAt,
  DownloadStatus status = DownloadStatus.completed,
}) =>
    DownloadItem(
      track: JellyfinTrack(
        id: id,
        name: 'Song $id',
        artists: [artist],
        album: album,
        albumId: albumId,
        indexNumber: index,
        parentIndexNumber: disc,
        productionYear: year,
      ),
      localPath: '/x/$id.flac',
      status: status,
      queuedAt: DateTime(2026, 1, 1),
      completedAt: completedAt ?? DateTime(2026, 1, 2),
      owners: {},
      fileSizeBytes: 100,
    );

void main() {
  group('groupOfflineAlbums', () {
    test('groups by album id and orders tracks by disc then number', () {
      final albums = groupOfflineAlbums([
        _dl('3', album: 'B', albumId: 'b', index: 1, disc: 2),
        _dl('1', album: 'B', albumId: 'b', index: 2, disc: 1),
        _dl('2', album: 'B', albumId: 'b', index: 1, disc: 1),
        _dl('4', album: 'A', albumId: 'a', index: 1),
      ]);
      expect(albums.map((a) => a.name), ['A', 'B']);
      expect(albums[1].items.map((d) => d.track.id), ['2', '1', '3']);
      expect(albums[1].totalBytes, 300);
    });

    test('keeps same-name albums with different ids apart', () {
      final albums = groupOfflineAlbums([
        _dl('1', album: 'Greatest Hits', albumId: 'x'),
        _dl('2', album: 'Greatest Hits', albumId: 'y'),
      ]);
      expect(albums, hasLength(2));
    });

    test('skips non-completed downloads', () {
      final albums = groupOfflineAlbums([
        _dl('1', album: 'A', albumId: 'a', status: DownloadStatus.queued),
      ]);
      expect(albums, isEmpty);
    });

    test('filters by track, album or artist, case-insensitively', () {
      final items = [
        _dl('1', album: 'Blue', albumId: 'b', artist: 'Joni'),
        _dl('2', album: 'Kind of Blue', albumId: 'k', artist: 'Miles'),
        _dl('3', album: 'Other', albumId: 'o', artist: 'Someone'),
      ];
      expect(groupOfflineAlbums(items, query: 'blue').map((a) => a.albumId),
          ['b', 'k']);
      expect(groupOfflineAlbums(items, query: 'MILES').single.albumId, 'k');
      expect(groupOfflineAlbums(items, query: 'song 3').single.albumId, 'o');
      expect(groupOfflineAlbums(items, query: '  ').length, 3);
    });

    test('recent sort puts the newest download first', () {
      final albums = groupOfflineAlbums(
        [
          _dl('1', album: 'Old', albumId: 'o', completedAt: DateTime(2025)),
          _dl('2', album: 'New', albumId: 'n', completedAt: DateTime(2026, 5)),
        ],
        sort: OfflineLibrarySort.recent,
      );
      expect(albums.first.name, 'New');
    });

    test('artist sort orders by artist, then year', () {
      final albums = groupOfflineAlbums(
        [
          _dl('1', album: 'Z', albumId: 'z', artist: 'B', year: 1990),
          _dl('2', album: 'Late', albumId: 'l', artist: 'A', year: 2000),
          _dl('3', album: 'Early', albumId: 'e', artist: 'A', year: 1980),
        ],
        sort: OfflineLibrarySort.artist,
      );
      expect(albums.map((a) => a.name), ['Early', 'Late', 'Z']);
    });
  });

  group('groupOfflineArtists', () {
    test('groups albums under their artist, oldest album first', () {
      final artists = groupOfflineArtists([
        _dl('1', album: 'Second', albumId: 's', artist: 'Band', year: 2010),
        _dl('2', album: 'First', albumId: 'f', artist: 'Band', year: 2001),
        _dl('3', album: 'Solo', albumId: 'x', artist: 'Another'),
      ]);
      expect(artists.map((a) => a.name), ['Another', 'Band']);
      expect(artists[1].albums.map((a) => a.name), ['First', 'Second']);
      expect(artists[1].trackCount, 2);
      expect(artists[1].tracks.map((t) => t.id), ['2', '1']);
    });
  });
}
