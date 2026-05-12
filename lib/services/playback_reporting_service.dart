import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_track.dart';

class PlaybackReportingService {
  final String serverUrl;
  final String accessToken;
  final http.Client httpClient;

  PlaybackReportingService({
    required this.serverUrl,
    required this.accessToken,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  String? _currentSessionId;
  String _currentPlayMethod = 'DirectPlay';
  Timer? _progressTimer;
  Duration Function()? _positionProvider;
  Duration _progressInterval = const Duration(seconds: 10);
  bool _enabled = true;
  JellyfinTrack? _activeTrack;
  bool _isPaused = false;
  bool _backgroundSuspended = false;

  static const Duration _activeInterval = Duration(seconds: 10);
  static const Duration _pausedInterval = Duration(seconds: 60);

  /// Queued start/stop events recorded while disabled (offline).
  /// Progress events are skipped (redundant — start/stop capture endpoints).
  final List<Map<String, dynamic>> _pendingEvents = [];

  /// Enable or disable reporting. When disabled, start/stop events are queued.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      _progressTimer?.cancel();
    }
  }

  bool get isEnabled => _enabled;

  void setProgressInterval(Duration interval) {
    _progressInterval = interval;
  }

  void attachPositionProvider(Duration Function() provider) {
    _positionProvider = provider;
  }

