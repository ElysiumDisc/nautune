import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
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
  Timer? _progressTimer;
  Duration Function()? _positionProvider;

  void attachPositionProvider(Duration Function() provider) {
    _positionProvider = provider;
  }

  Future<void> reportPlaybackStart(
    JellyfinTrack track, {
    String playMethod = 'DirectPlay',
  }) async {
    _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    
    print('📡 Reporting to Jellyfin: $serverUrl/Sessions/Playing');
    print('   Track: ${track.name} (${track.id})');
    print('   Method: $playMethod');
    
    final url = Uri.parse('$serverUrl/Sessions/Playing');
    final body = {
      'ItemId': track.id,
      'SessionId': _currentSessionId,
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
        print('✅ Playback start reported successfully!');
      } else {
        print('⚠️ Playback start failed: ${response.statusCode} - ${response.body}');
      }

      // Start periodic progress reporting
      _startProgressReporting(track);
    } catch (e) {
      print('❌ Failed to report playback start: $e');
    }
  }

  void _startProgressReporting(JellyfinTrack track) {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
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
    if (_currentSessionId == null) return;

    final url = Uri.parse('$serverUrl/Sessions/Playing/Progress');
    final positionTicks = position.inMicroseconds * 10;
    
    final body = {
      'ItemId': track.id,
      'SessionId': _currentSessionId,
      'PositionTicks': positionTicks,
      'IsPaused': isPaused,
      'PlayMethod': 'DirectPlay',
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
        print('✅ Progress reported: ${position.inSeconds}s, paused: $isPaused');
      } else {
        print('⚠️ Progress report failed: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Failed to report playback progress: $e');
    }
  }

  Future<void> reportPlaybackStopped(
    JellyfinTrack track,
    Duration position,
  ) async {
    _progressTimer?.cancel();
    
    if (_currentSessionId == null) return;

    final url = Uri.parse('$serverUrl/Sessions/Playing/Stopped');
    final positionTicks = position.inMicroseconds * 10;
    
    final body = {
      'ItemId': track.id,
      'SessionId': _currentSessionId,
      'PositionTicks': positionTicks,
      'PlayMethod': 'DirectPlay',
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
      print('Failed to report playback stopped: $e');
    } finally {
      _currentSessionId = null;
    }
  }

  void dispose() {
    _progressTimer?.cancel();
  }
}
