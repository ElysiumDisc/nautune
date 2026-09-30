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

  static const List<String> supportedIcons = ['default', 'orange', 'red', 'green'];

  String _currentIcon = 'default';

  String get currentIcon => _currentIcon;

  /// Returns the Flutter asset path for the current icon
  String get iconAssetPath {
    switch (_currentIcon) {
      case 'orange':
        return 'assets/iconorange.png';
      case 'red':
        return 'assets/iconred.png';
      case 'green':
        return 'assets/icongreen.png';
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
      case 'red':
        return 'Crimson';
      case 'green':
        return 'Emerald';
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

  /// Switches the icon. On iOS the preference only changes once the system
  /// accepted the new icon, so the stored choice never disagrees with the
  /// home screen. Returns false if the icon couldn't be changed.
  Future<bool> setIcon(String iconName) async {
    if (!supportedIcons.contains(iconName)) {
      throw ArgumentError('Unsupported icon: $iconName. Supported icons: $supportedIcons');
    }
    if (_currentIcon == iconName) return true;

    if (Platform.isIOS) {
      try {
        await _iosChannel.invokeMethod('setIcon', {'iconName': iconName});
      } catch (e) {
        debugPrint('🎨 AppIconService: Failed to set iOS icon: $e');
        return false;
      }
    }

    await _saveIcon(iconName);
    debugPrint('🎨 AppIconService: Saved icon preference: $iconName');
    return true;
  }

  /// On launch, adopt the icon iOS actually shows.
  ///
  /// iOS is the source of truth: it never loses the alternate icon, while
  /// the stored preference can be stale (restored backup, an earlier failed
  /// switch). This never calls setAlternateIconName, which would show the
  /// system "You have changed the icon" alert at launch, and fails while the
  /// app is in the background (e.g. launched from CarPlay).
  Future<void> syncIOSIcon() async {
    if (!Platform.isIOS) return;
    try {
      final iosIcon = await _iosChannel.invokeMethod<String>('getCurrentIcon');
      if (iosIcon == null || !supportedIcons.contains(iosIcon)) return;
      if (iosIcon != _currentIcon) {
        debugPrint('🎨 AppIconService: Adopting iOS icon: $iosIcon');
        await _saveIcon(iosIcon);
      }
    } catch (e) {
      debugPrint('🎨 AppIconService: Failed to sync iOS icon: $e');
    }
  }

  Future<void> _saveIcon(String iconName) async {
    _currentIcon = iconName;
    notifyListeners();
    final box = await Hive.openBox<String>(_boxName);
    await box.put(_selectedIconKey, iconName);
  }
}
