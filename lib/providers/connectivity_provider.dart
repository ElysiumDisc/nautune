import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/connectivity_service.dart';

/// Manages network connectivity state.
///
/// Responsibilities:
/// - Monitor network availability
/// - Provide connectivity status to the app
/// - Emit events when connectivity changes
///
/// This is a thin wrapper around ConnectivityService that makes it
/// compatible with the Provider pattern.
class ConnectivityProvider extends ChangeNotifier {
  ConnectivityProvider({
    required ConnectivityService connectivityService,
  }) : _connectivityService = connectivityService;

  final ConnectivityService _connectivityService;
  StreamSubscription<bool>? _connectivitySubscription;
  bool _networkAvailable = true;
  bool _initialized = false;

  bool get networkAvailable => _networkAvailable;
  bool get isInitialized => _initialized;

  /// Initialize connectivity monitoring.
  ///
  /// This should be called once during app startup.
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('ConnectivityProvider already initialized');
      return;
    }

    debugPrint('ConnectivityProvider: Initializing...');

    try {
      final isOnline = await _connectivityService.hasNetworkConnection();
      _networkAvailable = isOnline;
      debugPrint('ConnectivityProvider: Initial network status: $isOnline');
    } catch (error) {
      debugPrint('ConnectivityProvider: Connectivity probe failed: $error');
      _networkAvailable = false;
    }

    _connectivitySubscription = _connectivityService.onStatusChange.listen(
      _handleConnectivityChange,
    );

    _initialized = true;
    notifyListeners();
  }

  void _handleConnectivityChange(bool isOnline) {
    final wasOnline = _networkAvailable;
    _networkAvailable = isOnline;

    if (wasOnline != isOnline) {
      debugPrint('ConnectivityProvider: Network status changed to: $isOnline');
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
