import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../jellyfin/jellyfin_track.dart';
import 'audio_player_service.dart';

/// System tray service for desktop platforms (Linux, Windows, macOS).
/// Provides background playback controls and current track info.
class TrayService with TrayListener {
  TrayService({required AudioPlayerService audioService})
      : _audioService = audioService;

  final AudioPlayerService _audioService;
  bool _isInitialized = false;
  final StreamController<String> _actionController = StreamController.broadcast();

  Stream<String> get actionStream => _actionController.stream;

  /// Initialize the system tray if on a supported desktop platform.
  Future<void> initialize() async {
    if (!_isDesktopPlatform) {
      debugPrint('🔲 TrayService: Not a desktop platform, skipping');
      return;
    }

    try {
      // Listen for tray events immediately
      trayManager.addListener(this);

      // Set tray icon
      try {
        await trayManager.setIcon(_getTrayIconPath());
      } catch (e) {
        debugPrint('🔲 TrayService: Failed to set icon: $e');
      }

      // Set initial tooltip (ignore errors on Linux)
      try {
        await trayManager.setToolTip('Nautune - Not Playing');
      } catch (e) {
        // Ignored, likely not supported on this platform version
      }

      // Create context menu
      await _updateContextMenu();

      _isInitialized = true;
      debugPrint('🔲 TrayService: Initialized');
    } catch (e) {
      debugPrint('🔲 TrayService: Failed to initialize: $e');
    }
  }

  /// Update tray with current track info.
  Future<void> updateCurrentTrack(JellyfinTrack? track) async {
    if (!_isInitialized) return;

    try {
      if (track != null) {
        final tooltip = '${track.name}\n${track.displayArtist}';
        await trayManager.setToolTip(tooltip);
      } else {
        await trayManager.setToolTip('Nautune - Not Playing');
      }
    } catch (e) {
      // Ignore MissingPluginException on Linux if tray not fully supported
    }

    await _updateContextMenu();
  }

  /// Update playing state.
  Future<void> updatePlayingState(bool isPlaying) async {
    if (!_isInitialized) return;
    await _updateContextMenu();
  }

  Future<void> _updateContextMenu() async {
    final currentTrack = _audioService.currentTrack;
    final isPlaying = _audioService.isPlaying;

    final menu = Menu(
      items: [
        if (currentTrack != null) ...[
          MenuItem(
            label: currentTrack.name,
            disabled: true,
          ),
          MenuItem(
            label: currentTrack.displayArtist,
            disabled: true,
          ),
          MenuItem.separator(),
        ],
        MenuItem(
          key: 'play_pause',
          label: isPlaying ? 'Pause' : 'Play',
        ),
        MenuItem(
          key: 'previous',
          label: 'Previous',
        ),
        MenuItem(
          key: 'next',
          label: 'Next',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'show',
          label: 'Show / Hide',
        ),
        MenuItem(
          key: 'settings',
          label: 'Settings',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit',
        ),
      ],
    );

    try {
      await trayManager.setContextMenu(menu);
    } catch (e) {
      debugPrint('🔲 TrayService: Failed to set context menu: $e');
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Show context menu on click
    try {
      trayManager.popUpContextMenu();
    } catch (e) {
      debugPrint('🔲 TrayService: Failed to pop up context menu: $e');
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    // Also show context menu on right click
    try {
      trayManager.popUpContextMenu();
    } catch (e) {
      debugPrint('🔲 TrayService: Failed to pop up context menu: $e');
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'play_pause':
        if (_audioService.isPlaying) {
          _audioService.pause();
        } else {
          _audioService.resume();
        }
        break;
      case 'previous':
        _audioService.skipToPrevious();
        break;
      case 'next':
        _audioService.skipToNext();
        break;
      case 'show':
        _actionController.add('show');
        debugPrint('🔲 TrayService: Show window requested');
        break;
      case 'settings':
        _actionController.add('settings');
        break;
      case 'quit':
        // Exit the app
        exit(0);
      default:
        break;
    }
  }

  String _getTrayIconPath() {
    // Use the app icon for tray
    if (Platform.isWindows) {
      return 'assets/icon.ico';
    } else if (Platform.isMacOS) {
      return 'assets/icon.png';
    } else {
      // Linux
      return 'assets/icon.png';
    }
  }

  bool get _isDesktopPlatform {
    return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  }

  /// Clean up tray resources.
  Future<void> dispose() async {
    _actionController.close();
    if (_isInitialized) {
      trayManager.removeListener(this);
      await trayManager.destroy();
      _isInitialized = false;
    }
  }
}
