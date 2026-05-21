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

  /// Default sidebar width in characters (used when no layout info is
  /// available). Most callers should prefer `sidebarCharsForWidth`.
  static const int sidebarChars = 22;

  /// Status bar height in lines.
  static const int statusBarLines = 3;

  /// Minimum content pane width in characters.
  static const int minContentChars = 32;

  /// Responsive sidebar width (in characters) for a given window pixel width.
  /// Scales with terminal width so an 80-col window doesn't end up with the
  /// sidebar eating the whole content area:
  ///   total > 120 cols → 26
  ///   total 90–120 cols → 22
  ///   total < 90 cols → 18
  /// Always leaves at least `minContentChars` for the content pane.
  static int sidebarCharsForWidth(double pixelWidth) =>
      sidebarCharsForTotalChars(widthToChars(pixelWidth));

  /// Pure boundary math for `sidebarCharsForWidth`, factored out so it can be
  /// unit-tested without bringing up a `TextPainter` / Flutter binding.
  static int sidebarCharsForTotalChars(int totalChars) {
    int sidebar;
    if (totalChars > 120) {
      sidebar = 26;
    } else if (totalChars >= 90) {
      sidebar = 22;
    } else {
      sidebar = 18;
    }
    final maxSidebar = (totalChars - minContentChars).clamp(12, 32);
    return sidebar.clamp(12, maxSidebar).toInt();
  }

  /// Responsive sidebar width in pixels.
  static double sidebarWidthForWidth(double pixelWidth) =>
      charsToWidth(sidebarCharsForWidth(pixelWidth));

  /// Default sidebar width in pixels (legacy, prefer `sidebarWidthForWidth`).
  static double get sidebarWidth => charsToWidth(sidebarChars);

  /// Status bar height in pixels.
  static double get statusBarHeight => linesToHeight(statusBarLines);
}
