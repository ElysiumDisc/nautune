import 'dart:async';

import 'package:flutter/material.dart';

import '../services/playback_state_store.dart';
import '../theme/nautune_theme.dart';

/// Manages the app's color theme/palette selection.
///
/// Responsibilities:
/// - Current palette selection
/// - Theme persistence
/// - Building ThemeData from selected palette
/// - Custom color theme support
///
/// This provider is independent from other providers and only handles
/// visual theming concerns.
class ThemeProvider extends ChangeNotifier {
  ThemeProvider({
    required PlaybackStateStore playbackStateStore,
  }) : _playbackStateStore = playbackStateStore;

  final PlaybackStateStore _playbackStateStore;

  NautuneColorPalette _currentPalette = NautunePalettes.purpleOcean;
  bool _isInitialized = false;

  // Custom theme colors
  Color? _customPrimaryColor;
  Color? _customSecondaryColor;
  bool _customIsLight = false;

  /// The currently selected color palette
  NautuneColorPalette get palette => _currentPalette;

  /// Whether the provider has been initialized
  bool get isInitialized => _isInitialized;

  /// Whether using a custom theme
  bool get isCustomTheme => _currentPalette.id == 'custom';

  /// Custom primary color (null if not set)
  Color? get customPrimaryColor => _customPrimaryColor;

  /// Custom secondary color (null if not set)
  Color? get customSecondaryColor => _customSecondaryColor;

  /// Whether custom theme is light mode
  bool get customIsLight => _customIsLight;

  /// Build ThemeData from the current palette
  ThemeData get themeData => _currentPalette.buildTheme();

  /// Initialize by loading persisted theme preference.
  ///
  /// This should be called once during app startup.
  Future<void> initialize() async {
    debugPrint('ThemeProvider: Initializing...');

    try {
      final storedState = await _playbackStateStore.load();
      if (storedState != null) {
        // Load custom colors if they exist
        if (storedState.customPrimaryColor != null) {
          _customPrimaryColor = Color(storedState.customPrimaryColor!);
        }
        if (storedState.customSecondaryColor != null) {
          _customSecondaryColor = Color(storedState.customSecondaryColor!);
        }
        _customIsLight = storedState.customThemeIsLight;

        // If using custom theme, rebuild it with stored colors
        if (storedState.themePaletteId == 'custom' &&
            _customPrimaryColor != null &&
            _customSecondaryColor != null) {
          _currentPalette = NautuneColorPalette.custom(
            primary: _customPrimaryColor!,
            secondary: _customSecondaryColor!,
            isLight: _customIsLight,
          );
          debugPrint('ThemeProvider: Restored custom palette');
        } else {
          _currentPalette = NautunePalettes.getById(storedState.themePaletteId);
          debugPrint('ThemeProvider: Restored palette "${_currentPalette.name}"');
        }
      }
    } catch (error) {
      debugPrint('ThemeProvider: Failed to load theme preference: $error');
    }

    _isInitialized = true;
    notifyListeners();
  }

  /// Set the current palette by ID (for preset palettes)
  void setPaletteById(String id) {
    if (id == 'custom') {
      // Use setCustomColors instead
      return;
    }

    final newPalette = NautunePalettes.getById(id);
    if (_currentPalette.id == newPalette.id) return;

    _currentPalette = newPalette;
    unawaited(_playbackStateStore.saveUiState(themePaletteId: id));
    debugPrint('ThemeProvider: Changed palette to "${_currentPalette.name}"');
    notifyListeners();
  }

  /// Set the current palette directly
  void setPalette(NautuneColorPalette palette) {
    if (_currentPalette.id == palette.id && palette.id != 'custom') return;

    _currentPalette = palette;
    unawaited(_playbackStateStore.saveUiState(themePaletteId: palette.id));
    debugPrint('ThemeProvider: Changed palette to "${_currentPalette.name}"');
    notifyListeners();
  }

  /// Set custom theme colors
  void setCustomColors({
    required Color primary,
    required Color secondary,
    required bool isLight,
  }) {
    _customPrimaryColor = primary;
    _customSecondaryColor = secondary;
    _customIsLight = isLight;

    _currentPalette = NautuneColorPalette.custom(
      primary: primary,
      secondary: secondary,
      isLight: isLight,
    );

    // Persist custom colors (use toARGB32 for int storage)
    unawaited(_playbackStateStore.saveUiState(
      themePaletteId: 'custom',
      customPrimaryColor: primary.toARGB32(),
      customSecondaryColor: secondary.toARGB32(),
      customThemeIsLight: isLight,
    ));

    debugPrint('ThemeProvider: Set custom colors (primary: $primary, secondary: $secondary, light: $isLight)');
    notifyListeners();
  }

  /// Get all preset palettes (excludes custom)
  List<NautuneColorPalette> get presetPalettes => NautunePalettes.presets;

  /// Get all available palettes including custom placeholder
  List<NautuneColorPalette> get availablePalettes => NautunePalettes.all;
}
