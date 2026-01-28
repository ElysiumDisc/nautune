import 'package:flutter/material.dart';

import '../tui_metrics.dart';
import '../tui_theme.dart';

/// A container widget with box-drawing character borders.
/// Creates the classic TUI aesthetic with │ ─ ┌ ┐ └ ┘ characters.
class TuiBox extends StatelessWidget {
  const TuiBox({
    super.key,
    required this.child,
    this.title,
    this.focused = false,
    this.showBorder = true,
  });

  final Widget child;
  final String? title;
  final bool focused;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    if (!showBorder) {
      return child;
    }

    final borderColor = focused ? TuiColors.accent : TuiColors.border;
    final borderStyle = TuiTextStyles.normal.copyWith(color: borderColor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top border with optional title
        _buildTopBorder(borderStyle),
        // Content with side borders
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(TuiChars.vertical, style: borderStyle),
              Expanded(child: child),
              Text(TuiChars.vertical, style: borderStyle),
            ],
          ),
        ),
        // Bottom border
        _buildBottomBorder(borderStyle),
      ],
    );
  }

  Widget _buildTopBorder(TextStyle style) {
    if (title == null) {
      return Row(
        children: [
          Text(TuiChars.topLeft, style: style),
          Expanded(
            child: Text(
              TuiChars.horizontal * 1000, // Will be clipped
              style: style,
              overflow: TextOverflow.clip,
              maxLines: 1,
            ),
          ),
          Text(TuiChars.topRight, style: style),
        ],
      );
    }

    return Row(
      children: [
        Text(TuiChars.topLeft, style: style),
        Text(TuiChars.horizontal, style: style),
        Text(
          ' $title ',
          style: focused ? TuiTextStyles.accent : TuiTextStyles.normal,
        ),
        Expanded(
          child: Text(
            TuiChars.horizontal * 1000,
            style: style,
            overflow: TextOverflow.clip,
            maxLines: 1,
          ),
        ),
        Text(TuiChars.topRight, style: style),
      ],
    );
  }

  Widget _buildBottomBorder(TextStyle style) {
    return Row(
      children: [
        Text(TuiChars.bottomLeft, style: style),
        Expanded(
          child: Text(
            TuiChars.horizontal * 1000,
            style: style,
            overflow: TextOverflow.clip,
            maxLines: 1,
          ),
        ),
        Text(TuiChars.bottomRight, style: style),
      ],
    );
  }
}

/// A simple horizontal divider using box-drawing characters.
class TuiHorizontalDivider extends StatelessWidget {
  const TuiHorizontalDivider({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = TuiTextStyles.normal.copyWith(
      color: color ?? TuiColors.border,
    );

    return Text(
      TuiChars.horizontal * 1000,
      style: style,
      overflow: TextOverflow.clip,
      maxLines: 1,
    );
  }
}

/// A simple vertical divider using box-drawing characters.
class TuiVerticalDivider extends StatelessWidget {
  const TuiVerticalDivider({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = TuiTextStyles.normal.copyWith(
      color: color ?? TuiColors.border,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final lineHeight = TuiMetrics.charHeight;
        final lineCount = (constraints.maxHeight / lineHeight).floor();

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            lineCount,
            (_) => Text(TuiChars.vertical, style: style),
          ),
        );
      },
    );
  }
}
