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

  /// Initialize the system tray if on a supported desktop platform.
  Future<void> initialize() async {
    if (!_isDesktopPlatform) {
      debugPrint('🔲 TrayService: Not a desktop platform, skipping');
      return;
    }

    try {
      // Set tray icon
      await trayManager.setIcon(_getTrayIconPath());

      // Set initial tooltip
      await trayManager.setToolTip('Nautune - Not Playing');

      // Create context menu
      await _updateContextMenu();

      // Listen for tray events
      trayManager.addListener(this);

      _isInitialized = true;
      debugPrint('🔲 TrayService: Initialized');
    } catch (e) {
      debugPrint('🔲 TrayService: Failed to initialize: $e');
    }
  }

  /// Update tray with current track info.
  void updateCurrentTrack(JellyfinTrack? track) {
    if (!_isInitialized) return;

    if (track != null) {
      final tooltip = '${track.name}\n${track.displayArtist}';
      trayManager.setToolTip(tooltip);
    } else {
      trayManager.setToolTip('Nautune - Not Playing');
    }

    _updateContextMenu();
  }

  /// Update tray playing state.
  void updatePlayingState(bool isPlaying) {
    if (!_isInitialized) return;
    _updateContextMenu();
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
          label: 'Show Nautune',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: 'Quit',
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayIconMouseDown() {
    // Show context menu on click
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Also show context menu on right click
    trayManager.popUpContextMenu();
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
        // This would need window_manager to actually show the window
        // For now, we just log it
        debugPrint('🔲 TrayService: Show window requested');
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
    if (_isInitialized) {
      trayManager.removeListener(this);
      await trayManager.destroy();
      _isInitialized = false;
    }
  }
}
