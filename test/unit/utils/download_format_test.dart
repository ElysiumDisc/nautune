import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/download_format.dart';

void main() {
  group('DownloadFormat.extensionFor', () {
    test('prefers the Content-Disposition filename', () {
      expect(
        DownloadFormat.extensionFor(
          contentType: 'application/octet-stream',
          contentDisposition: 'attachment; filename="01 - Song.FLAC"',
        ),
        'flac',
      );
    });

    test('reads RFC 5987 filename*', () {
      expect(
        DownloadFormat.extensionFor(
          contentDisposition:
              "attachment; filename=x; filename*=UTF-8''Caf%C3%A9%20Song.m4a",
        ),
        'm4a',
      );
    });

    test('ignores non-audio filename extensions', () {
      expect(
        DownloadFormat.extensionFor(
          contentType: 'audio/mpeg',
          contentDisposition: 'attachment; filename="track.bin"',
        ),
        'mp3',
      );
    });

    test('maps content types, ignoring parameters and case', () {
      expect(DownloadFormat.extensionFor(contentType: 'audio/mpeg'), 'mp3');
      expect(DownloadFormat.extensionFor(contentType: 'Audio/FLAC'), 'flac');
      expect(DownloadFormat.extensionFor(contentType: 'audio/x-m4a'), 'm4a');
      expect(DownloadFormat.extensionFor(contentType: 'audio/mp4'), 'm4a');
      expect(DownloadFormat.extensionFor(contentType: 'audio/aac'), 'aac');
      expect(
        DownloadFormat.extensionFor(contentType: 'audio/ogg; codecs=opus'),
        'ogg',
      );
      expect(DownloadFormat.extensionFor(contentType: 'audio/x-aiff'), 'aiff');
      expect(DownloadFormat.extensionFor(contentType: 'audio/wav'), 'wav');
    });

    test('falls back to the Jellyfin container list', () {
      expect(
        DownloadFormat.extensionFor(
          contentType: 'application/octet-stream',
          container: 'mov,mp4,m4a,3gp,3g2,mj2',
        ),
        'm4a',
      );
      expect(DownloadFormat.extensionFor(container: 'ogg'), 'ogg');
    });

    test('defaults to flac when nothing is known', () {
      expect(DownloadFormat.extensionFor(), DownloadFormat.fallbackExtension);
      expect(
        DownloadFormat.extensionFor(contentType: 'application/octet-stream'),
        'flac',
      );
    });
  });

  group('DownloadFormat.isOfflinePlayableExtension', () {
    test('accepts AVPlayer formats', () {
      for (final ext in ['mp3', 'm4a', 'flac', 'wav', 'aiff', 'aac', '.MP3']) {
        expect(DownloadFormat.isOfflinePlayableExtension(ext), isTrue,
            reason: ext);
      }
    });

    test('rejects formats AVPlayer cannot decode', () {
      for (final ext in ['ogg', 'opus', 'wma', 'ape', 'wv', 'mka', 'webm']) {
        expect(DownloadFormat.isOfflinePlayableExtension(ext), isFalse,
            reason: ext);
      }
    });
  });

  group('DownloadFormat.extensionOf', () {
    test('returns the lowercase extension of the file name', () {
      expect(DownloadFormat.extensionOf('/a/b/abc_Song.OPUS'), 'opus');
      expect(DownloadFormat.extensionOf('/a.dir/file'), '');
      expect(DownloadFormat.extensionOf('.hidden'), '');
      expect(DownloadFormat.extensionOf('name.'), '');
    });
  });

  group('DownloadFormat.estimateBytes', () {
    test('bitrate x duration', () {
      // 320 kbps for 60 s = 2.4 MB.
      expect(
        DownloadFormat.estimateBytes(
          bitrate: 320000,
          runTimeTicks: 60 * 10000000,
        ),
        2400000,
      );
    });

    test('null when unknown', () {
      expect(DownloadFormat.estimateBytes(bitrate: null, runTimeTicks: 1), isNull);
      expect(DownloadFormat.estimateBytes(bitrate: 1000, runTimeTicks: 0), isNull);
    });
  });
}
