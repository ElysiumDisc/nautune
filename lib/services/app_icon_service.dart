import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

class AppIconService extends ChangeNotifier {
  static const MethodChannel _iosChannel = MethodChannel('com.nautune.app_icon/methods');
  static final AppIconService _instance = AppIconService._internal();
  factory AppIconService() => _instance;
  AppIconService._internal();

  static const String _boxName = 'nautune_app_icon';
  static const String _selectedIconKey = 'selected_icon';

  static const List<String> supportedIcons = ['default', 'orange'];

  String _currentIcon = 'default';

  String get currentIcon => _currentIcon;

  /// Returns the Flutter asset path for the current icon
  String get iconAssetPath {
    switch (_currentIcon) {
      case 'orange':
        return 'assets/iconorange.png';
      case 'default':
      default:
        return 'assets/icon.png';
    }
  }

  /// Returns the path for tray icon (same as main icon for now)
  String get trayIconPath {
    switch (_currentIcon) {
      case 'orange':
        return 'assets/iconorange.png';
      case 'default':
      default:
        return 'assets/icon.png';
    }
  }

  /// Display name for UI
  String get iconDisplayName {
    switch (_currentIcon) {
      case 'orange':
        return 'Sunset';
      case 'default':
      default:
        return 'Classic';
    }
  }

  Future<void> initialize() async {
    final box = await Hive.openBox<String>(_boxName);
    final savedIcon = box.get(_selectedIconKey);
    debugPrint('🎨 AppIconService: Loaded saved icon: $savedIcon');
    if (savedIcon != null && supportedIcons.contains(savedIcon)) {
      _currentIcon = savedIcon;
      debugPrint('🎨 AppIconService: Set current icon to: $_currentIcon');
    }
    notifyListeners();
  }

  Future<void> setIcon(String iconName) async {
    if (!supportedIcons.contains(iconName)) {
      throw ArgumentError('Unsupported icon: $iconName. Supported icons: $supportedIcons');
    }
    if (_currentIcon == iconName) return;

    // Update iOS alternate icon if on iOS
    if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('setIcon', {'iconName': iconName});
      } catch (e) {
        debugPrint('🎨 AppIconService: Failed to set iOS icon: $e');
        // Continue anyway to update local state
      }
    }

    _currentIcon = iconName;
    final box = await Hive.openBox<String>(_boxName);
    await box.put(_selectedIconKey, iconName);
    debugPrint('🎨 AppIconService: Saved icon preference: $iconName');
    notifyListeners();
  }

  /// Sync iOS icon with stored preference on app launch
  Future<void> syncIOSIcon() async {
    if (!Platform.isIOS) return;
    try {
      final currentIOSIcon = await _iosChannel.invokeMethod<String>('getCurrentIcon');
      if (currentIOSIcon != _currentIcon) {
        await _iosChannel.invokeMethod('setIcon', {'iconName': _currentIcon});
      }
    } catch (e) {
      debugPrint('🎨 AppIconService: Failed to sync iOS icon: $e');
    }
  }
}
