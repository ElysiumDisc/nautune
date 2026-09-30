import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/appearance.dart';
import 'nautune_spacing.dart';

/// Represents a color palette for the Nautune app theme
class NautuneColorPalette {
  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final bool isLight; // Whether this is a light theme

  const NautuneColorPalette({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    this.isLight = false,
  });

  /// Create a custom palette from user-selected primary, secondary, and accent colors
  factory NautuneColorPalette.custom({
    required Color primary,
    required Color secondary,
    Color? accent,
    required bool isLight,
  }) {
    // Generate complementary colors based on primary/secondary. The user can
    // pick any colours, so every role is pushed to a readable contrast
    // against the generated surface (text 4.5:1, accents 3:1).
    final hsl = HSLColor.fromColor(primary);

    if (isLight) {
      // Light theme: light surface with dark text
      // Use user-selected accent or fall back to dark version of primary
      final surface = Color.lerp(Colors.white, primary, 0.03)!; // Very light tint of primary
      final textPrimaryColor = accent ?? hsl.withLightness(0.25).toColor();
      return NautuneColorPalette(
        id: 'custom',
        name: 'Custom',
        primary: _withContrast(primary, surface, 3),
        secondary: _withContrast(secondary, surface, 3),
        surface: surface,
        textPrimary: _withContrast(textPrimaryColor, surface, 4.5),
        textSecondary: _withContrast(Colors.grey.shade600, surface, 4.5),
        isLight: true,
      );
    } else {
      // Dark theme: dark surface with light text
      // Use user-selected accent or fall back to secondary
      final surface = hsl
          .withLightness(0.08)
          .withSaturation(hsl.saturation * 0.3)
          .toColor();
      final textPrimaryColor = accent ?? secondary;
      return NautuneColorPalette(
        id: 'custom',
        name: 'Custom',
        primary: _withContrast(primary, surface, 3),
        secondary: _withContrast(secondary, surface, 3),
        surface: surface,
        textPrimary: _withContrast(textPrimaryColor, surface, 4.5),
        textSecondary: _withContrast(Color.lerp(Colors.grey, secondary, 0.2)!, surface, 4.5),
        isLight: false,
      );
    }
  }

  Brightness get brightness => isLight ? Brightness.light : Brightness.dark;

  /// This palette rendered at [target] brightness. A palette designed for the
  /// other brightness keeps its hues but gets a generated surface and text
  /// colours with readable contrast, so every preset (and custom palette)
  /// works in light and dark mode.
  NautuneColorPalette variant(Brightness target) {
    if (target == brightness) return this;
    if (target == Brightness.light) {
      final surface = Color.lerp(Colors.white, primary, 0.04)!;
      return NautuneColorPalette(
        id: id,
        name: name,
        primary: _withContrast(primary, surface, 3),
        secondary: _withContrast(secondary, surface, 3),
        surface: surface,
        textPrimary: _withContrast(textPrimary, surface, 4.5),
        textSecondary: Colors.grey.shade600,
        isLight: true,
      );
    }
    final hsl = HSLColor.fromColor(primary);
    final surface = hsl
        .withLightness(0.08)
        .withSaturation(hsl.saturation * 0.3)
        .toColor();
    return NautuneColorPalette(
      id: id,
      name: name,
      primary: _withContrast(primary, surface, 3),
      secondary: _withContrast(secondary, surface, 3),
      surface: surface,
      textPrimary: _withContrast(textPrimary, surface, 4.5),
      textSecondary: Color.lerp(Colors.grey, secondary, 0.2)!,
      isLight: false,
    );
  }

