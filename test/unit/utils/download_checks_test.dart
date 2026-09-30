import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/download_checks.dart';

void main() {
  group('isAcceptableDownloadContentType', () {
    test('accepts audio, octet-stream and unknown types', () {
      expect(isAcceptableDownloadContentType('audio/flac'), isTrue);
      expect(isAcceptableDownloadContentType('audio/mpeg; charset=binary'),
          isTrue);
      expect(isAcceptableDownloadContentType('application/octet-stream'),
          isTrue);
      expect(isAcceptableDownloadContentType('video/mp4'), isTrue);
      expect(isAcceptableDownloadContentType(null), isTrue);
      expect(isAcceptableDownloadContentType(''), isTrue);
    });

    test('rejects pages, documents and images', () {
      expect(isAcceptableDownloadContentType('text/html; charset=utf-8'),
          isFalse);
      expect(isAcceptableDownloadContentType('TEXT/PLAIN'), isFalse);
      expect(isAcceptableDownloadContentType('application/json'), isFalse);
      expect(isAcceptableDownloadContentType('application/problem+json'),
          isFalse);
      expect(isAcceptableDownloadContentType('application/xhtml+xml'),
          isFalse);
      expect(isAcceptableDownloadContentType('image/jpeg'), isFalse);
    });
  });

  group('isLikelyTruncated', () {
    const s = 10000000; // ticks per second

    test('flags a transcode that stopped well short', () {
      expect(isLikelyTruncated(probedTicks: 120 * s, expectedTicks: 240 * s),
          isTrue);
    });

    test('ignores small differences', () {
      // 97%: encoder padding / VBR estimate.
      expect(isLikelyTruncated(probedTicks: 233 * s, expectedTicks: 240 * s),
          isFalse);
      // Under 90% but only 3 s short (very short track).
      expect(isLikelyTruncated(probedTicks: 20 * s, expectedTicks: 23 * s),
          isFalse);
    });

    test('ignores unknown lengths', () {
      expect(isLikelyTruncated(probedTicks: 0, expectedTicks: 240 * s),
          isFalse);
      expect(isLikelyTruncated(probedTicks: 120 * s, expectedTicks: 0),
          isFalse);
    });
  });

  group('downloadBelongsToSession', () {
    bool belongs(String? server, String? user) => downloadBelongsToSession(
          recordServerUrl: server,
          recordUserId: user,
          sessionServerUrl: 'https://music.example.com/jf/',
          sessionUserId: 'user-b',
        );

    test('records without an account belong to the current one', () {
      expect(belongs(null, null), isTrue);
      expect(belongs('', ''), isTrue);
    });

    test('same server (trailing slashes ignored) and user', () {
      expect(belongs('https://music.example.com/jf', 'user-b'), isTrue);
      expect(belongs('https://music.example.com/jf//', null), isTrue);
    });

    test('same server spelled with another scheme/host case or port', () {
      expect(belongs('HTTPS://Music.Example.com:443/jf', 'user-b'), isTrue);
    });

    test('another server or user does not belong', () {
      expect(belongs('https://other.example.com', 'user-b'), isFalse);
      expect(belongs('https://music.example.com/jf', 'user-a'), isFalse);
      expect(belongs(null, 'user-a'), isFalse);
    });
  });

  group('canReuseStorageScan', () {
    bool reuse({
      bool hasScan = true,
      int scanRevision = 1,
      int currentRevision = 2,
      Duration age = const Duration(seconds: 5),
    }) =>
        canReuseStorageScan(
          hasScan: hasScan,
          scanRevision: scanRevision,
          currentRevision: currentRevision,
          age: age,
          maxAge: const Duration(seconds: 30),
        );

    test('reuses a recent scan when downloads changed', () {
      expect(reuse(), isTrue);
    });

    test('rescans on an explicit refresh (same revision)', () {
      expect(reuse(scanRevision: 2, currentRevision: 2), isFalse);
    });

    test('rescans when stale or missing', () {
      expect(reuse(age: const Duration(seconds: 30)), isFalse);
      expect(reuse(hasScan: false), isFalse);
    });
  });
}
