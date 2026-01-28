import 'package:flutter/material.dart';

import '../tui_metrics.dart';
import '../tui_theme.dart';

/// A monospace text widget with character-based truncation.
/// Truncates text to fit within a specified character width.
class TuiText extends StatelessWidget {
  const TuiText(
    this.text, {
    super.key,
    this.style,
    this.maxChars,
    this.align = TextAlign.left,
    this.ellipsis = true,
  });

  final String text;
  final TextStyle? style;
  final int? maxChars;
  final TextAlign align;
  final bool ellipsis;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? TuiTextStyles.normal;
    String displayText = text;

    if (maxChars != null && text.length > maxChars!) {
      if (ellipsis) {
        displayText = '${text.substring(0, maxChars! - 1)}…';
      } else {
        displayText = text.substring(0, maxChars!);
      }
    }

    return Text(
      displayText,
      style: effectiveStyle,
      textAlign: align,
      overflow: TextOverflow.clip,
      maxLines: 1,
    );
  }
}

/// A fixed-width text widget that pads or truncates to exact character count.
class TuiFixedText extends StatelessWidget {
  const TuiFixedText(
    this.text, {
    super.key,
    required this.chars,
    this.style,
    this.align = TextAlign.left,
    this.padChar = ' ',
  });

  final String text;
  final int chars;
  final TextStyle? style;
  final TextAlign align;
  final String padChar;

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? TuiTextStyles.normal;
    String displayText;

    if (text.length > chars) {
      displayText = '${text.substring(0, chars - 1)}…';
    } else if (text.length < chars) {
      switch (align) {
        case TextAlign.right:
        case TextAlign.end:
          displayText = text.padLeft(chars, padChar);
          break;
        case TextAlign.center:
          final totalPad = chars - text.length;
          final leftPad = totalPad ~/ 2;
          final rightPad = totalPad - leftPad;
          displayText = padChar * leftPad + text + padChar * rightPad;
          break;
        default:
          displayText = text.padRight(chars, padChar);
      }
    } else {
      displayText = text;
    }

    return SizedBox(
      width: TuiMetrics.charsToWidth(chars),
      child: Text(
        displayText,
        style: effectiveStyle,
        overflow: TextOverflow.clip,
        maxLines: 1,
      ),
    );
  }
}

/// A text span builder for combining styled text segments.
class TuiTextSpan extends StatelessWidget {
  const TuiTextSpan({
    super.key,
    required this.spans,
    this.maxChars,
  });

  final List<TuiSpan> spans;
  final int? maxChars;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: spans.map((s) => s.toTextSpan()).toList(),
      ),
      overflow: TextOverflow.clip,
      maxLines: 1,
    );
  }
}

/// A single styled text segment.
class TuiSpan {
  const TuiSpan(this.text, {this.style});

  final String text;
  final TextStyle? style;

  TextSpan toTextSpan() => TextSpan(
        text: text,
        style: style ?? TuiTextStyles.normal,
      );
}
