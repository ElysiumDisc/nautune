import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/jellyfin_credentials.dart';
import '../models/helm_session.dart';

/// Service for Helm Mode — controlling a remote Nautune instance
/// via the Jellyfin Sessions API.
///
/// One device becomes the "commander" and sends playstate commands
/// to a target session discovered on the same server.
class HelmService extends ChangeNotifier {
  HelmService({
    required JellyfinClient client,
    required JellyfinCredentials credentials,
    required String ownDeviceId,
  })  : _client = client,
        _credentials = credentials,
        _ownDeviceId = ownDeviceId;

  final JellyfinClient _client;
  final JellyfinCredentials _credentials;
  final String _ownDeviceId;

  HelmSession? _activeTarget;
  List<HelmSession> _discoveredTargets = [];
  Timer? _pollingTimer;
  bool _isDiscovering = false;

  /// The currently controlled remote session, or null if helm is inactive.
  HelmSession? get activeTarget => _activeTarget;

  /// Whether helm mode is active (controlling a remote device).
  bool get isActive => _activeTarget != null;

  /// All discovered Nautune sessions (excluding own device).
  List<HelmSession> get discoveredTargets => _discoveredTargets;

  /// Whether a discovery scan is in progress.
  bool get isDiscovering => _isDiscovering;

  /// Stream for UI to react to target state changes.
  final _targetController = StreamController<HelmSession?>.broadcast();
  Stream<HelmSession?> get targetStream => _targetController.stream;

  /// Discover other Nautune instances on the server.
  Future<void> discoverTargets() async {
    _isDiscovering = true;
    notifyListeners();

    try {
      final sessions = await _client.fetchSessions(_credentials);
      _discoveredTargets = sessions
          .where((s) {
            final client = s['Client'] as String? ?? '';
            final deviceId = s['DeviceId'] as String? ?? '';
            // Find other Nautune instances, exclude self
            return client.contains('Nautune') && deviceId != _ownDeviceId;
          })
          .map(HelmSession.fromSessionJson)
          .toList();
    } catch (e) {
      debugPrint('Helm: Failed to discover targets: $e');
    } finally {
      _isDiscovering = false;
      notifyListeners();
    }
  }

  /// Activate helm mode — start controlling a remote session.
  void activateHelm(HelmSession target) {
    _activeTarget = target;
    _targetController.add(target);
    notifyListeners();

    // Start adaptive polling: 3s when playing, 10s when idle
    _startAdaptivePolling();

    debugPrint('Helm: Activated control of ${target.deviceName}');
  }

  /// Adaptive polling: frequent when target is playing, slower when idle.
  void _startAdaptivePolling() {
    _pollingTimer?.cancel();
    final interval = (_activeTarget?.isPaused ?? true)
        ? const Duration(seconds: 10)
        : const Duration(seconds: 3);
    _pollingTimer = Timer.periodic(interval, (_) {
      _refreshTargetState();
    });
  }

  /// Deactivate helm mode — stop controlling the remote session.
  void deactivateHelm() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _activeTarget = null;
    _targetController.add(null);
    notifyListeners();

    debugPrint('Helm: Deactivated');
  }

  /// Refresh the target's now-playing state from /Sessions.
  Future<void> _refreshTargetState() async {
    if (_activeTarget == null) return;

    try {
      final sessions = await _client.fetchSessions(_credentials);
      final match = sessions.firstWhere(
        (s) => s['Id'] == _activeTarget!.sessionId,
        orElse: () => <String, dynamic>{},
      );

      if (match.isNotEmpty) {
        final oldPaused = _activeTarget!.isPaused;
        _activeTarget = HelmSession.fromSessionJson(match);
        _targetController.add(_activeTarget);
        notifyListeners();

        // Adjust polling rate when play/pause state changes
        if (_activeTarget!.isPaused != oldPaused) {
          _startAdaptivePolling();
        }
      }
    } catch (e) {
      debugPrint('Helm: Failed to refresh target state: $e');
    }
  }

  // ============ Remote Commands ============

  Future<void> helmPlay() async {
    if (_activeTarget == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        command: 'Unpause',
      );
    } catch (e) {
      debugPrint('Helm: Play failed: $e');
    }
  }

  Future<void> helmPause() async {
    if (_activeTarget == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        command: 'Pause',
      );
    } catch (e) {
      debugPrint('Helm: Pause failed: $e');
    }
  }

  Future<void> helmTogglePlayPause() async {
    if (_activeTarget == null) return;
    if (_activeTarget!.isPaused) {
      await helmPlay();
    } else {
      await helmPause();
    }
  }

  Future<void> helmSeek(Duration position) async {
    if (_activeTarget == null) return;
    try {
      final ticks = position.inMicroseconds * 10;
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        command: 'Seek',
        seekPositionTicks: ticks,
      );
    } catch (e) {
      debugPrint('Helm: Seek failed: $e');
    }
  }

  Future<void> helmNext() async {
    if (_activeTarget == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        command: 'NextTrack',
      );
    } catch (e) {
      debugPrint('Helm: Next failed: $e');
    }
  }

  Future<void> helmPrevious() async {
    if (_activeTarget == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        command: 'PreviousTrack',
      );
    } catch (e) {
      debugPrint('Helm: Previous failed: $e');
    }
  }

  /// Send specific items to play on the remote session.
  Future<void> helmPlayItems(List<String> itemIds, {int? startIndex}) async {
    if (_activeTarget == null) return;
    try {
      await _client.sendPlayCommand(
        _credentials,
        sessionId: _activeTarget!.sessionId,
        itemIds: itemIds,
        startIndex: startIndex,
      );
    } catch (e) {
      debugPrint('Helm: Play items failed: $e');
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _targetController.close();
    super.dispose();
  }
}
