import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/network_download_service.dart';

void main() {
  group('NetworkDownloadService.toRelativePath', () {
    test('keeps paths that are already relative', () {
      expect(
        NetworkDownloadService.toRelativePath('audio/radio radi0.mp3'),
        'audio/radio radi0.mp3',
      );
    });

    test('migrates absolute paths from older builds (container moves)', () {
      expect(
        NetworkDownloadService.toRelativePath(
          '/var/mobile/Containers/Data/Application/ABC-123/Documents/network/audio/bible.mp3',
        ),
        'audio/bible.mp3',
      );
      expect(
        NetworkDownloadService.toRelativePath(
          '/private/var/Documents/network/images/BV.FM.jpg',
        ),
        'images/BV.FM.jpg',
      );
    });

    test('returns null for paths outside the network folder or empty', () {
      expect(NetworkDownloadService.toRelativePath('/tmp/other/file.mp3'), isNull);
      expect(NetworkDownloadService.toRelativePath(''), isNull);
      expect(NetworkDownloadService.toRelativePath(null), isNull);
    });
  });
}
