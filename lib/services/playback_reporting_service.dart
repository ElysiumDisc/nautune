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
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(_progressInterval, (_) {
      final provider = _positionProvider;
      final position = provider != null ? provider() : Duration.zero;
      unawaited(reportPlaybackProgress(track, position, false));
    });
  }

  Future<void> reportPlaybackProgress(
    JellyfinTrack track,
    Duration position,
    bool isPaused,
  ) async {
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
    
    if (_currentSessionId == null || serverUrl.startsWith('demo://')) return;

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

  void dispose() {
    _progressTimer?.cancel();
  }
}
