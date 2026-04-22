import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// AutoColor allows widgets to specify colors that resolve based on theme context.
/// `auto` resolves to the current extracted primary color from album art.
enum AutoColor {
  auto,
}

/// Represents a complete TUI color theme.
class TuiTheme {
  const TuiTheme({
    required this.name,
    required this.background,
    required this.foreground,
    required this.dim,
    required this.accent,
    required this.selection,
    required this.selectionText,
    required this.error,
    required this.border,
    required this.playing,
    this.primary,
  });

  final String name;
  final Color background;
  final Color foreground;
  final Color dim;
  final Color accent;
  final Color selection;
  final Color selectionText;
  final Color error;
  final Color border;
  final Color playing;
  final Color? primary; // Base primary color, can be overridden by album art

  TuiTheme copyWith({
    String? name,
    Color? background,
    Color? foreground,
    Color? dim,
    Color? accent,
    Color? selection,
    Color? selectionText,
    Color? error,
    Color? border,
    Color? playing,
    Color? primary,
  }) {
    return TuiTheme(
      name: name ?? this.name,
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      dim: dim ?? this.dim,
      accent: accent ?? this.accent,
      selection: selection ?? this.selection,
      selectionText: selectionText ?? this.selectionText,
      error: error ?? this.error,
      border: border ?? this.border,
      playing: playing ?? this.playing,
      primary: primary ?? this.primary,
    );
  }
}

/// Built-in themes collection
class TuiThemes {
  TuiThemes._();

  /// Classic terminal green theme (default)
  static const dark = TuiTheme(
    name: 'Dark',
    background: Color(0xFF000000),
    foreground: Color(0xFFFFFFFF),
    dim: Color(0xFF666666),
    accent: Color(0xFF00FF00),
    selection: Color(0xFF00AA00),
    selectionText: Color(0xFF000000),
    error: Color(0xFFFF4444),
    border: Color(0xFF444444),
    playing: Color(0xFF00FFFF),
    primary: Color(0xFF00FF00),
  );

  /// Gruvbox Dark theme
  static const gruvboxDark = TuiTheme(
    name: 'Gruvbox Dark',
    background: Color(0xFF282828),
    foreground: Color(0xFFEBDBB2),
    dim: Color(0xFF928374),
    accent: Color(0xFFB8BB26),
    selection: Color(0xFF458588),
    selectionText: Color(0xFFEBDBB2),
    error: Color(0xFFCC241D),
    border: Color(0xFF504945),
    playing: Color(0xFFFE8019),
    primary: Color(0xFFB8BB26),
  );

  /// Gruvbox Light theme
  static const gruvboxLight = TuiTheme(
    name: 'Gruvbox Light',
    background: Color(0xFFFBF1C7),
    foreground: Color(0xFF3C3836),
    dim: Color(0xFF928374),
    accent: Color(0xFF79740E),
    selection: Color(0xFF076678),
    selectionText: Color(0xFFFBF1C7),
    error: Color(0xFFCC241D),
    border: Color(0xFFD5C4A1),
    playing: Color(0xFFAF3A03),
    primary: Color(0xFF79740E),
  );

  /// Nord Dark theme
  static const nordDark = TuiTheme(
    name: 'Nord Dark',
    background: Color(0xFF2E3440),
    foreground: Color(0xFFECEFF4),
    dim: Color(0xFF4C566A),
    accent: Color(0xFF88C0D0),
    selection: Color(0xFF5E81AC),
    selectionText: Color(0xFFECEFF4),
    error: Color(0xFFBF616A),
    border: Color(0xFF3B4252),
    playing: Color(0xFFA3BE8C),
    primary: Color(0xFF88C0D0),
  );

  /// Nord Light theme
  static const nordLight = TuiTheme(
    name: 'Nord Light',
    background: Color(0xFFECEFF4),
    foreground: Color(0xFF2E3440),
    dim: Color(0xFF4C566A),
    accent: Color(0xFF5E81AC),
    selection: Color(0xFF88C0D0),
    selectionText: Color(0xFF2E3440),
    error: Color(0xFFBF616A),
    border: Color(0xFFD8DEE9),
    playing: Color(0xFFA3BE8C),
    primary: Color(0xFF5E81AC),
  );

