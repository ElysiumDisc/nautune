import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// TUI color palette - minimal, high-contrast colors for terminal aesthetic.
class TuiColors {
  TuiColors._();

  static const Color background = Color(0xFF000000);
  static const Color foreground = Color(0xFFFFFFFF);
  static const Color dim = Color(0xFF666666);
  static const Color accent = Color(0xFF00FF00); // Terminal green
  static const Color selection = Color(0xFF00AA00);
  static const Color selectionText = Color(0xFF000000);
  static const Color error = Color(0xFFFF4444);
  static const Color border = Color(0xFF444444);
  static const Color playing = Color(0xFF00FFFF); // Cyan for now playing
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

  // Progress bar
  static const String progressFilled = '=';
  static const String progressEmpty = ' ';
  static const String progressHead = '>';
  static const String progressLeft = '[';
  static const String progressRight = ']';
}

/// TUI text styles using monospace font.
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

  /// Returns the base text style for character measurement.
  static TextStyle get measureStyle => _baseStyle;
}
