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

    test('values round-trip through the server\'s WebUtility.UrlDecode', () {
      // AuthorizationContext.GetParts splits on quotes/commas (no backslash
      // escapes) and UrlDecodes each value, turning a raw '+' into a space.
      // Uri.decodeQueryComponent has the same '+' semantics.
      Map<String, String> serverParse(String header) {
        final parts = <String, String>{};
        final body = header.substring(header.indexOf(' ') + 1);
        for (final m in RegExp(r'(\w+)="([^"]*)"').allMatches(body)) {
          parts[m.group(1)!] = Uri.decodeQueryComponent(m.group(2)!);
        }
        return parts;
      }

      const values = {
        'Client': 'Nautune',
        'Device': 'Ben\'s "iPhone", 15 + Pro ✓',
        'DeviceId': 'a+b/c=d',
        'Version': '8.9.7+1',
        'Token': 'tok+en',
      };
      final parsed = serverParse(buildJellyfinAuthorization(
        client: values['Client']!,
        device: values['Device']!,
        deviceId: values['DeviceId']!,
        version: values['Version']!,
        token: values['Token'],
      ));
      expect(parsed, values);
      // A raw '+' would have been decoded as a space.
      expect(Uri.decodeQueryComponent('8.9.7+1'), '8.9.7 1');
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
