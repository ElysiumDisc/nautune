import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nautune/jellyfin/robust_http_client.dart';

void main() {
  final uri = Uri.parse('https://host/jf/Playlists');

  test('POST is not retried after a 5xx response', () async {
    var calls = 0;
    final client = RobustHttpClient(
      client: MockClient((_) async {
        calls++;
        return http.Response('boom', 500);
      }),
      maxRetries: 3,
    );
    final response = await client.post(uri, body: '{}');
    expect(response.statusCode, 500);
    expect(calls, 1);
  });

  test('POST is not retried after a timeout', () async {
    var calls = 0;
    final client = RobustHttpClient(
      client: MockClient((_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      }),
      maxRetries: 3,
    );
    await expectLater(
      client.post(uri, body: '{}', timeout: const Duration(milliseconds: 20)),
      throwsA(isA<ServerSlowException>()),
    );
    expect(calls, 1);
  });

  test('POST is not retried after a mid-request connection reset', () async {
    var calls = 0;
    final client = RobustHttpClient(
      client: MockClient((_) async {
        calls++;
        throw http.ClientException('Connection reset by peer');
      }),
      maxRetries: 3,
    );
    await expectLater(
      client.post(uri, body: '{}'),
      throwsA(isA<RobustHttpException>()),
    );
    expect(calls, 1);
  });

  test('POST is retried when the connection was never established', () async {
    var calls = 0;
    final client = RobustHttpClient(
      client: MockClient((_) async {
        calls++;
        if (calls == 1) {
          throw const SocketException('Connection refused');
        }
        return http.Response('{}', 200);
      }),
      maxRetries: 2,
    );
    final response = await client.post(uri, body: '{}');
    expect(response.statusCode, 200);
    expect(calls, 2);
  });

  test('GET is still retried on 5xx', () async {
    var calls = 0;
    final client = RobustHttpClient(
      client: MockClient((_) async {
        calls++;
        return calls == 1 ? http.Response('x', 503) : http.Response('{}', 200);
      }),
      maxRetries: 2,
    );
    final response = await client.get(uri, useCache: false);
    expect(response.statusCode, 200);
    expect(calls, 2);
  });

  test('isConnectionEstablishmentFailure classification', () {
    expect(
      RobustHttpClient.isConnectionEstablishmentFailure(
        const SocketException('Failed host lookup: host'),
      ),
      isTrue,
    );
    expect(
      RobustHttpClient.isConnectionEstablishmentFailure(
        http.ClientException('Connection refused'),
      ),
      isTrue,
    );
    expect(
      RobustHttpClient.isConnectionEstablishmentFailure(
        const HandshakeException('bad cert'),
      ),
      isTrue,
    );
    expect(
      RobustHttpClient.isConnectionEstablishmentFailure(
        http.ClientException('Connection closed while receiving data'),
      ),
      isFalse,
    );
    expect(
      RobustHttpClient.isConnectionEstablishmentFailure(
        HttpTimeoutException('t', const Duration(seconds: 1)),
      ),
      isFalse,
    );
  });
}
