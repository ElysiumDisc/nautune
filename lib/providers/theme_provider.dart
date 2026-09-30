import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appearance.dart';
import '../models/playback_state.dart';
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
  Color? _customAccentColor;
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

  /// Custom accent color (null if not set)
  Color? get customAccentColor => _customAccentColor;

  /// Whether custom theme is light mode
  bool get customIsLight => _customIsLight;

  // Appearance preferences
  AppearanceMode _appearanceMode = AppearanceMode.palette;
  CornerStyle _cornerStyle = CornerStyle.squircle;
  AccentSource _accentSource = AccentSource.palette;
  bool _frostedBlur = true;
  bool _artworkTint = true;

  AppearanceMode get appearanceMode => _appearanceMode;
  CornerStyle get cornerStyle => _cornerStyle;
  AccentSource get accentSource => _accentSource;
  bool get frostedBlur => _frostedBlur;
  bool get artworkTint => _artworkTint;

  NautuneStyle get _style => NautuneStyle(
        frostedBlur: _frostedBlur,
        cornerStyle: _cornerStyle,
        artworkTint: _artworkTint,
      );

  /// Theme for [brightness]: the current palette rendered at that brightness,
  /// optionally with [accent] (Now Playing colour) as primary.
  ThemeData themeFor(Brightness brightness, {Color? accent}) => _currentPalette
      .variant(brightness)
      .withAccent(_accentSource == AccentSource.nowPlaying ? accent : null)
      .buildTheme(style: _style);

  /// [ThemeMode] for MaterialApp. "Palette" follows the palette's own
  /// brightness, as before appearance modes existed.
  ThemeMode get themeMode => switch (_appearanceMode) {
        AppearanceMode.palette =>
          _currentPalette.isLight ? ThemeMode.light : ThemeMode.dark,
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      };

  /// Build ThemeData from the current palette at its own brightness
  ThemeData get themeData => themeFor(_currentPalette.brightness);

  void setAppearanceMode(AppearanceMode mode) {
    if (_appearanceMode == mode) return;
    _appearanceMode = mode;
    unawaited(_playbackStateStore.saveUiState(appearanceMode: mode));
    notifyListeners();
  }

  void setCornerStyle(CornerStyle style) {
    if (_cornerStyle == style) return;
    _cornerStyle = style;
    unawaited(_playbackStateStore.saveUiState(cornerStyle: style));
    notifyListeners();
  }

  void setAccentSource(AccentSource source) {
    if (_accentSource == source) return;
    _accentSource = source;
    unawaited(_playbackStateStore.saveUiState(accentSource: source));
    notifyListeners();
  }

  void setFrostedBlur(bool enabled) {
    if (_frostedBlur == enabled) return;
    _frostedBlur = enabled;
    unawaited(_playbackStateStore.saveUiState(frostedBlurEnabled: enabled));
    notifyListeners();
  }

  void setArtworkTint(bool enabled) {
    if (_artworkTint == enabled) return;
    _artworkTint = enabled;
    unawaited(_playbackStateStore.saveUiState(artworkTintEnabled: enabled));
    notifyListeners();
  }

  /// Initialize by loading persisted theme preference.
  ///
  /// This should be called once during app startup. Pass [storedState] when
  /// the caller already loaded it, to avoid decoding it again.
  Future<void> initialize({PlaybackState? storedState}) async {
    debugPrint('ThemeProvider: Initializing...');

    try {
      storedState ??= await _playbackStateStore.load();
      if (storedState != null) {
        // Load custom colors if they exist
        if (storedState.customPrimaryColor != null) {
          _customPrimaryColor = Color(storedState.customPrimaryColor!);
        }
        if (storedState.customSecondaryColor != null) {
          _customSecondaryColor = Color(storedState.customSecondaryColor!);
        }
        if (storedState.customAccentColor != null) {
          _customAccentColor = Color(storedState.customAccentColor!);
        }
        _customIsLight = storedState.customThemeIsLight;
        _appearanceMode = storedState.appearanceMode;
        _cornerStyle = storedState.cornerStyle;
        _accentSource = storedState.accentSource;
        _frostedBlur = storedState.frostedBlurEnabled;
        _artworkTint = storedState.artworkTintEnabled;

        // If using custom theme, rebuild it with stored colors
        if (storedState.themePaletteId == 'custom' &&
            _customPrimaryColor != null &&
            _customSecondaryColor != null) {
          _currentPalette = NautuneColorPalette.custom(
            primary: _customPrimaryColor!,
            secondary: _customSecondaryColor!,
            accent: _customAccentColor,
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
    Color? accent,
    required bool isLight,
  }) {
    _customPrimaryColor = primary;
    _customSecondaryColor = secondary;
    _customAccentColor = accent;
    _customIsLight = isLight;

    _currentPalette = NautuneColorPalette.custom(
      primary: primary,
      secondary: secondary,
      accent: accent,
      isLight: isLight,
    );

    // Persist custom colors (use toARGB32 for int storage)
    unawaited(_playbackStateStore.saveUiState(
      themePaletteId: 'custom',
      customPrimaryColor: primary.toARGB32(),
      customSecondaryColor: secondary.toARGB32(),
      customAccentColor: accent?.toARGB32(),
      customThemeIsLight: isLight,
    ));

    debugPrint('ThemeProvider: Set custom colors (primary: $primary, secondary: $secondary, accent: $accent, light: $isLight)');
    notifyListeners();
  }

  /// Get all preset palettes (excludes custom)
  List<NautuneColorPalette> get presetPalettes => NautunePalettes.presets;

  /// Get all available palettes including custom placeholder
  List<NautuneColorPalette> get availablePalettes => NautunePalettes.all;

  @override
  void dispose() {
    _customPrimaryColor = null;
    _customSecondaryColor = null;
    _customAccentColor = null;
    super.dispose();
  }
}
