import 'package:flutter/material.dart';

import '../tui_theme.dart';

/// An ASCII-style progress bar widget.
/// Renders as: [=========>          ] 2:34 / 4:12
class TuiProgressBar extends StatelessWidget {
  const TuiProgressBar({
    super.key,
    required this.position,
    required this.duration,
    this.width = 30,
    this.showTime = true,
  });

  final Duration position;
  final Duration duration;
  final int width;
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Calculate bar segments
    final innerWidth = width - 2; // Subtract brackets
    final filledCount = (progress * innerWidth).floor();
    final hasHead = filledCount < innerWidth;

    final filled = TuiChars.progressFilled * filledCount;
    final head = hasHead ? TuiChars.progressHead : '';
    final empty = TuiChars.progressEmpty * (innerWidth - filledCount - (hasHead ? 1 : 0));

    final bar =
        '${TuiChars.progressLeft}$filled$head$empty${TuiChars.progressRight}';

    if (!showTime) {
      return Text(bar, style: TuiTextStyles.normal);
    }

    final posStr = _formatDuration(position);
    final durStr = _formatDuration(duration);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(bar, style: TuiTextStyles.accent),
        const SizedBox(width: 8),
        Text('$posStr / $durStr', style: TuiTextStyles.dim),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString()}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString()}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// A simple volume bar indicator.
/// Renders as: Vol: [████████░░] 80%
class TuiVolumeBar extends StatelessWidget {
  const TuiVolumeBar({
    super.key,
    required this.volume,
    this.width = 10,
    this.showLabel = true,
  });

  final double volume;
  final int width;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final filled = (volume * width).round();
    final empty = width - filled;

    final filledChar = '█';
    final emptyChar = '░';

    final bar = filledChar * filled + emptyChar * empty;
    final percent = (volume * 100).round();

    if (!showLabel) {
      return Text('[$bar]', style: TuiTextStyles.normal);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Vol: ', style: TuiTextStyles.dim),
        Text('[$bar]', style: TuiTextStyles.accent),
        Text(' $percent%', style: TuiTextStyles.dim),
      ],
    );
  }
}
