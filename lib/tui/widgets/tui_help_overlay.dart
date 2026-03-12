import 'package:flutter/material.dart';

import '../tui_theme.dart';

/// Help overlay showing all available keybindings.
/// Toggle with `?` key. Press any key to dismiss.
class TuiHelpOverlay extends StatelessWidget {
  const TuiHelpOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TuiColors.background.withValues(alpha: 0.95),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSection('Navigation', _navigationBindings),
                      const SizedBox(height: 16),
                      _buildSection('Playback', _playbackBindings),
                      const SizedBox(height: 16),
                      _buildSection('Volume', _volumeBindings),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSection('Queue', _queueBindings),
                      const SizedBox(height: 16),
                      _buildSection('Seek', _seekBindings),
                      const SizedBox(height: 16),
                      _buildSection('A-B Loop', _loopBindings),
                      const SizedBox(height: 16),
                      _buildSection('Other', _otherBindings),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                'Press any key to dismiss',
                style: TuiTextStyles.dim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          '${TuiChars.topLeftDouble}${TuiChars.horizontalDouble * 3} ',
          style: TuiTextStyles.accent,
        ),
        Text('Help', style: TuiTextStyles.title.copyWith(color: TuiColors.accent)),
        Text(
          ' ${TuiChars.horizontalDouble * 60}${TuiChars.topRightDouble}',
          style: TuiTextStyles.accent,
        ),
      ],
    );
  }

  Widget _buildSection(String title, List<_KeyBinding> bindings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '[ $title ]',
          style: TuiTextStyles.bold.copyWith(color: TuiColors.accent),
        ),
        const SizedBox(height: 8),
        for (final binding in bindings) _buildBinding(binding),
      ],
    );
  }

  Widget _buildBinding(_KeyBinding binding) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              binding.keys,
              style: TuiTextStyles.normal.copyWith(color: TuiColors.primary),
            ),
          ),
          Expanded(
            child: Text(
              binding.description,
              style: TuiTextStyles.dim,
            ),
          ),
        ],
      ),
    );
  }

  static const List<_KeyBinding> _navigationBindings = [
    _KeyBinding('j / Down', 'Move cursor down'),
    _KeyBinding('k / Up', 'Move cursor up'),
    _KeyBinding('h / Left', 'Go back / focus sidebar'),
    _KeyBinding('l / Right', 'Select / focus content'),
    _KeyBinding('Enter', 'Select item'),
    _KeyBinding('gg / Home', 'Go to top'),
    _KeyBinding('G / End', 'Go to bottom'),
    _KeyBinding('PgUp / PgDn', 'Page up / down'),
    _KeyBinding('a / A', 'Jump to next/prev letter'),
    _KeyBinding('Tab', 'Cycle through sections'),
    _KeyBinding('Esc', 'Go back'),
  ];

  static const List<_KeyBinding> _playbackBindings = [
    _KeyBinding('Space', 'Play / Pause'),
    _KeyBinding('n', 'Next track'),
    _KeyBinding('p', 'Previous track'),
    _KeyBinding('S', 'Stop playback'),
    _KeyBinding('s', 'Toggle shuffle'),
    _KeyBinding('R', 'Toggle repeat mode'),
  ];

  static const List<_KeyBinding> _volumeBindings = [
    _KeyBinding('+ / =', 'Volume up'),
    _KeyBinding('-', 'Volume down'),
    _KeyBinding('m', 'Toggle mute'),
  ];

  static const List<_KeyBinding> _queueBindings = [
    _KeyBinding('e', 'Add to queue'),
    _KeyBinding('E', 'Clear queue'),
    _KeyBinding('x / d', 'Delete from queue'),
    _KeyBinding('J', 'Move queue item down'),
    _KeyBinding('K', 'Move queue item up'),
  ];

  static const List<_KeyBinding> _seekBindings = [
    _KeyBinding('r / t', 'Seek -5s / +5s'),
    _KeyBinding(', / .', 'Seek -60s / +60s'),
  ];

  static const List<_KeyBinding> _loopBindings = [
    _KeyBinding('[', 'Set loop start (A)'),
    _KeyBinding(']', 'Set loop end (B)'),
    _KeyBinding(r'\', 'Clear loop markers'),
  ];

  static const List<_KeyBinding> _otherBindings = [
    _KeyBinding('/', 'Search'),
    _KeyBinding('f', 'Toggle favorite'),
    _KeyBinding('v', 'Toggle spectrum visualizer'),
    _KeyBinding('T', 'Cycle theme'),
    _KeyBinding('Ctrl+K', 'Command palette'),
    _KeyBinding('?', 'Show/hide help'),
    _KeyBinding('P', 'Open Piano'),
    _KeyBinding('X', 'Full reset (stop + clear)'),
    _KeyBinding('q', 'Quit'),
    _KeyBinding('Drag tab bar', 'Move window'),
  ];
}

class _KeyBinding {
  const _KeyBinding(this.keys, this.description);

  final String keys;
  final String description;
}
