import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Reports whether the device has a usable network transport (Wi-Fi,
/// cellular, ethernet).
///
/// This deliberately does NOT probe the public internet: a Jellyfin server
/// on the local network must keep working on a Wi-Fi without internet access
/// (or where public DNS is blocked). Whether the *server* answers is decided
/// separately (bootstrap sync failures and
/// `JellyfinService.isServerReachable()`, see `NautuneAppState`).
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Emits `true` when a network transport is available and `false` when
  /// there is none. One shared broadcast stream, so every listener sees the
  /// same events without triggering extra platform queries.
  late final Stream<bool> onStatusChange = _connectivity.onConnectivityChanged
      .map((results) => _extractPrimaryResult(results) != ConnectivityResult.none)
      .asBroadcastStream();

  /// Performs an immediate connectivity check (network transport present).
  Future<bool> hasNetworkConnection() => hasNetworkTransport();

  /// Whether any network interface (Wi-Fi, cellular, ethernet) is up,
  /// without probing the internet. Cheap, and correct for LAN-only servers.
  /// False in airplane mode.
  Future<bool> hasNetworkTransport() async {
    try {
      final results = await _connectivity
          .checkConnectivity()
          .timeout(const Duration(seconds: 2));
      return _extractPrimaryResult(results) != ConnectivityResult.none;
    } catch (e) {
      // Unknown (platform error, or no answer in time): let the caller try
      // the network rather than stall. Reporting "offline" here would start
      // the app offline (the startup probe) on a slow platform answer.
      return true;
    }
  }

  /// Check if currently connected via WiFi (not mobile data).
  Future<bool> isOnWifi() async {
    try {
      final results = await _connectivity.checkConnectivity().timeout(
        const Duration(seconds: 2),
        onTimeout: () => [ConnectivityResult.none],
      );
      final primary = _extractPrimaryResult(results);
      return primary == ConnectivityResult.wifi ||
             primary == ConnectivityResult.ethernet;
    } catch (e) {
      return false;
    }
  }

  /// Check if currently on mobile data.
  Future<bool> isOnMobileData() async {
    try {
      final results = await _connectivity.checkConnectivity().timeout(
        const Duration(seconds: 2),
        onTimeout: () => [ConnectivityResult.none],
      );
      final primary = _extractPrimaryResult(results);
      return primary == ConnectivityResult.mobile;
    } catch (e) {
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
    // All results are VPN — treat as no real transport so WiFi-only gates and
    // similar downstream checks don't misinterpret VPN as a usable network.
    return ConnectivityResult.none;
  }
}