  /// This palette with [accent] as its primary colour (Now Playing accent),
  /// adjusted for contrast against the surface.
  NautuneColorPalette withAccent(Color? accent) {
    if (accent == null) return this;
    final primary = _withContrast(accent, surface, 3);
    return NautuneColorPalette(
      id: id,
      name: name,
      primary: primary,
      secondary: _withContrast(
        Color.lerp(accent, isLight ? Colors.black : Colors.white, 0.15)!,
        surface,
        3,
      ),
      surface: surface,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      isLight: isLight,
    );
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// [c] with its HSL lightness moved away from [background] (darker on a
  /// light background, lighter on a dark one) until the WCAG contrast ratio
  /// reaches [min]. Hue and saturation are kept.
  static Color _withContrast(Color c, Color background, double min) {
    if (_contrast(c, background) >= min) return c;
    final towardDark =
        ThemeData.estimateBrightnessForColor(background) == Brightness.light;
    var hsl = HSLColor.fromColor(c);
    for (var i = 0; i < 50; i++) {
      final l = (hsl.lightness + (towardDark ? -0.02 : 0.02)).clamp(0.0, 1.0);
      hsl = hsl.withLightness(l);
      final candidate = hsl.toColor();
      if (_contrast(candidate, background) >= min || l == 0 || l == 1) {
        return candidate;
      }
    }
    return hsl.toColor();
  }

  /// Black or white, whichever reads better on [background].
  static Color _onColor(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : Colors.black;

  /// Build a ThemeData from this palette at its own brightness.
  ThemeData buildTheme({NautuneStyle style = const NautuneStyle()}) =>
      _build(style);

  /// The single app-wide type scale. Every style gets the platform font and a
  /// palette colour, so `theme.textTheme.<role>` is never missing a colour.
  /// Secondary roles (titleSmall / labelMedium / labelSmall) use the muted
  /// palette colour. Decorative fonts (Pacifico) are reserved for the app
  /// wordmark and easter-egg screens; don't add them here.
  TextTheme _buildTextTheme(TextTheme base, Color onSurface, Color secondaryText) {
    final themed = base.apply(bodyColor: onSurface, displayColor: onSurface);
    return themed.copyWith(
      titleLarge: themed.titleLarge?.copyWith(fontSize: 22, fontWeight: FontWeight.bold),
      titleSmall: themed.titleSmall?.copyWith(color: secondaryText),
      labelMedium: themed.labelMedium?.copyWith(color: secondaryText),
      labelSmall: themed.labelSmall?.copyWith(color: secondaryText),
    );
  }

  /// iOS-flavoured Material 3 theme. Palette colours keep their roles
  /// (primary/secondary accents, textPrimary as body text on dark palettes);
  /// the container and surface tiers are derived from them so grouped lists,
  /// sheets and bars layer like iOS system backgrounds.
  ThemeData _build(NautuneStyle style) {
    final brightness = this.brightness;
    final onSurface = isLight ? const Color(0xFF1A1A1A) : textPrimary;
    // Secondary text (subtitles, footnotes, captions) must stay readable
    // whatever the palette says.
    final secondaryText = _withContrast(textSecondary, surface, 4.5);
    Color tier(double amount) => isLight
        ? Color.alphaBlend(primary.withValues(alpha: amount * 0.6), Colors.white)
        : Color.alphaBlend(
            Colors.white.withValues(alpha: amount),
            Color.alphaBlend(primary.withValues(alpha: 0.05), surface),
          );
    // iOS "secondarySystemGroupedBackground": the cell colour in grouped lists.
    final groupedCell = isLight ? Colors.white : tier(0.07);
    final separator = onSurface.withValues(alpha: isLight ? 0.12 : 0.14);

    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      onPrimary: _onColor(primary),
      secondary: secondary,
      onSecondary: _onColor(secondary),
      tertiary: textPrimary,
      onTertiary: _onColor(textPrimary),
      surface: surface,
      onSurface: onSurface,
      onSurfaceVariant: secondaryText,
      surfaceContainerLowest: isLight ? Colors.white : tier(0.02),
      surfaceContainerLow: tier(0.04),
      surfaceContainer: tier(0.06),
      surfaceContainerHigh: tier(0.09),
      surfaceContainerHighest: tier(0.12),
      outline: secondaryText.withValues(alpha: 0.6),
      outlineVariant: separator,
      surfaceTint: Colors.transparent,
    );

    final style0 = style.copyWith(
      groupedBackground: surface,
      groupedCell: groupedCell,
      separator: separator,
      barColor: surface.withValues(alpha: style.frostedBlur ? 0.72 : 1.0),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      platform: TargetPlatform.iOS,
    );
    final cornerShape = style0.shape(NautuneRadius.md);

    return base.copyWith(
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      // iOS has no ink ripples; keep a soft highlight for touch feedback.
      splashFactory: NoSplash.splashFactory,
      highlightColor: onSurface.withValues(alpha: 0.06),
      textTheme: _buildTextTheme(base.textTheme, onSurface, secondaryText),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        },
      ),
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: primary,
        scaffoldBackgroundColor: surface,
        barBackgroundColor: style0.barColor,
        textTheme: CupertinoTextThemeData(
          primaryColor: primary,
          textStyle: TextStyle(
            inherit: false,
            fontFamily: 'CupertinoSystemText',
            fontSize: 17,
            letterSpacing: -0.41,
            color: onSurface,
          ),
          navTitleTextStyle: TextStyle(
            inherit: false,
            fontFamily: 'CupertinoSystemText',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.41,
            color: onSurface,
          ),
          navLargeTitleTextStyle: TextStyle(
            inherit: false,
            fontFamily: 'CupertinoSystemDisplay',
            fontSize: 34,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.38,
            color: onSurface,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: groupedCell,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: cornerShape,
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        textColor: onSurface,
        iconColor: primary,
      ),
      iconTheme: IconThemeData(color: primary),
      dividerTheme: DividerThemeData(color: separator, thickness: 0.5, space: 0.5),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        thumbColor: isLight ? Colors.white : onSurface,
        inactiveTrackColor: onSurface.withValues(alpha: 0.15),
        trackHeight: 4,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return onSurface.withValues(alpha: 0.16);
        }),
        thumbColor: const WidgetStatePropertyAll(Colors.white),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: primary),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        shape: style0.shape(NautuneRadius.lg),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: style0.shape(NautuneRadius.md)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: style0.shape(NautuneRadius.md)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isLight ? const Color(0xFF2C2C2E) : tier(0.16),
        contentTextStyle: TextStyle(color: isLight ? Colors.white : onSurface),
        actionTextColor: isLight ? _withContrast(primary, const Color(0xFF2C2C2E), 4.5) : primary,
        shape: style0.shape(NautuneRadius.md),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: isLight ? primary : onSurface,
        unselectedLabelColor: secondaryText,
        indicatorColor: primary,
        dividerColor: Colors.transparent,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: primary,
          selectedForegroundColor: scheme.onPrimary,
          side: BorderSide(color: separator),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: tier(0.08),
        labelStyle: TextStyle(color: onSurface),
        selectedColor: primary,
        secondarySelectedColor: primary,
        side: BorderSide.none,
        shape: const StadiumBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: groupedCell,
        shape: style0.shape(NautuneRadius.lg),
        titleTextStyle: TextStyle(color: onSurface, fontSize: 20, fontWeight: FontWeight.bold),
        contentTextStyle: TextStyle(color: secondaryText),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: groupedCell,
        textStyle: TextStyle(color: onSurface),
        shape: style0.shape(NautuneRadius.md),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isLight ? surface : tier(0.05),
        showDragHandle: true,
        dragHandleColor: onSurface.withValues(alpha: 0.25),
        shape: style0.shape(
          NautuneRadius.xl,
          corners: const BorderRadius.vertical(
            top: Radius.circular(NautuneRadius.xl),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: style0.barColor,
        indicatorColor: primary.withValues(alpha: 0.18),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: onSurface.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: NautuneRadius.allMd,
          borderSide: BorderSide.none,
        ),
      ),
      extensions: [style0],
    );
  }
}

