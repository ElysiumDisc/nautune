import 'package:flutter/material.dart';

import 'tui_theme.dart';

/// Character grid metrics for TUI layout calculations.
/// Provides character-based sizing for the monospace terminal aesthetic.
class TuiMetrics {
  TuiMetrics._();

  static double? _charWidth;
  static double? _charHeight;

  /// Initialize metrics by measuring a character.
  /// Must be called before using charWidth/charHeight.
  static void initialize() {
    if (_charWidth != null && _charHeight != null) return;

    final painter = TextPainter(
      text: TextSpan(text: 'M', style: TuiTextStyles.measureStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    _charWidth = painter.width;
    _charHeight = painter.height;
  }

  /// Width of a single monospace character.
  static double get charWidth {
    initialize();
    return _charWidth!;
  }

  /// Height of a single monospace character line.
  static double get charHeight {
    initialize();
    return _charHeight!;
  }

  /// Convert character count to pixel width.
  static double charsToWidth(int chars) => chars * charWidth;

  /// Convert line count to pixel height.
  static double linesToHeight(int lines) => lines * charHeight;

  /// Convert pixel width to character count (floor).
  static int widthToChars(double width) => (width / charWidth).floor();

  /// Convert pixel height to line count (floor).
  static int heightToLines(double height) => (height / charHeight).floor();

  /// Sidebar width in characters.
  static const int sidebarChars = 22;

  /// Status bar height in lines.
  static const int statusBarLines = 3;

  /// Minimum content pane width in characters.
  static const int minContentChars = 40;

  /// Sidebar width in pixels.
  static double get sidebarWidth => charsToWidth(sidebarChars);

  /// Status bar height in pixels.
  static double get statusBarHeight => linesToHeight(statusBarLines);
}
