import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/connectivity_service.dart';

class _FakeConnectivity implements Connectivity {
  _FakeConnectivity(this.check);
  final Future<List<ConnectivityResult>> Function() check;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() => check();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

ConnectivityService _service(List<ConnectivityResult> results) =>
    ConnectivityService(
      connectivity: _FakeConnectivity(() async => results),
    );

void main() {
  group('hasNetworkTransport', () {
    test('Wi-Fi or cellular is a transport', () async {
      expect(await _service([ConnectivityResult.wifi]).hasNetworkTransport(), isTrue);
      expect(await _service([ConnectivityResult.mobile]).hasNetworkTransport(), isTrue);
    });

    test('none (airplane mode) is not', () async {
      expect(await _service([ConnectivityResult.none]).hasNetworkTransport(), isFalse);
    });

    test('no platform answer in time counts as unknown (online), not offline', () async {
      final never = Completer<List<ConnectivityResult>>();
      final service = ConnectivityService(
        connectivity: _FakeConnectivity(() => never.future),
      );
      expect(await service.hasNetworkTransport(), isTrue);
    });

    test('a platform error counts as unknown (online)', () async {
      final service = ConnectivityService(
        connectivity: _FakeConnectivity(() async => throw StateError('boom')),
      );
      expect(await service.hasNetworkTransport(), isTrue);
    });
  });
}
