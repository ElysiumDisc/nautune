import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_auth_header.dart';

void main() {
  group('buildJellyfinAuthorization', () {
    test('modern MediaBrowser header with token', () {
      final header = buildJellyfinAuthorization(
        client: 'Nautune',
        device: 'iOS',
        deviceId: 'abc-123',
        version: '8.9.7+1',
        token: 'deadbeef',
      );
      expect(
        header,
        'MediaBrowser Client="Nautune", Device="iOS", DeviceId="abc-123", '
        'Version="8.9.7%2B1", Token="deadbeef"',
      );
    });

    test('omits Token before login', () {
      final header = buildJellyfinAuthorization(
        client: 'Nautune',
        device: 'iOS',
        deviceId: 'abc',
        version: '1.0',
      );
      expect(header, isNot(contains('Token')));
      expect(header, startsWith('MediaBrowser Client="Nautune"'));
    });

    test('escapes quotes, commas and non-ASCII so the header stays parseable', () {
      final header = buildJellyfinAuthorization(
        client: 'Nautune',
        device: 'Ben\'s "iPhone", Pro ✓',
        deviceId: 'id',
        version: '1.0',
        token: 't',
      );
      // Exactly the 10 delimiting quotes of the 5 fields remain.
      expect('"'.allMatches(header).length, 10);
      expect(header, contains('Device="Ben\'s%20%22iPhone%22%2C%20Pro%20%E2%9C%93"'));
      // Header values must be ASCII.
      expect(header.codeUnits.every((c) => c < 128), isTrue);
    });

    test('app-level helper uses Nautune client and ApiKey constant', () {
      final headers = nautuneAuthHeaders(deviceId: 'dev', token: 'tok');
      expect(headers.keys, [kJellyfinAuthorizationHeader]);
      expect(headers['Authorization'], contains('Client="Nautune"'));
      expect(headers['Authorization'], contains('DeviceId="dev"'));
      expect(headers['Authorization'], contains('Token="tok"'));
      expect(kJellyfinApiKeyQueryParam, 'ApiKey');
    });
  });
}
