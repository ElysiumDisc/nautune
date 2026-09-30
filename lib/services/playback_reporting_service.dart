import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../jellyfin/jellyfin_auth_header.dart';
import '../jellyfin/jellyfin_track.dart';
import '../jellyfin/server_uri.dart';
import 'pending_report_store.dart';

/// Result of sending one playback report.
enum ReportOutcome { delivered, retryLater, drop }

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

  /// Persists queued offline events; null keeps them in memory only.
  final PendingReportStore? pendingStore;

  PlaybackReportingService({
    required this.serverUrl,
    required this.accessToken,
    this.deviceId,
    this.userId,
    http.Client? httpClient,
    this.pendingStore,
  }) : httpClient = httpClient ?? http.Client() {
    _pendingLoaded = _loadPersistedEvents();
  }

  _ReportSession? _current;

  /// Sessions that were replaced by a newer start before their stop report
  /// arrived (e.g. the stop call completed after the next track's start).
  /// Keyed by track id; bounded so it can't grow without limit.
  final Map<String, _ReportSession> _unstopped = {};

  /// Start reports still in flight, by play session id. A stop for the same
  /// session waits for its start, so a start that fails and gets queued can
  /// never be delivered after its own stop.
  final Map<String, Future<void>> _startsInFlight = {};
  static const int _maxUnstopped = 8;

  Timer? _progressTimer;
  Duration Function()? _positionProvider;
  /// Base cadence while playing in the foreground (60 s in battery saver).
  Duration _baseInterval = _activeInterval;
  bool _enabled = true;
  bool _disposed = false;
  bool _retired = false;
  Timer? _retireTimer;
  JellyfinTrack? _activeTrack;
  bool _isPaused = false;
  bool _inBackground = false;

  static const Duration _activeInterval = Duration(seconds: 10);
  static const Duration _pausedInterval = Duration(seconds: 60);
  static const Duration _backgroundInterval = Duration(seconds: 30);

  /// Progress-report cadence for the given state, or null when no progress
  /// should be sent. Locked-screen listening keeps reporting (throttled) so the
  /// server's resume position stays current; a paused, backgrounded app is
  /// silent because the server already has the paused position.
  @visibleForTesting
  static Duration? progressIntervalFor({
    required Duration base,
    required bool paused,
    required bool backgrounded,
  }) {
    if (backgrounded && paused) return null;
    var interval = base;
    if (paused && interval < _pausedInterval) interval = _pausedInterval;
    if (backgrounded && interval < _backgroundInterval) {
      interval = _backgroundInterval;
    }
    return interval;
  }

  /// Queued start/stop events recorded while disabled (offline).
  /// Progress events are skipped (redundant — start/stop capture endpoints).
  final List<Map<String, dynamic>> _pendingEvents = [];

  /// Oldest events are dropped beyond this many (a long offline stretch).
  static const int maxPendingEvents = 500;

  late final Future<void> _pendingLoaded;

  String get _accountKey => '$serverUrl|${userId ?? ''}';

  Future<void> _loadPersistedEvents() async {
    final store = pendingStore;
    if (store == null || _isDemo) return;
    final stored = await store.load(_accountKey);
    if (stored.isEmpty || _disposed || _retired) return;
    final merged = [...stored];
    for (final event in _pendingEvents) {
      if (!merged.any((e) => _sameEvent(e, event))) merged.add(event);
    }
    _pendingEvents
      ..clear()
      ..addAll(merged);
    _trimPending();
  }

  static bool _sameEvent(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['type'] == b['type'] && a['sessionId'] == b['sessionId'];

  void _trimPending() {
    final excess = _pendingEvents.length - maxPendingEvents;
    if (excess > 0) _pendingEvents.removeRange(0, excess);
  }

  void _queueEvent(Map<String, dynamic> event) {
    if (_pendingEvents.any((e) => _sameEvent(e, event))) return;
    _pendingEvents.add(event);
    _trimPending();
    _persistPending();
  }

  void _persistPending() {
    final store = pendingStore;
    if (store == null || _isDemo) return;
    unawaited(store.save(_accountKey, List.of(_pendingEvents)));
  }

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
    for (final event in previous._pendingEvents) {
      if (!_pendingEvents.any((e) => _sameEvent(e, event))) {
        _pendingEvents.add(event);
      }
    }
    _trimPending();
    previous._pendingEvents.clear();
    _persistPending();
    _unstopped.addAll(previous._unstopped);
    previous._unstopped.clear();
    _current ??= previous._current;
    previous._current = null;
    _activeTrack ??= previous._activeTrack;
    _isPaused = previous._isPaused;
    _baseInterval = previous._baseInterval;
    _inBackground = previous._inBackground;
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

  /// Per-request timeout. Reports are fire-and-forget but awaited (e.g. the
  /// sequential offline flush); without a timeout a stalled server would
  /// block them indefinitely.
  static const Duration _requestTimeout = Duration(seconds: 15);

  Future<http.Response> _post(String path, Map<String, dynamic> body) {
    return httpClient
        .post(_uri(path), headers: _headers(), body: jsonEncode(body))
        .timeout(_requestTimeout);
  }

  /// `PlaybackStartInfo` / `PlaybackProgressInfo` body. For audio items the
  /// media source id is the item id.
  static Map<String, dynamic> startBody({
    required String itemId,
    required String playSessionId,
    required String playMethod,
  }) =>
      {
        'ItemId': itemId,
        'MediaSourceId': itemId,
        // Matches the PlaySessionId on transcoded stream URLs so the server
        // can kill the ffmpeg job on stop.
        'PlaySessionId': playSessionId,
        'PlayMethod': playMethod,
        'CanSeek': true,
        'IsPaused': false,
        'IsMuted': false,
        'PositionTicks': 0,
        'RepeatMode': 'RepeatNone',
      };

  /// `PlaybackStopInfo` body (has no PlayMethod/IsPaused fields).
  static Map<String, dynamic> stopBody({
    required String itemId,
    required String playSessionId,
    required int positionTicks,
  }) =>
      {
        'ItemId': itemId,
        'MediaSourceId': itemId,
        'PlaySessionId': playSessionId,
        'PositionTicks': positionTicks,
      };

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
    _baseInterval = interval;
    if (_activeTrack != null && _current != null && _enabled) {
      _restartProgressTimer();
    }
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
      _queueEvent({
        'type': 'start',
        'trackId': track.id,
        'playMethod': playMethod,
        'sessionId': session.sessionId,
      });
      debugPrint('📡 Playback start queued (offline): ${track.name}');
      return;
    }

    debugPrint('📡 Reporting playback start: ${track.name} (${track.id}) [$playMethod]');

    final startEvent = {
      'type': 'start',
      'trackId': track.id,
      'playMethod': playMethod,
      'sessionId': session.sessionId,
    };
    final startDone = Completer<void>();
    _startsInFlight[session.sessionId] = startDone.future;
    try {
      final outcome = await _send(startEvent);
      if (outcome == ReportOutcome.retryLater && !_retired && !_disposed) {
        // Transient failure (network drop, 5xx): keep it so the play is still
        // counted; the matching stop is queued behind it.
        _queueEvent(startEvent);
        debugPrint('📡 Playback start failed, queued for retry');
      } else if (outcome == ReportOutcome.delivered) {
        _flushIfPending();
      }
    } finally {
      // Settled (delivered, dropped or queued): release a waiting stop.
      _startsInFlight.remove(session.sessionId);
      startDone.complete();
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
    final interval = progressIntervalFor(
      base: _baseInterval,
      paused: _isPaused,
      backgrounded: _inBackground,
    );
    if (track == null ||
        session == null ||
        interval == null ||
        _disposed ||
        _retired) {
      return;
    }
    _progressTimer = Timer.periodic(interval, (timer) {
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
  /// progress cadence while paused (see [progressIntervalFor]).
  void notifyPaused(bool isPaused) {
    if (_isPaused == isPaused) return;
    _isPaused = isPaused;
    if (_activeTrack != null && _enabled) {
      _restartProgressTimer();
    }
  }

  /// The app went to the background. Progress keeps flowing at a throttled
  /// cadence while audio plays (locked-screen listening is the common case),
  /// and stops entirely while paused.
  void suspendForBackground() {
    if (_inBackground) return;
    _inBackground = true;
    if (_activeTrack != null && _enabled) {
      _restartProgressTimer();
    }
  }

  /// Restore the foreground cadence if a track is still active.
  void resumeFromBackground() {
    if (!_inBackground) return;
    _inBackground = false;
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
      final response = await _post('/Sessions/Playing/Progress', {
        ...startBody(
          itemId: track.id,
          playSessionId: session.sessionId,
          playMethod: session.playMethod,
        ),
        'PositionTicks': positionTicks,
        'IsPaused': isPaused,
      });

      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('✅ Progress reported: ${position.inSeconds}s, paused: $isPaused');
        // The server is reachable again: deliver anything a transient
        // failure left queued.
        _flushIfPending();
      } else {
        debugPrint('⚠️ Progress report failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Failed to report playback progress: ${e.runtimeType}');
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
    } else {
      // Either a late stop for a session already replaced by a newer start
      // (don't touch the new session's state), or a duplicate stop.
      session = _unstopped.remove(track.id);
    }
    if (session == null) return;

    final positionTicks = position.inMicroseconds * 10;

    final stopEvent = {
      'type': 'stop',
      'trackId': track.id,
      'positionTicks': positionTicks,
      'sessionId': session.sessionId,
      'playMethod': session.playMethod,
    };

    // Let this session's start settle first (it may end up queued).
    final sessionId = session.sessionId;
    final startInFlight = _startsInFlight[sessionId];
    if (startInFlight != null) {
      await startInFlight;
      if (_disposed) return;
    }

    // Offline, or this session's start is still queued: the stop must go
    // out after it, so queue it too.
    final startPending = _pendingEvents.any(
      (e) => e['type'] == 'start' && e['sessionId'] == sessionId,
    );
    if (!_enabled || startPending) {
      if (_retired) return; // Logged out: don't queue for later.
      _queueEvent(stopEvent);
      debugPrint('📡 Playback stop queued: ${track.name}');
      if (_enabled) _flushIfPending();
      return;
    }

    final outcome = await _send(stopEvent);
    if (outcome == ReportOutcome.retryLater && !_retired && !_disposed) {
      _queueEvent(stopEvent);
      debugPrint('📡 Playback stop failed, queued for retry');
    } else if (outcome == ReportOutcome.delivered) {
      _flushIfPending();
    }
  }

  /// Classifies a report response: 2xx delivered; network errors, 5xx and
  /// 401/408/429 are worth retrying later; other 4xx are permanent (the
  /// event is malformed or the item is gone) and are dropped.
  @visibleForTesting
  static ReportOutcome outcomeForStatus(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return ReportOutcome.delivered;
    if (statusCode >= 500 ||
        statusCode == 401 ||
        statusCode == 408 ||
        statusCode == 429) {
      return ReportOutcome.retryLater;
    }
    return ReportOutcome.drop;
  }

  /// Sends one queued-format start/stop event.
  Future<ReportOutcome> _send(Map<String, dynamic> event) async {
    final trackId = event['trackId'];
    final sessionId = event['sessionId'];
    if (trackId is! String || sessionId is! String) return ReportOutcome.drop;
    try {
      final http.Response response;
      if (event['type'] == 'start') {
        response = await _post(
          '/Sessions/Playing',
          startBody(
            itemId: trackId,
            playSessionId: sessionId,
            playMethod: event['playMethod'] as String? ?? 'DirectPlay',
          ),
        );
      } else if (event['type'] == 'stop') {
        final ticks = event['positionTicks'];
        response = await _post(
          '/Sessions/Playing/Stopped',
          stopBody(
            itemId: trackId,
            playSessionId: sessionId,
            positionTicks: ticks is num ? ticks.toInt() : 0,
          ),
        );
      } else {
        return ReportOutcome.drop;
      }
      final outcome = outcomeForStatus(response.statusCode);
      if (outcome != ReportOutcome.delivered) {
        debugPrint('📡 ${event['type']} report: HTTP ${response.statusCode}');
      }
      return outcome;
    } catch (e) {
      debugPrint('📡 ${event['type']} report failed: ${e.runtimeType}');
      return ReportOutcome.retryLater;
    }
  }

  void _flushIfPending() {
    if (_pendingEvents.isNotEmpty && _enabled && !_disposed && !_retired) {
      unawaited(flushPendingReports());
    }
  }

  Future<void>? _flushing;

  /// Flush queued start/stop events when coming back online. Single-flight.
  ///
  /// Events are sent oldest first and each is removed (and the queue
  /// re-persisted) only once the server accepted it or rejected it
  /// permanently; on a transient failure the flush stops and the remaining
  /// events stay queued for the next attempt.
  Future<void> flushPendingReports() =>
      _flushing ??= _flush().whenComplete(() => _flushing = null);

  Future<void> _flush() async {
    await _pendingLoaded;
    if (_pendingEvents.isEmpty || _disposed || _retired) return;

    debugPrint('📡 Flushing ${_pendingEvents.length} pending playback reports...');
    var sent = 0;
    while (_pendingEvents.isNotEmpty && _enabled && !_disposed && !_retired) {
      final event = _pendingEvents.first;
      final outcome = await _send(event);
      if (outcome == ReportOutcome.retryLater) {
        debugPrint('📡 Flush paused: ${_pendingEvents.length} still queued');
        return;
      }
      // Identity removal: the queue may have been trimmed meanwhile.
      _pendingEvents.remove(event);
      _persistPending();
      sent++;
    }
    debugPrint('📡 Flush complete ($sent sent)');
  }

  /// Drop queued offline events (e.g. on logout, so they aren't sent later
  /// under another account).
  void clearPendingEvents() {
    _pendingEvents.clear();
    _persistPending();
  }

  /// Logout: stop accepting new sessions/progress and drop queued offline
  /// events, but still let the stop report for the ending session go out —
  /// the audio service may deliver it asynchronously after logout starts.
  /// Disposes itself after [grace].
  void retire({Duration grace = const Duration(seconds: 20)}) {
    if (_disposed || _retired) return;
    _retired = true;
    _pendingEvents.clear();
    _persistPending();
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