  /// Catppuccin Mocha theme
  static const catppuccinMocha = TuiTheme(
    name: 'Catppuccin Mocha',
    background: Color(0xFF1E1E2E),
    foreground: Color(0xFFCDD6F4),
    dim: Color(0xFF6C7086),
    accent: Color(0xFFA6E3A1),
    selection: Color(0xFF89B4FA),
    selectionText: Color(0xFF1E1E2E),
    error: Color(0xFFF38BA8),
    border: Color(0xFF313244),
    playing: Color(0xFFF9E2AF),
    primary: Color(0xFFA6E3A1),
  );

  /// Catppuccin Latte theme (light)
  static const catppuccinLatte = TuiTheme(
    name: 'Catppuccin Latte',
    background: Color(0xFFEFF1F5),
    foreground: Color(0xFF4C4F69),
    dim: Color(0xFF9CA0B0),
    accent: Color(0xFF40A02B),
    selection: Color(0xFF1E66F5),
    selectionText: Color(0xFFEFF1F5),
    error: Color(0xFFD20F39),
    border: Color(0xFFCCD0DA),
    playing: Color(0xFFDF8E1D),
    primary: Color(0xFF40A02B),
  );

  /// Classic Light theme
  static const light = TuiTheme(
    name: 'Light',
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF000000),
    dim: Color(0xFF888888),
    accent: Color(0xFF0066CC),
    selection: Color(0xFF0066CC),
    selectionText: Color(0xFFFFFFFF),
    error: Color(0xFFCC0000),
    border: Color(0xFFCCCCCC),
    playing: Color(0xFF008800),
    primary: Color(0xFF0066CC),
  );

  /// Dracula theme
  static const dracula = TuiTheme(
    name: 'Dracula',
    background: Color(0xFF282A36),
    foreground: Color(0xFFF8F8F2),
    dim: Color(0xFF6272A4),
    accent: Color(0xFF50FA7B),
    selection: Color(0xFFBD93F9),
    selectionText: Color(0xFF282A36),
    error: Color(0xFFFF5555),
    border: Color(0xFF44475A),
    playing: Color(0xFFFFB86C),
    primary: Color(0xFF50FA7B),
  );

  /// Solarized Dark theme
  static const solarizedDark = TuiTheme(
    name: 'Solarized Dark',
    background: Color(0xFF002B36),
    foreground: Color(0xFF839496),
    dim: Color(0xFF586E75),
    accent: Color(0xFF859900),
    selection: Color(0xFF268BD2),
    selectionText: Color(0xFF002B36),
    error: Color(0xFFDC322F),
    border: Color(0xFF073642),
    playing: Color(0xFFCB4B16),
    primary: Color(0xFF859900),
  );

  /// All available themes
  static const List<TuiTheme> all = [
    dark,
    gruvboxDark,
    gruvboxLight,
    nordDark,
    nordLight,
    catppuccinMocha,
    catppuccinLatte,
    light,
    dracula,
    solarizedDark,
  ];
}

/// TUI visualizer rendering styles. Persisted across launches so the user
/// doesn't have to re-cycle through them every session. `blocks` is the
/// original `▁▂▃▅▇█` bar visualizer; `brailleSpectro` is the Braille-dot
/// spectroscope ported from `tunein-cli`.
enum TuiVisualizerStyle {
  blocks,
  brailleSpectro,
}

extension TuiVisualizerStyleExt on TuiVisualizerStyle {
  String get id => switch (this) {
        TuiVisualizerStyle.blocks => 'blocks',
        TuiVisualizerStyle.brailleSpectro => 'braille_spectro',
      };

  String get label => switch (this) {
        TuiVisualizerStyle.blocks => 'Blocks',
        TuiVisualizerStyle.brailleSpectro => 'Braille',
      };

  /// Next style in the cycle, wrapping back to the first.
  TuiVisualizerStyle get next {
    final values = TuiVisualizerStyle.values;
    return values[(index + 1) % values.length];
  }