/// App-wide style knobs the user can customise that Material's ThemeData
/// has no slot for. Read with `NautuneStyle.of(context)`.
@immutable
class NautuneStyle extends ThemeExtension<NautuneStyle> {
  const NautuneStyle({
    this.frostedBlur = true,
    this.cornerStyle = CornerStyle.squircle,
    this.artworkTint = true,
    this.groupedBackground = Colors.black,
    this.groupedCell = const Color(0xFF1C1C1E),
    this.separator = const Color(0x24FFFFFF),
    this.barColor = const Color(0xB8000000),
  });

  /// Translucent, blurred bars and sheets (off = opaque, cheaper).
  final bool frostedBlur;
  final CornerStyle cornerStyle;

  /// Tint the mini player, queue and player chrome from the artwork.
  final bool artworkTint;

  /// iOS systemGroupedBackground / secondarySystemGroupedBackground.
  final Color groupedBackground;
  final Color groupedCell;
  final Color separator;

  /// Background for tab bar, mini player and navigation bars.
  final Color barColor;

  static NautuneStyle of(BuildContext context) =>
      Theme.of(context).extension<NautuneStyle>() ?? const NautuneStyle();

  /// Border for a card/sheet/button of corner [radius] in the user's corner
  /// style.
  /// Pass [corners] to round only some corners (e.g. a sheet's top edge).
  OutlinedBorder shape(double radius, {BorderRadius? corners}) {
    final borderRadius = corners ?? BorderRadius.circular(radius);
    return cornerStyle == CornerStyle.squircle
        ? RoundedSuperellipseBorder(borderRadius: borderRadius)
        : RoundedRectangleBorder(borderRadius: borderRadius);
  }

