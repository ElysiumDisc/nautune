import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/models/download_item.dart';
import 'package:nautune/repositories/offline_repository.dart';

DownloadItem _dl(String id, {Set<String> owners = const {}}) => DownloadItem(
      track: JellyfinTrack(id: id, name: 'Song $id', artists: const ['A'], album: 'Album'),
      localPath: '/x/$id.flac',
      status: DownloadStatus.completed,
      queuedAt: DateTime(2026, 1, 1),
      completedAt: DateTime(2026, 1, 2),
      owners: owners,
      fileSizeBytes: 100,
    );

List<String> _ids(List<DownloadItem> items) =>
    items.map((d) => d.track.id).toList();

void main() {
  group('offlinePlaylistDownloads', () {
    final completed = [
      _dl('a', owners: {'album1'}),
      _dl('b', owners: {'pl'}),
      _dl('c'),
      _dl('d', owners: {'pl'}),
    ];

    test('cached membership: downloaded members in playlist order, '
        'however they were downloaded', () {
      final result = offlinePlaylistDownloads(
        playlistId: 'pl',
        memberIds: const ['d', 'x', 'a', 'c'],
        completed: completed,
      );
      // 'x' isn't downloaded; 'b' is owned by the playlist but no longer in it.
      expect(_ids(result), ['d', 'a', 'c']);
    });

    test('keeps duplicate playlist entries', () {
      final result = offlinePlaylistDownloads(
        playlistId: 'pl',
        memberIds: const ['a', 'c', 'a'],
        completed: completed,
      );
      expect(_ids(result), ['a', 'c', 'a']);
    });

    test('no cached membership: falls back to download ownership', () {
      final result = offlinePlaylistDownloads(
        playlistId: 'pl',
        memberIds: null,
        completed: completed,
      );
      expect(_ids(result), ['b', 'd']);
    });

    test('empty cached playlist lists nothing', () {
      final result = offlinePlaylistDownloads(
        playlistId: 'pl',
        memberIds: const [],
        completed: completed,
      );
      expect(result, isEmpty);
    });
  });
}