  static TuiVisualizerStyle fromId(String? id) {
    for (final style in TuiVisualizerStyle.values) {
      if (style.id == id) return style;
    }
    return TuiVisualizerStyle.blocks;
  }
}

/// Theme manager singleton that handles theme switching and color extraction.
class TuiThemeManager extends ChangeNotifier {
  TuiThemeManager._();

  static final TuiThemeManager _instance = TuiThemeManager._();
  static TuiThemeManager get instance => _instance;

  static const String _boxName = 'nautune_tui_settings';
  static const String _themeKey = 'theme_name';
  static const String _visualizerStyleKey = 'visualizer_style';

  TuiTheme _currentTheme = TuiThemes.dark;
  Color? _extractedPrimary;
  Color? _targetPrimary;
  Color? _currentPrimary;
  double _lerpProgress = 1.0;
  Box? _settingsBox;
  bool _initialized = false;
  TuiVisualizerStyle _visualizerStyle = TuiVisualizerStyle.blocks;

  static const Duration _transitionDuration = Duration(milliseconds: 500);

  /// Initialize the theme manager and load saved theme
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _settingsBox = await Hive.openBox(_boxName);
      final savedThemeName = _settingsBox?.get(_themeKey) as String?;
      if (savedThemeName != null) {
        final savedTheme = TuiThemes.all.firstWhere(
          (t) => t.name == savedThemeName,
          orElse: () => TuiThemes.dark,
        );
        _currentTheme = savedTheme;
        _currentPrimary = savedTheme.primary ?? savedTheme.accent;
        debugPrint('TUI: Restored theme "$savedThemeName"');
      }
      final savedStyle = _settingsBox?.get(_visualizerStyleKey) as String?;
      _visualizerStyle = TuiVisualizerStyleExt.fromId(savedStyle);
      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('TUI: Failed to load saved theme: $e');
      _initialized = true;
    }
  }

  /// Save current theme to persistent storage
  Future<void> _saveTheme() async {
    try {
      await _settingsBox?.put(_themeKey, _currentTheme.name);
    } catch (e) {
      debugPrint('TUI: Failed to save theme: $e');
    }
  }

  /// Current visualizer style. Survives restarts via the same Hive box that
  /// stores the theme choice.
  TuiVisualizerStyle get visualizerStyle => _visualizerStyle;

  /// Cycle to the next visualizer style and persist it.
  void cycleVisualizerStyle() {
    _visualizerStyle = _visualizerStyle.next;
    _saveVisualizerStyle();
    notifyListeners();
  }

  /// Directly set a style (used by the command palette, future settings UI).
  void setVisualizerStyle(TuiVisualizerStyle style) {
    if (style == _visualizerStyle) return;
    _visualizerStyle = style;
    _saveVisualizerStyle();
    notifyListeners();
  }

  Future<void> _saveVisualizerStyle() async {
    try {
      await _settingsBox?.put(_visualizerStyleKey, _visualizerStyle.id);
    } catch (e) {
      debugPrint('TUI: Failed to save visualizer style: $e');
    }
  }

  /// Get current theme
  TuiTheme get currentTheme => _currentTheme;

  /// Get the name of the current theme
  String get currentThemeName => _currentTheme.name;

  /// Get all available themes
  List<TuiTheme> get availableThemes => TuiThemes.all;

  /// Get current primary color (extracted from album art or theme default)
  Color get primaryColor {
    if (_currentPrimary != null) return _currentPrimary!;
    return _extractedPrimary ?? _currentTheme.primary ?? _currentTheme.accent;
  }

  /// Set theme by name
  void setThemeByName(String name) {
    final theme = TuiThemes.all.firstWhere(
      (t) => t.name == name,
      orElse: () => TuiThemes.dark,
    );
    setTheme(theme);
  }

  /// Set theme directly
  void setTheme(TuiTheme theme, {bool save = true}) {
    _currentTheme = theme;
    _extractedPrimary = null;
    _currentPrimary = theme.primary ?? theme.accent;
    _targetPrimary = null;
    _lerpProgress = 1.0;
    if (save) {
      _saveTheme();
    }
    notifyListeners();
  }

  /// Cycle to next theme
  void cycleTheme() {
    final currentIndex = TuiThemes.all.indexOf(_currentTheme);
    final nextIndex = (currentIndex + 1) % TuiThemes.all.length;
    setTheme(TuiThemes.all[nextIndex]);
    debugPrint('TUI: Switched to theme "${_currentTheme.name}"');
  }

  /// Extract primary color from an album art URL
  Future<void> extractPrimaryColor(String? imageUrl, Map<String, String>? headers) async {
    if (imageUrl == null) {
      _setTargetPrimary(_currentTheme.primary ?? _currentTheme.accent);
      return;
    }

    try {
      final color = await _extractDominantColor(imageUrl, headers);
      if (color != null) {
        _setTargetPrimary(color);
      } else {
        _setTargetPrimary(_currentTheme.primary ?? _currentTheme.accent);
      }
    } catch (e) {
      debugPrint('TUI: Failed to extract color: $e');
      _setTargetPrimary(_currentTheme.primary ?? _currentTheme.accent);
    }
  }

  void _setTargetPrimary(Color color) {
    if (_targetPrimary == color) return;
    _targetPrimary = color;
    _lerpProgress = 0.0;
    notifyListeners();
  }

  /// Tick the color lerp animation. Call this from animation frame.
  void tickLerp(Duration elapsed) {
    if (_lerpProgress >= 1.0 || _targetPrimary == null) return;

    final progressDelta = elapsed.inMilliseconds / _transitionDuration.inMilliseconds;
    _lerpProgress = (_lerpProgress + progressDelta).clamp(0.0, 1.0);

    // Smoothstep easing
    final t = _smoothstep(_lerpProgress);

    final from = _currentPrimary ?? _currentTheme.primary ?? _currentTheme.accent;
    _currentPrimary = Color.lerp(from, _targetPrimary!, t);

    if (_lerpProgress >= 1.0) {
      _extractedPrimary = _targetPrimary;
      _currentPrimary = _targetPrimary;
    }

    notifyListeners();
  }

  double _smoothstep(double t) {
    return t * t * (3 - 2 * t);
  }

  /// Extract dominant color from image URL
  Future<Color?> _extractDominantColor(String imageUrl, Map<String, String>? headers) async {
    try {
      final completer = Completer<ui.Image>();

      final networkImage = NetworkImage(imageUrl, headers: headers ?? {});
      final stream = networkImage.resolve(ImageConfiguration.empty);

      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (error, _) {
          completer.completeError(error);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);

      final image = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('Image load timeout'),
      );

      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

      final pixels = byteData.buffer.asUint8List();

      // Sample pixels and find dominant color using simple frequency analysis
      final colorCounts = <int, int>{};
      final step = (pixels.length / 4 / 100).ceil().clamp(1, 1000); // Sample ~100 pixels

      for (int i = 0; i < pixels.length; i += step * 4) {
        final r = pixels[i];
        final g = pixels[i + 1];
        final b = pixels[i + 2];

        // Skip very dark or very light pixels
        final brightness = (r + g + b) / 3;
        if (brightness < 30 || brightness > 225) continue;

        // Quantize to reduce color space
        final qr = (r ~/ 32) * 32;
        final qg = (g ~/ 32) * 32;
        final qb = (b ~/ 32) * 32;

        final colorKey = (qr << 16) | (qg << 8) | qb;
        colorCounts[colorKey] = (colorCounts[colorKey] ?? 0) + 1;
      }

      if (colorCounts.isEmpty) return null;

      // Find most frequent color
      var maxCount = 0;
      var dominantColor = 0;
      for (final entry in colorCounts.entries) {
        if (entry.value > maxCount) {
          maxCount = entry.value;
          dominantColor = entry.key;
        }
      }

      // Boost saturation for better visibility
      final r = (dominantColor >> 16) & 0xFF;
      final g = (dominantColor >> 8) & 0xFF;
      final b = dominantColor & 0xFF;

      final hsl = HSLColor.fromColor(Color.fromRGBO(r, g, b, 1.0));
      final boosted = hsl.withSaturation((hsl.saturation * 1.3).clamp(0.0, 1.0))
                        .withLightness(hsl.lightness.clamp(0.3, 0.7));

      return boosted.toColor();
    } catch (e) {
      debugPrint('TUI: Color extraction error: $e');
      return null;
    }
  }
}

