import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/nautune_theme.dart';

/// Translucent, blurred bar background (tab bar, mini player, toolbars), as
/// iOS draws its system bars. Falls back to an opaque bar when the user turned
/// frosted blur off or the system asks for higher contrast.
class FrostedBar extends StatelessWidget {
  const FrostedBar({
    super.key,
    required this.child,
    this.topBorder = true,
    this.bottomBorder = false,
    this.color,
  });

  final Widget child;
  final bool topBorder;
  final bool bottomBorder;

  /// Overrides the theme's bar colour (e.g. an artwork tint). Its alpha is
  /// kept when blurring and forced opaque otherwise.
  final Color? color;

  static bool blurEnabled(BuildContext context) =>
      NautuneStyle.of(context).frostedBlur && !MediaQuery.highContrastOf(context);

  @override
  Widget build(BuildContext context) {
    final style = NautuneStyle.of(context);
    final blur = blurEnabled(context);
    final base = color ?? style.barColor;
    final hairline = BorderSide(color: style.separator, width: 0.5);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: blur
            ? base
            : Color.alphaBlend(base, style.groupedBackground).withValues(alpha: 1),
        border: Border(
          top: topBorder ? hairline : BorderSide.none,
          bottom: bottomBorder ? hairline : BorderSide.none,
        ),
      ),
      child: child,
    );
    if (!blur) return bar;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: bar,
      ),
    );
  }
}
