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
    notifyListeners();

    // Immediately fetch the latest state, then start periodic polling
    _refreshTargetState();
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
    notifyListeners();

    debugPrint('Helm: Deactivated');
  }

  /// Suspend polling without clearing the target (for offline mode).
  void suspendPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    debugPrint('Helm: Polling suspended (offline)');
  }

  /// Resume polling if a target is active (when coming back online).
  void resumePolling() {
    if (_activeTarget != null && _pollingTimer == null) {
      _startAdaptivePolling();
      debugPrint('Helm: Polling resumed');
    }
  }

  /// Refresh the target's now-playing state from /Sessions.
  Future<void> refreshTarget() => _refreshTargetState();

  Future<void> _refreshTargetState() async {
    // Capture to local to avoid null-after-await race condition
    final target = _activeTarget;
    if (target == null) return;

    try {
      final sessions = await _client.fetchSessions(_credentials);
      // Re-check after await in case deactivateHelm() was called
      if (_activeTarget == null) return;

      final match = sessions.firstWhere(
        (s) => s['Id'] == target.sessionId,
        orElse: () => <String, dynamic>{},
      );

      if (match.isNotEmpty) {
        final oldPaused = _activeTarget!.isPaused;
        final updated = HelmSession.fromSessionJson(match);
        // Only notify if state actually changed (equality check)
        if (_activeTarget != updated) {
          _activeTarget = updated;
          notifyListeners();
        }

        // Adjust polling rate when play/pause state changes
        if (updated.isPaused != oldPaused) {
          _startAdaptivePolling();
        }
      } else {
        // Target session disappeared from server - deactivate
        debugPrint('Helm: Target session disappeared, deactivating');
        deactivateHelm();
      }
    } catch (e) {
      debugPrint('Helm: Failed to refresh target state: $e');
    }
  }

  // ============ Remote Commands ============

  Future<void> helmPlay() async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: target.sessionId,
        command: 'Unpause',
      );
      // Optimistic update
      _activeTarget = target.copyWith(isPaused: false);
      notifyListeners();
      debugPrint('Helm: Sent Unpause to ${target.deviceName}');
    } catch (e) {
      debugPrint('Helm: Play failed: $e');
    }
  }

  Future<void> helmPause() async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: target.sessionId,
        command: 'Pause',
      );
      // Optimistic update
      _activeTarget = target.copyWith(isPaused: true);
      notifyListeners();
      debugPrint('Helm: Sent Pause to ${target.deviceName}');
    } catch (e) {
      debugPrint('Helm: Pause failed: $e');
    }
  }

  Future<void> helmTogglePlayPause() async {
    final target = _activeTarget;
    if (target == null) return;
    if (target.isPaused) {
      await helmPlay();
    } else {
      await helmPause();
    }
  }

  Future<void> helmSeek(Duration position) async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      final ticks = position.inMicroseconds * 10;
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: target.sessionId,
        command: 'Seek',
        seekPositionTicks: ticks,
      );
      debugPrint('Helm: Sent Seek to ${target.deviceName}');
    } catch (e) {
      debugPrint('Helm: Seek failed: $e');
    }
  }

  Future<void> helmNext() async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: target.sessionId,
        command: 'NextTrack',
      );
      debugPrint('Helm: Sent NextTrack to ${target.deviceName}');
    } catch (e) {
      debugPrint('Helm: Next failed: $e');
    }
  }

  Future<void> helmPrevious() async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      await _client.sendPlaystateCommand(
        _credentials,
        sessionId: target.sessionId,
        command: 'PreviousTrack',
      );
      debugPrint('Helm: Sent PreviousTrack to ${target.deviceName}');
    } catch (e) {
      debugPrint('Helm: Previous failed: $e');
    }
  }

  /// Send specific items to play on the remote session.
  Future<void> helmPlayItems(List<String> itemIds, {int? startIndex}) async {
    final target = _activeTarget;
    if (target == null) return;
    try {
      await _client.sendPlayCommand(
        _credentials,
        sessionId: target.sessionId,
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
    super.dispose();
  }
}