/// TUI color palette - now theme-aware with backwards compatibility.
class TuiColors {
  TuiColors._();

  static TuiTheme get _theme => TuiThemeManager.instance.currentTheme;

  static Color get background => _theme.background;
  static Color get foreground => _theme.foreground;
  static Color get dim => _theme.dim;
  static Color get accent => _theme.accent;
  static Color get selection => _theme.selection;
  static Color get selectionText => _theme.selectionText;
  static Color get error => _theme.error;
  static Color get border => _theme.border;
  static Color get playing => _theme.playing;
  static Color get primary => TuiThemeManager.instance.primaryColor;

  /// Resolve an AutoColor or regular Color to a concrete Color
  static Color resolve(dynamic color) {
    if (color is AutoColor) {
      return primary;
    }
    return color as Color;
  }
}

/// Box-drawing characters for TUI borders.
class TuiChars {
  TuiChars._();

  // Single-line box drawing
  static const String horizontal = '─';
  static const String vertical = '│';
  static const String topLeft = '┌';
  static const String topRight = '┐';
  static const String bottomLeft = '└';
  static const String bottomRight = '┘';
  static const String teeLeft = '├';
  static const String teeRight = '┤';
  static const String teeTop = '┬';
  static const String teeBottom = '┴';
  static const String cross = '┼';

