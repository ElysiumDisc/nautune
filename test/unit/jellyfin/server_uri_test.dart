import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/server_uri.dart';

void main() {
  group('buildServerUri', () {
    test('preserves reverse-proxy sub-path', () {
      expect(
        buildServerUrl('https://host/jellyfin', '/System/Info/Public'),
        'https://host/jellyfin/System/Info/Public',
      );
    });

    test('handles trailing slash on base and missing leading slash on path', () {
      expect(
        buildServerUrl('https://host/jellyfin/', 'System/Info/Public'),
        'https://host/jellyfin/System/Info/Public',
      );
      expect(
        buildServerUrl('https://host/a/b//', '//Items//x/'),
        'https://host/a/b/Items/x',
      );
    });

    test('root server', () {
      expect(
        buildServerUrl('https://host', '/Items'),
        'https://host/Items',
      );
      expect(
        buildServerUrl('https://host/', '/Items'),
        'https://host/Items',
      );
    });

    test('preserves explicit port', () {
      final uri = buildServerUri('http://192.168.1.5:8096', '/Audio/abc/universal');
      expect(uri.port, 8096);
      expect(uri.toString(), 'http://192.168.1.5:8096/Audio/abc/universal');
      expect(
        buildServerUrl('https://host:8920/jf', '/Items'),
        'https://host:8920/jf/Items',
      );
    });

    test('encodes query parameters and path segments', () {
      final uri = buildServerUri('https://host/jf', '/Items', {
        'searchTerm': 'AC/DC & Friends',
        'ApiKey': 'a+b=c',
      });
      expect(uri.path, '/jf/Items');
      expect(uri.queryParameters['searchTerm'], 'AC/DC & Friends');
      expect(uri.queryParameters['ApiKey'], 'a+b=c');
      expect(uri.query, isNot(contains('&Friends')));
      expect(uri.query, isNot(contains('a+b=c')));

      final seg = buildServerUri('https://host', '/Items/a b#c');
      expect(seg.toString(), 'https://host/Items/a%20b%23c');
    });

    test('empty or null query yields no question mark', () {
      expect(buildServerUrl('https://host', '/Items', {}), 'https://host/Items');
      expect(buildServerUrl('https://host', '/Items'), 'https://host/Items');
    });

    test('drops query/fragment present on the base URL', () {
      expect(
        buildServerUrl('https://host/jf?x=1#frag', '/Items'),
        'https://host/jf/Items',
      );
    });

    test('works for demo scheme', () {
      expect(
        buildServerUrl('demo://nautune', '/Items/1/Images/Primary'),
        'demo://nautune/Items/1/Images/Primary',
      );
    });
  });

  group('normalizeServerBaseUrl', () {
    test('keeps path, trims whitespace and trailing slashes', () {
      expect(normalizeServerBaseUrl('  https://host/jellyfin//  '),
          'https://host/jellyfin');
      expect(normalizeServerBaseUrl('https://host:8096/'), 'https://host:8096');
    });
  });
}
