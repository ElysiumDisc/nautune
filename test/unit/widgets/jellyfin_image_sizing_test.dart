import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/widgets/jellyfin_image.dart';

void main() {
  group('JellyfinImage.pixelSizeFor', () {
    test('scales logical points by the pixel ratio into a bucket', () {
      expect(JellyfinImage.pixelSizeFor(JellyfinImage.listArtwork, 3), 256);
      expect(JellyfinImage.pixelSizeFor(JellyfinImage.listArtwork, 2), 128);
      expect(JellyfinImage.pixelSizeFor(JellyfinImage.gridArtwork, 3), 640);
      expect(JellyfinImage.pixelSizeFor(JellyfinImage.gridArtwork, 2), 384);
    });

    test('nearby sizes share a bucket; huge sizes are capped', () {
      expect(JellyfinImage.pixelSizeFor(175, 3),
          JellyfinImage.pixelSizeFor(210, 3));
      expect(JellyfinImage.pixelSizeFor(1024, 3), 2048);
    });
  });

  group('JellyfinTrack.playlistItemId', () {
    test('is parsed from PlaylistItemId and survives storage', () {
      final track = JellyfinTrack.fromJson({
        'Id': 'item1',
        'Name': 'Song',
        'PlaylistItemId': 'entry9',
      });
      expect(track.playlistItemId, 'entry9');
      final restored = JellyfinTrack.fromStorageJson(track.toStorageJson());
      expect(restored.playlistItemId, 'entry9');
      expect(track.copyWith(name: 'x').playlistItemId, 'entry9');
    });

    test('is null for tracks that are not playlist entries', () {
      final track = JellyfinTrack.fromJson({'Id': 'item1', 'Name': 'Song'});
      expect(track.playlistItemId, isNull);
    });
  });
}