  // Double-line box drawing (for emphasis)
  static const String horizontalDouble = '═';
  static const String verticalDouble = '║';
  static const String topLeftDouble = '╔';
  static const String topRightDouble = '╗';
  static const String bottomLeftDouble = '╚';
  static const String bottomRightDouble = '╝';

  // Selection and indicators
  static const String cursor = '>';
  static const String playing = '♪';
  static const String paused = '‖';
  static const String bullet = '•';
  static const String arrow = '→';
  static const String tempQueueMarker = '▸';

  // Progress bar
  static const String progressFilled = '=';
  static const String progressEmpty = ' ';
  static const String progressHead = '>';
  static const String progressLeft = '[';
  static const String progressRight = ']';

  // Scrollbar
  static const String scrollTrack = '│';
  static const String scrollThumb = '█';

  // Spinner frames for buffering
  static const List<String> spinnerFrames = ['◰', '◳', '◲', '◱'];
}

/// TUI text styles using monospace font - now theme-aware.
class TuiTextStyles {
  TuiTextStyles._();

  static TextStyle get _baseStyle => GoogleFonts.jetBrainsMono(
        color: TuiColors.foreground,
        fontSize: 14.0,
        height: 1.2,
      );

  static TextStyle get normal => _baseStyle;

  static TextStyle get dim => _baseStyle.copyWith(
        color: TuiColors.dim,
      );

  static TextStyle get accent => _baseStyle.copyWith(
        color: TuiColors.accent,
      );

  static TextStyle get selection => _baseStyle.copyWith(
        color: TuiColors.selectionText,
        backgroundColor: TuiColors.selection,
      );

  static TextStyle get playing => _baseStyle.copyWith(
        color: TuiColors.playing,
      );

  static TextStyle get error => _baseStyle.copyWith(
        color: TuiColors.error,
      );

  static TextStyle get bold => _baseStyle.copyWith(
        fontWeight: FontWeight.bold,
      );

  static TextStyle get title => _baseStyle.copyWith(
        fontWeight: FontWeight.bold,
        fontSize: 16.0,
      );

  static TextStyle get primary => _baseStyle.copyWith(
        color: TuiColors.primary,
      );

  /// Returns the base text style for character measurement.
  static TextStyle get measureStyle => _baseStyle;
}
