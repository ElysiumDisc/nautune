import 'dart:io';

import 'package:flutter/services.dart';

/// Provides haptic feedback for user interactions.
/// Only triggers on mobile platforms (iOS/Android).
class HapticService {
  static bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  /// Light tap feedback - for button taps, toggles
  static void lightTap() {
    if (!_isMobile) return;
    HapticFeedback.lightImpact();
  }

  /// Medium tap feedback - for play/pause, next/previous
  static void mediumTap() {
    if (!_isMobile) return;
    HapticFeedback.mediumImpact();
  }

  /// Heavy tap feedback - for destructive actions, errors
  static void heavyTap() {
    if (!_isMobile) return;
    HapticFeedback.heavyImpact();
  }

  /// Selection change feedback - for slider, picker changes
  static void selectionClick() {
    if (!_isMobile) return;
    HapticFeedback.selectionClick();
  }

  /// Vibrate pattern for success
  static void success() {
    if (!_isMobile) return;
    HapticFeedback.mediumImpact();
  }

  /// Vibrate pattern for error
  static void error() {
    if (!_isMobile) return;
    HapticFeedback.heavyImpact();
  }
}