  @override
  NautuneStyle copyWith({
    bool? frostedBlur,
    CornerStyle? cornerStyle,
    bool? artworkTint,
    Color? groupedBackground,
    Color? groupedCell,
    Color? separator,
    Color? barColor,
  }) {
    return NautuneStyle(
      frostedBlur: frostedBlur ?? this.frostedBlur,
      cornerStyle: cornerStyle ?? this.cornerStyle,
      artworkTint: artworkTint ?? this.artworkTint,
      groupedBackground: groupedBackground ?? this.groupedBackground,
      groupedCell: groupedCell ?? this.groupedCell,
      separator: separator ?? this.separator,
      barColor: barColor ?? this.barColor,
    );
  }

  @override
  NautuneStyle lerp(covariant NautuneStyle? other, double t) {
    if (other == null) return this;
    return NautuneStyle(
      frostedBlur: t < 0.5 ? frostedBlur : other.frostedBlur,
      cornerStyle: t < 0.5 ? cornerStyle : other.cornerStyle,
      artworkTint: t < 0.5 ? artworkTint : other.artworkTint,
      groupedBackground: Color.lerp(groupedBackground, other.groupedBackground, t)!,
      groupedCell: Color.lerp(groupedCell, other.groupedCell, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      barColor: Color.lerp(barColor, other.barColor, t)!,
    );
  }
}

/// iOS Human Interface type roles over the app's [TextTheme], so new UI can
/// say `textTheme.headline` instead of hard-coding font sizes. Colours come
/// from the theme (bodyMedium for primary text, labelMedium for secondary).
extension NautuneTypography on TextTheme {
  TextStyle _role(double size, FontWeight weight, {bool secondary = false}) =>
      (secondary ? labelMedium : bodyMedium)!.copyWith(
        fontSize: size,
        fontWeight: weight,
        height: 1.2,
      );

  TextStyle get largeTitle => _role(34, FontWeight.w700);
  TextStyle get title1 => _role(28, FontWeight.w700);
  TextStyle get title2 => _role(22, FontWeight.w700);
  TextStyle get title3 => _role(20, FontWeight.w600);
  TextStyle get headline => _role(17, FontWeight.w600);
  TextStyle get body => _role(17, FontWeight.w400);
  TextStyle get callout => _role(16, FontWeight.w400);
  TextStyle get subhead => _role(15, FontWeight.w400);
  TextStyle get footnote => _role(13, FontWeight.w400, secondary: true);
  TextStyle get caption => _role(12, FontWeight.w400, secondary: true);
}


/// All available color palettes
class NautunePalettes {
  /// Purple Ocean - The default Nautune theme
  static const purpleOcean = NautuneColorPalette(
    id: 'purple_ocean',
    name: 'Purple Ocean',
    primary: Color(0xFF4B1D77),      // Deep purple
    secondary: Color(0xFF7A3DF1),    // Violet accent
    surface: Color(0xFF1E102D),      // Dark purple surface
    textPrimary: Color(0xFF409CFF),  // Ocean blue
    textSecondary: Color(0xFF8B9DC3), // Muted blue-gray
  );

  /// Apricot Garden - Warm orange with fresh green accents
  static const apricotGarden = NautuneColorPalette(
    id: 'apricot_garden',
    name: 'Apricot Garden',
    primary: Color(0xFFFF8C42),      // Apricot orange
    secondary: Color(0xFFFFAB76),    // Light apricot
    surface: Color(0xFF1A1A2E),      // Dark navy
    textPrimary: Color(0xFF4ADE80),  // Fresh green
    textSecondary: Color(0xFFB5E48C), // Light green
  );

