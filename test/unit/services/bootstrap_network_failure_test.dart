import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nautune/jellyfin/jellyfin_exceptions.dart';
import 'package:nautune/jellyfin/robust_http_client.dart';
import 'package:nautune/services/bootstrap_service.dart';

void main() {
  final uri = Uri.parse('https://host/Items');

  test('genuine network failures', () {
    expect(BootstrapService.isNetworkFailure(const SocketException('x')), isTrue);
    expect(BootstrapService.isNetworkFailure(const HandshakeException('x')), isTrue);
    expect(BootstrapService.isNetworkFailure(http.ClientException('x')), isTrue);
    expect(
      BootstrapService.isNetworkFailure(RobustHttpException(
        'failed',
        uri: uri,
        lastError: const SocketException('Failed host lookup'),
      )),
      isTrue,
    );
  });

  test('server-side / slow / parse errors are not network loss', () {
    expect(
      BootstrapService.isNetworkFailure(
        RobustHttpException('failed', uri: uri, lastError: 'Server error: 500'),
      ),
      isFalse,
    );
    expect(BootstrapService.isNetworkFailure(JellyfinRequestException('500')), isFalse);
    expect(BootstrapService.isNetworkFailure(const FormatException('bad json')), isFalse);
    expect(BootstrapService.isNetworkFailure(TimeoutException('slow')), isFalse);
    expect(BootstrapService.isNetworkFailure(ServerSlowException('slow', uri: uri)), isFalse);
  });
}
