import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_auth_header.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/server_uri.dart';

/// One started (and not yet stopped) Jellyfin playback session.
class _ReportSession {
  _ReportSession({
    required this.trackId,
    required this.sessionId,
    required this.playMethod,
  });

  final String trackId;
  final String sessionId;
  final String playMethod;
}

/// Reports playback start/progress/stop to Jellyfin.
///
/// Session bookkeeping is per track: a stop report only ever ends the session
/// it belongs to, so the common `reportPlaybackStopped(previous)` →
/// `reportPlaybackStart(next)` sequence (including gapless transitions and
/// out-of-order completion of the two HTTP calls) can't wipe or leak the new
/// track's session. Duplicate starts for the active track and duplicate stops
/// are no-ops.
class PlaybackReportingService {
  final String serverUrl;
  final String accessToken;

  /// Device id used in the `Authorization` header. Optional for backwards
  /// compatibility; when absent the header carries only the token.
  final String? deviceId;

  /// User the token belongs to; used to decide whether queued offline events
  /// may be carried over to a replacement service.
  final String? userId;
  final http.Client httpClient;

  PlaybackReportingService({
    required this.serverUrl,
    required this.accessToken,
    this.deviceId,
    this.userId,
    http.Client? httpClient,
  }) : httpClient = httpClient ?? http.Client();

  _ReportSession? _current;

  /// Sessions that were replaced by a newer start before their stop report
  /// arrived (e.g. the stop call completed after the next track's start).
  /// Keyed by track id; bounded so it can't grow without limit.
  final Map<String, _ReportSession> _unstopped = {};
  static const int _maxUnstopped = 8;

  Timer? _progressTimer;
  Duration Function()? _positionProvider;
  Duration _progressInterval = const Duration(seconds: 10);
  bool _enabled = true;
  bool _disposed = false;
  bool _retired = false;
  Timer? _retireTimer;
  JellyfinTrack? _activeTrack;
  bool _isPaused = false;
  bool _backgroundSuspended = false;

  static const Duration _activeInterval = Duration(seconds: 10);
  static const Duration _pausedInterval = Duration(seconds: 60);

  /// Queued start/stop events recorded while disabled (offline).
  /// Progress events are skipped (redundant — start/stop capture endpoints).
  final List<Map<String, dynamic>> _pendingEvents = [];

  bool get _isDemo => serverUrl.startsWith('demo://');

  /// Whether this service reports for the same server + user as [other]
  /// (queued events and the active session may be carried over).
  bool isSameAccountAs(PlaybackReportingService other) =>
      !other._retired &&
      !other._disposed &&
      serverUrl == other.serverUrl &&
      userId != null &&
      userId == other.userId;

  /// Whether this service would behave identically to one built with these
  /// parameters (so it can simply be kept instead of replaced).
  bool matches({
    required String serverUrl,
    required String accessToken,
    String? deviceId,
    String? userId,
  }) =>
      !_disposed &&
      !_retired &&
      this.serverUrl == serverUrl &&
      this.accessToken == accessToken &&
      this.deviceId == deviceId &&
      this.userId == userId;

  /// Move queued offline events, the active session and progress state from
  /// [previous] into this service. Call before disposing [previous].
  void adoptStateFrom(PlaybackReportingService previous) {
    if (identical(previous, this) || previous._retired || previous._disposed) {
      return;
    }
    _pendingEvents.addAll(previous._pendingEvents);
    previous._pendingEvents.clear();
    _unstopped.addAll(previous._unstopped);
    previous._unstopped.clear();
    _current ??= previous._current;
    previous._current = null;
    _activeTrack ??= previous._activeTrack;
    _isPaused = previous._isPaused;
    _progressInterval = previous._progressInterval;
    _backgroundSuspended = previous._backgroundSuspended;
    _positionProvider ??= previous._positionProvider;
    if (_activeTrack != null && _current != null && _enabled) {
      _restartProgressTimer();
    }
  }

