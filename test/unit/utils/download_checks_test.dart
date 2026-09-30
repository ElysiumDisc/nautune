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

    test('another user does not belong', () {
      expect(belongs('https://music.example.com/jf', 'user-a'), isFalse);
      expect(belongs(null, 'user-a'), isFalse);
      expect(belongs('https://other.example.com', 'user-a'), isFalse);
    });

    test('the same user keeps its downloads after a server address change',
        () {
      expect(belongs('http://192.168.1.10:8096', 'user-b'), isTrue);
    });

    test('without a user id, another server does not belong', () {
      expect(belongs('https://other.example.com', null), isFalse);
      expect(belongs('https://other.example.com', ''), isFalse);
    });
  });

  group('continuesPartialDownload', () {
    bool continues(String? range, {int offset = 4, int total = 10}) =>
        continuesPartialDownload(
          contentRange: range,
          offset: offset,
          totalBytes: total,
        );

    test('accepts the rest of the same file', () {
      expect(continues('bytes 4-9/10'), isTrue);
      expect(continues('BYTES 4-9/10 '), isTrue);
    });

    test('rejects another range, size or a malformed header', () {
      expect(continues('bytes 0-9/10'), isFalse);
      expect(continues('bytes 4-8/10'), isFalse);
      expect(continues('bytes 4-11/12'), isFalse);
      expect(continues('bytes 4-9/*'), isFalse);
      expect(continues(null), isFalse);
      expect(continues('bytes 0-9/10', offset: 0), isFalse);
    });
  });

  group('redactSecrets', () {
    test('strips access tokens from URLs in error messages', () {
      const message = 'ClientException: Connection reset, '
          'uri=https://jf.example/Items/1/Download?ApiKey=abc123&x=1';
      final redacted = redactSecrets(message);
      expect(redacted, isNot(contains('abc123')));
      expect(redacted, contains('ApiKey=<redacted>&x=1'));
    });

    test('handles api_key spellings and several URLs', () {
      final redacted = redactSecrets(
        'a?api_key=one b&X-Emby-Token=two c?token=three',
      );
      expect(redacted, isNot(contains('one')));
      expect(redacted, isNot(contains('two')));
      expect(redacted, isNot(contains('three')));
    });

    test('leaves text without tokens alone', () {
      expect(redactSecrets('HTTP 404'), 'HTTP 404');
      expect(redactSecrets(null), 'null');
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