  Future<void> reportPlaybackStart(
    JellyfinTrack track, {
    String playMethod = 'DirectPlay',
    String? sessionId,
  }) async {
    if (serverUrl.startsWith('demo://')) return;

    _currentSessionId = sessionId ?? DateTime.now().millisecondsSinceEpoch.toString();
    _currentPlayMethod = playMethod;

    if (!_enabled) {
      _pendingEvents.add({
        'type': 'start',
        'trackId': track.id,
        'playMethod': playMethod,
        'sessionId': _currentSessionId,
      });
      debugPrint('📡 Playback start queued (offline): ${track.name}');
      return;
    }

    debugPrint('📡 Reporting to Jellyfin: $serverUrl/Sessions/Playing');
    debugPrint('   Track: ${track.name} (${track.id})');
    debugPrint('   Method: $playMethod');

    final url = Uri.parse('$serverUrl/Sessions/Playing');
    final body = {
      'ItemId': track.id,
      // Use PlaySessionId to match the transcoding session we started
      'PlaySessionId': _currentSessionId,
      'PlayMethod': playMethod,
      'CanSeek': true,
      'IsPaused': false,
      'IsMuted': false,
      'PositionTicks': 0,
      'RepeatMode': 'RepeatNone',
    };

    try {
      final response = await httpClient.post(
        url,
        headers: {
          'X-Emby-Token': accessToken,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('✅ Playback start reported successfully!');
      } else {
        debugPrint('⚠️ Playback start failed: ${response.statusCode} - ${response.body}');
      }

      // Start periodic progress reporting
      _startProgressReporting(track);
    } catch (e) {
      debugPrint('❌ Failed to report playback start: $e');
    }
  }

  void _startProgressReporting(JellyfinTrack track) {
    _activeTrack = track;
    _isPaused = false;
    _restartProgressTimer();
  }

  void _restartProgressTimer() {
    _progressTimer?.cancel();
    final track = _activeTrack;
    if (track == null || _backgroundSuspended) return;
    _progressTimer = Timer.periodic(_progressInterval, (_) {
      final provider = _positionProvider;
      final position = provider != null ? provider() : Duration.zero;
      unawaited(reportPlaybackProgress(track, position, _isPaused));
    });
  }

  /// Notify the reporter that playback paused/resumed. Downshifts the
  /// progress cadence to 60 s while paused, restores 10 s on resume.
  void notifyPaused(bool isPaused) {
    if (_isPaused == isPaused) return;
    _isPaused = isPaused;
    _progressInterval = isPaused ? _pausedInterval : _activeInterval;
    if (_activeTrack != null) {
      _restartProgressTimer();
    }
  }

  /// Cancel the progress timer while the app is backgrounded. Server already
  /// has the most recent progress; resume rearms when the app returns.
  void suspendForBackground() {
    if (_backgroundSuspended) return;
    _backgroundSuspended = true;
    _progressTimer?.cancel();
  }

  /// Re-arm the progress timer if a track is still active.
  void resumeFromBackground() {
    if (!_backgroundSuspended) return;
    _backgroundSuspended = false;
    if (_activeTrack != null) {
      _restartProgressTimer();
    }
  }

  Future<void> reportPlaybackProgress(
    JellyfinTrack track,
    Duration position,
    bool isPaused,
  ) async {
    if (!_enabled) return;
    if (_currentSessionId == null || serverUrl.startsWith('demo://')) return;

    final url = Uri.parse('$serverUrl/Sessions/Playing/Progress');
    final positionTicks = position.inMicroseconds * 10;
    
    final body = {
      'ItemId': track.id,
      'PlaySessionId': _currentSessionId,
      'PositionTicks': positionTicks,
      'IsPaused': isPaused,
      'PlayMethod': _currentPlayMethod,
      'CanSeek': true,
      'RepeatMode': 'RepeatNone',
    };

    try {
      final response = await httpClient.post(
        url,
        headers: {
          'X-Emby-Token': accessToken,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
      
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('✅ Progress reported: ${position.inSeconds}s, paused: $isPaused');
      } else {
        debugPrint('⚠️ Progress report failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Failed to report playback progress: $e');
    }
  }

  Future<void> reportPlaybackStopped(
    JellyfinTrack track,
    Duration position,
  ) async {
    _progressTimer?.cancel();
    _activeTrack = null;
    _isPaused = false;
    _progressInterval = _activeInterval;

    if (_currentSessionId == null || serverUrl.startsWith('demo://')) return;

    if (!_enabled) {
      _pendingEvents.add({
        'type': 'stop',
        'trackId': track.id,
        'positionTicks': position.inMicroseconds * 10,
        'sessionId': _currentSessionId,
      });
      _currentSessionId = null;
      debugPrint('📡 Playback stop queued (offline): ${track.name}');
      return;
    }

    final url = Uri.parse('$serverUrl/Sessions/Playing/Stopped');
    final positionTicks = position.inMicroseconds * 10;
    
    final body = {
      'ItemId': track.id,
      'PlaySessionId': _currentSessionId,
      'PositionTicks': positionTicks,
      'PlayMethod': _currentPlayMethod,
    };

    try {
      await httpClient.post(
        url,
        headers: {
          'X-Emby-Token': accessToken,
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } catch (e) {
      debugPrint('Failed to report playback stopped: $e');
    } finally {
      _currentSessionId = null;
    }
  }

  /// Flush queued start/stop events when coming back online.
  Future<void> flushPendingReports() async {
    if (_pendingEvents.isEmpty) return;

    debugPrint('📡 Flushing ${_pendingEvents.length} pending playback reports...');
    final events = List<Map<String, dynamic>>.from(_pendingEvents);
    _pendingEvents.clear();

    for (final event in events) {
      try {
        if (event['type'] == 'start') {
          final url = Uri.parse('$serverUrl/Sessions/Playing');
          await httpClient.post(
            url,
            headers: {
              'X-Emby-Token': accessToken,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'ItemId': event['trackId'],
              'PlaySessionId': event['sessionId'],
              'PlayMethod': event['playMethod'],
              'CanSeek': true,
              'IsPaused': false,
              'IsMuted': false,
              'PositionTicks': 0,
              'RepeatMode': 'RepeatNone',
            }),
          );
        } else if (event['type'] == 'stop') {
          final url = Uri.parse('$serverUrl/Sessions/Playing/Stopped');
          await httpClient.post(
            url,
            headers: {
              'X-Emby-Token': accessToken,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'ItemId': event['trackId'],
              'PlaySessionId': event['sessionId'],
              'PositionTicks': event['positionTicks'],
              'PlayMethod': 'DirectPlay',
            }),
          );
        }
      } catch (e) {
        debugPrint('📡 Failed to flush event: $e');
      }
    }
    debugPrint('📡 Flush complete');
  }

  void dispose() {
    _progressTimer?.cancel();
  }
}