  Map<String, String> _headers() {
    final id = deviceId;
    final auth = id != null
        ? nautuneAuthorization(deviceId: id, token: accessToken)
        : buildJellyfinAuthorization(
            client: kJellyfinClientName,
            device: '', // omitted
            deviceId: '', // omitted; server falls back to the token's device
            version: '', // omitted
            token: accessToken,
          );
    return {
      kJellyfinAuthorizationHeader: auth,
      'Content-Type': 'application/json',
    };
  }

  Uri _uri(String path) => buildServerUri(serverUrl, path);

  /// Enable or disable reporting. When disabled, start/stop events are queued.
  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      _progressTimer?.cancel();
      _progressTimer = null;
    } else if (_activeTrack != null && _current != null) {
      _restartProgressTimer();
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
    if (_disposed || _retired || _isDemo) return;

    final existing = _current;
    if (existing != null &&
        existing.trackId == track.id &&
        (sessionId == null || sessionId == existing.sessionId)) {
      // Duplicate start for the track that's already being reported.
      _activeTrack = track;
      if (_enabled && _progressTimer == null) _restartProgressTimer();
      return;
    }
    if (existing != null) {
      // Caller started a new track without stopping the previous one (or the
      // stop is still in flight). Keep it so a late stop can still end it.
      _unstopped[existing.trackId] = existing;
      while (_unstopped.length > _maxUnstopped) {
        _unstopped.remove(_unstopped.keys.first);
      }
    }

    final session = _ReportSession(
      trackId: track.id,
      sessionId: sessionId ?? DateTime.now().microsecondsSinceEpoch.toString(),
      playMethod: playMethod,
    );
    _current = session;
    _activeTrack = track;
    _isPaused = false;
    _progressTimer?.cancel();
    _progressTimer = null;

    if (!_enabled) {
      _pendingEvents.add({
        'type': 'start',
        'trackId': track.id,
        'playMethod': playMethod,
        'sessionId': session.sessionId,
      });
      debugPrint('📡 Playback start queued (offline): ${track.name}');
      return;
    }

    debugPrint('📡 Reporting playback start: ${track.name} (${track.id}) [$playMethod]');

    try {
      final response = await httpClient.post(
        _uri('/Sessions/Playing'),
        headers: _headers(),
        body: jsonEncode({
          'ItemId': track.id,
          // Use PlaySessionId to match the transcoding session we started
          'PlaySessionId': session.sessionId,
          'PlayMethod': playMethod,
          'CanSeek': true,
          'IsPaused': false,
          'IsMuted': false,
          'PositionTicks': 0,
          'RepeatMode': 'RepeatNone',
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('✅ Playback start reported successfully!');
      } else {
        debugPrint('⚠️ Playback start failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Failed to report playback start: $e');
    }

    // Only arm progress reporting if this is still the active session (a stop
    // or another start may have happened while the request was in flight).
    if (identical(_current, session) && !_disposed && _enabled) {
      _restartProgressTimer();
    }
  }

  void _restartProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
    final track = _activeTrack;
    final session = _current;
    if (track == null ||
        session == null ||
        _backgroundSuspended ||
        _disposed ||
        _retired) {
      return;
    }
    _progressTimer = Timer.periodic(_progressInterval, (timer) {
      if (!identical(_current, session) || _disposed) {
        timer.cancel();
        return;
      }
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
    if (_activeTrack != null && _enabled) {
      _restartProgressTimer();
    }
  }

  /// Cancel the progress timer while the app is backgrounded. Server already
  /// has the most recent progress; resume rearms when the app returns.
  void suspendForBackground() {
    if (_backgroundSuspended) return;
    _backgroundSuspended = true;
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// Re-arm the progress timer if a track is still active.
  void resumeFromBackground() {
    if (!_backgroundSuspended) return;
    _backgroundSuspended = false;
    if (_activeTrack != null && _enabled) {
      _restartProgressTimer();
    }
  }

  Future<void> reportPlaybackProgress(
    JellyfinTrack track,
    Duration position,
    bool isPaused,
  ) async {
    if (!_enabled || _disposed || _retired || _isDemo) return;
    final session = _current;
    // Only report progress for the track whose session is active.
    if (session == null || session.trackId != track.id) return;

    final positionTicks = position.inMicroseconds * 10;

    try {
      final response = await httpClient.post(
        _uri('/Sessions/Playing/Progress'),
        headers: _headers(),
        body: jsonEncode({
          'ItemId': track.id,
          'PlaySessionId': session.sessionId,
          'PositionTicks': positionTicks,
          'IsPaused': isPaused,
          'PlayMethod': session.playMethod,
          'CanSeek': true,
          'RepeatMode': 'RepeatNone',
        }),
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
    if (_disposed || _isDemo) return;

    final _ReportSession? session;
    final current = _current;
    if (current != null && current.trackId == track.id) {
      session = current;
      _current = null;
      _progressTimer?.cancel();
      _progressTimer = null;
      _activeTrack = null;
      _isPaused = false;
      _progressInterval = _activeInterval;
    } else {
      // Either a late stop for a session already replaced by a newer start
      // (don't touch the new session's state), or a duplicate stop.
      session = _unstopped.remove(track.id);
    }
    if (session == null) return;

    final positionTicks = position.inMicroseconds * 10;

    if (!_enabled) {
      if (_retired) return; // Logged out: don't queue for later.
      _pendingEvents.add({
        'type': 'stop',
        'trackId': track.id,
        'positionTicks': positionTicks,
        'sessionId': session.sessionId,
        'playMethod': session.playMethod,
      });
      debugPrint('📡 Playback stop queued (offline): ${track.name}');
      return;
    }

    try {
      await httpClient.post(
        _uri('/Sessions/Playing/Stopped'),
        headers: _headers(),
        body: jsonEncode({
          'ItemId': track.id,
          'PlaySessionId': session.sessionId,
          'PositionTicks': positionTicks,
          'PlayMethod': session.playMethod,
        }),
      );
    } catch (e) {
      debugPrint('Failed to report playback stopped: $e');
    }
  }

  /// Flush queued start/stop events when coming back online.
  Future<void> flushPendingReports() async {
    if (_pendingEvents.isEmpty || _disposed) return;

    debugPrint('📡 Flushing ${_pendingEvents.length} pending playback reports...');
    final events = List<Map<String, dynamic>>.from(_pendingEvents);
    _pendingEvents.clear();

    for (final event in events) {
      try {
        if (event['type'] == 'start') {
          await httpClient.post(
            _uri('/Sessions/Playing'),
            headers: _headers(),
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
          await httpClient.post(
            _uri('/Sessions/Playing/Stopped'),
            headers: _headers(),
            body: jsonEncode({
              'ItemId': event['trackId'],
              'PlaySessionId': event['sessionId'],
              'PositionTicks': event['positionTicks'],
              'PlayMethod': event['playMethod'] ?? 'DirectPlay',
            }),
          );
        }
      } catch (e) {
        debugPrint('📡 Failed to flush event: $e');
      }
    }
    debugPrint('📡 Flush complete');
  }

  /// Drop queued offline events (e.g. on logout, so they aren't sent later
  /// under another account).
  void clearPendingEvents() {
    _pendingEvents.clear();
  }

  /// Logout: stop accepting new sessions/progress and drop queued offline
  /// events, but still let the stop report for the ending session go out —
  /// the audio service may deliver it asynchronously after logout starts.
  /// Disposes itself after [grace].
  void retire({Duration grace = const Duration(seconds: 20)}) {
    if (_disposed || _retired) return;
    _retired = true;
    _pendingEvents.clear();
    _progressTimer?.cancel();
    _progressTimer = null;
    _retireTimer = Timer(grace, dispose);
  }

  bool get isRetired => _retired;

  /// Stops all timers and makes every further call a no-op. Idempotent.
  void dispose() {
    _disposed = true;
    _retireTimer?.cancel();
    _retireTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    _activeTrack = null;
    _current = null;
    _unstopped.clear();
  }
}