  /// Raspberry Sunset - Bold red with golden yellow
  static const raspberrySunset = NautuneColorPalette(
    id: 'raspberry_sunset',
    name: 'Raspberry Sunset',
    primary: Color(0xFFE63946),      // Raspberry red
    secondary: Color(0xFFFF6B6B),    // Light red
    surface: Color(0xFF1D1128),      // Dark wine
    textPrimary: Color(0xFFFFC947),  // Golden yellow
    textSecondary: Color(0xFFFFE066), // Light yellow
  );

  /// Emerald Rose - Rich green with pink highlights
  static const emeraldRose = NautuneColorPalette(
    id: 'emerald_rose',
    name: 'Emerald Rose',
    primary: Color(0xFF10B981),      // Emerald green
    secondary: Color(0xFF34D399),    // Light emerald
    surface: Color(0xFF0F1419),      // Near black
    textPrimary: Color(0xFFEC4899),  // Rose pink
    textSecondary: Color(0xFFF472B6), // Light pink
  );

  /// OLED Peach - True black OLED with salmon/peach accents
  static const oledPeach = NautuneColorPalette(
    id: 'oled_peach',
    name: 'OLED Peach',
    primary: Color(0xFFFF8A80),      // Salmon/coral
    secondary: Color(0xFFFFAB91),    // Light peach
    surface: Color(0xFF000000),      // Pure black for OLED
    textPrimary: Color(0xFFFFCCBC),  // Cream peach
    textSecondary: Color(0xFF8D6E63), // Warm brown
  );

  /// Light Lavender - Clean white with dark purple accents
  static const lightLavender = NautuneColorPalette(
    id: 'light_lavender',
    name: 'Light Lavender',
    primary: Color(0xFF6B21A8),      // Dark purple
    secondary: Color(0xFF9333EA),    // Vivid purple
    surface: Color(0xFFFAF5FF),      // Very light lavender white
    textPrimary: Color(0xFF581C87),  // Deep purple
    textSecondary: Color(0xFF6B6478), // Lavender gray (5.3:1 on the surface)
    isLight: true,
  );

  /// Custom theme placeholder (actual colors set via ThemeProvider)
  static const custom = NautuneColorPalette(
    id: 'custom',
    name: 'Custom',
    primary: Color(0xFF6B21A8),  // Default purple (will be overridden)
    secondary: Color(0xFF9333EA),
    surface: Color(0xFF1A1A2E),
    textPrimary: Color(0xFF409CFF),
    textSecondary: Color(0xFF8B9DC3),
  );

  /// List of all preset palettes (excludes custom)
  static const List<NautuneColorPalette> presets = [
    purpleOcean,
    lightLavender,
    oledPeach,
    apricotGarden,
    raspberrySunset,
    emeraldRose,
  ];

  /// List of all available palettes including custom
  static const List<NautuneColorPalette> all = [
    purpleOcean,
    lightLavender,
    oledPeach,
    apricotGarden,
    raspberrySunset,
    emeraldRose,
    custom,
  ];

  /// Get a palette by its ID, returns default if not found
  static NautuneColorPalette getById(String id) {
    if (id == 'custom') return custom;  // Custom is handled specially by ThemeProvider
    return presets.firstWhere(
      (palette) => palette.id == id,
      orElse: () => purpleOcean,
    );
  }
}

/// Cross-screen accent colours that recur in feature/easter-egg screens
/// (Profile shelves, Frets on Fire, ListenBrainz badges). Centralised so the
/// values stop drifting and so a future palette tweak only edits one place.
///
/// Core screens should prefer `Theme.of(context).colorScheme` roles; these are
/// only for fixed semantic/brand/categorical accents that have no scheme role
/// (positive-trend green, ListenBrainz orange, game colours).
class NautuneFeatureColors {
  const NautuneFeatureColors._();

  /// "Emerald sea" — positive/growth accents on Profile stat cards.
  static const Color verdantGreen = Color(0xFF10B981);

  /// "Gold treasure" — Frets on Fire fire colour, Profile highlight accents.
  static const Color treasureGold = Color(0xFFFFD700);

  /// Lightning-blue cyan — visualizers, Frets on Fire arcs.
  static const Color cyanVisualizer = Color(0xFF00BFFF);

  /// ListenBrainz brand orange — Profile integration badge.
  static const Color listenBrainzOrange = Color(0xFFEB743B);
}
