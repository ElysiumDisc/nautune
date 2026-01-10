import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Monitors the device's network reachability and reports whether the internet
/// is actually reachable (not just if a transport like Wi-Fi is enabled).
class ConnectivityService {
  ConnectivityService({
    Connectivity? connectivity,
    this.lookupHost = 'one.one.one.one',
    this.lookupTimeout = const Duration(seconds: 3),
  }) : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Host to resolve to verify that DNS/internet is reachable.
  final String lookupHost;

  /// Maximum amount of time to wait for DNS resolution before assuming offline.
  final Duration lookupTimeout;

  /// Emits [true] when the internet appears reachable and [false] otherwise.
  Stream<bool> get onStatusChange => _connectivity.onConnectivityChanged
      .asyncMap((results) => _probeConnection(_extractPrimaryResult(results)));

  /// Performs an immediate connectivity check.
  Future<bool> hasNetworkConnection() async {
    try {
      final results = await _connectivity.checkConnectivity().timeout(
        const Duration(seconds: 2),
        onTimeout: () => [ConnectivityResult.none],
      );
      return _probeConnection(_extractPrimaryResult(results));
    } catch (e) {
      return false;
    }
  }

  Future<bool> _probeConnection(ConnectivityResult result) async {
    if (result == ConnectivityResult.none) {
      return false;
    }

    try {
      final lookup = await InternetAddress.lookup(lookupHost).timeout(
        lookupTimeout,
        onTimeout: () => const <InternetAddress>[],
      );
      return lookup.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  ConnectivityResult _extractPrimaryResult(List<ConnectivityResult> results) {
    if (results.isEmpty) {
      return ConnectivityResult.none;
    }
    for (final result in results) {
      if (result != ConnectivityResult.vpn) {
        return result;
      }
    }
    return results.first;
  }
}
