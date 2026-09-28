import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/download_paths.dart';

void main() {
  const oldContainer =
      '/var/mobile/Containers/Data/Application/1111-AAAA/Documents/downloads';
  const newRoot =
      '/var/mobile/Containers/Data/Application/2222-BBBB/Library/Application Support/downloads';

  group('DownloadPaths.toRelative', () {
    test('absolute path from an old container keeps the part after /downloads/', () {
      expect(
        DownloadPaths.toRelative('$oldContainer/abc123_My Song.flac', rootPath: newRoot),
        'abc123_My Song.flac',
      );
    });

    test('absolute artwork and artist paths keep their subfolder', () {
      expect(DownloadPaths.toRelative('$oldContainer/artwork/album42.jpg'),
          'artwork/album42.jpg');
      expect(DownloadPaths.toRelative('$oldContainer/artists/artist7.jpg'),
          'artists/artist7.jpg');
    });

    test('path under the current root strips the root prefix', () {
      expect(DownloadPaths.toRelative('$newRoot/artwork/a.jpg', rootPath: newRoot),
          'artwork/a.jpg');
      expect(DownloadPaths.toRelative('$newRoot/x.mp3', rootPath: '$newRoot/'),
          'x.mp3');
    });

    test('already-relative path is returned unchanged', () {
      expect(DownloadPaths.toRelative('abc_Song.flac', rootPath: newRoot),
          'abc_Song.flac');
      expect(DownloadPaths.toRelative('artwork/album42.jpg'), 'artwork/album42.jpg');
    });

    test('absolute path without a downloads segment falls back to the filename', () {
      expect(DownloadPaths.toRelative('/private/tmp/elsewhere/t1_Song.m4a'),
          't1_Song.m4a');
    });

    test('empty stays empty (unresolved queue placeholder)', () {
      expect(DownloadPaths.toRelative(''), '');
      expect(DownloadPaths.toRelative('', rootPath: newRoot), '');
    });

    test('traversal segments are dropped', () {
      expect(DownloadPaths.toRelative('../../etc/passwd'), 'etc/passwd');
      expect(DownloadPaths.toRelative('./artwork/../a.jpg'), 'artwork/a.jpg');
    });

    test('backslashes are normalized', () {
      expect(DownloadPaths.toRelative(r'C:\Users\me\downloads\artwork\a.jpg'),
          'artwork/a.jpg');
    });
  });

  group('DownloadPaths.toAbsolute / resolve', () {
    test('joins a relative path onto the root', () {
      expect(DownloadPaths.toAbsolute('abc.flac', newRoot), '$newRoot/abc.flac');
      expect(DownloadPaths.toAbsolute('artwork/a.jpg', '$newRoot/'),
          '$newRoot/artwork/a.jpg');
    });

    test('empty relative stays empty', () {
      expect(DownloadPaths.toAbsolute('', newRoot), '');
      expect(DownloadPaths.resolve('', newRoot), '');
    });

    test('resolve rebases a legacy absolute path onto the current root', () {
      expect(DownloadPaths.resolve('$oldContainer/abc_Song.flac', newRoot),
          '$newRoot/abc_Song.flac');
      expect(DownloadPaths.resolve('$oldContainer/artwork/al.jpg', newRoot),
          '$newRoot/artwork/al.jpg');
    });

    test('resolve is idempotent for current-root and relative paths', () {
      expect(DownloadPaths.resolve('$newRoot/abc.flac', newRoot), '$newRoot/abc.flac');
      expect(DownloadPaths.resolve('abc.flac', newRoot), '$newRoot/abc.flac');
    });

    test('round trip: toRelative(resolve(x)) == toRelative(x)', () {
      const stored = '$oldContainer/t9_Track.opus';
      final abs = DownloadPaths.resolve(stored, newRoot);
      expect(DownloadPaths.toRelative(abs, rootPath: newRoot), 't9_Track.opus');
    });
  });
}
