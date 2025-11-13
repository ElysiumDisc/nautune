import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NautuneCarplay {
  static const MethodChannel _channel = MethodChannel('nautune_carplay');

  /// Initialize CarPlay with the app's configuration
  static Future<void> initialize() async {
    try {
      await _channel.invokeMethod('initialize');
    } on PlatformException catch (e) {
      debugPrint('Failed to initialize CarPlay: ${e.message}');
    }
  }

  /// Update the now playing info
  static Future<void> updateNowPlaying({
    required String trackId,
    required String title,
    required String artist,
    required String? album,
    required Duration duration,
    required Duration position,
    String? artworkUrl,
  }) async {
    try {
      await _channel.invokeMethod('updateNowPlaying', {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration.inSeconds,
        'position': position.inSeconds,
        'artworkUrl': artworkUrl,
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to update now playing: ${e.message}');
    }
  }

  /// Set playback state
  static Future<void> setPlaybackState({required bool isPlaying}) async {
    try {
      await _channel.invokeMethod('setPlaybackState', {
        'isPlaying': isPlaying,
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to set playback state: ${e.message}');
    }
  }

  /// Update the library/browse content
  static Future<void> updateLibraryContent(List<Map<String, dynamic>> items) async {
    try {
      await _channel.invokeMethod('updateLibraryContent', {
        'items': items,
      });
    } on PlatformException catch (e) {
      debugPrint('Failed to update library: ${e.message}');
    }
  }

  /// Handle CarPlay commands callback
  static void setCommandHandler(Function(String command, Map<String, dynamic>? args) handler) {
    _channel.setMethodCallHandler((call) async {
      handler(call.method, call.arguments as Map<String, dynamic>?);
    });
  }
}
