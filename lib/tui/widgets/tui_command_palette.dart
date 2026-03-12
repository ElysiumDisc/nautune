import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tui_keybindings.dart';
import '../tui_theme.dart';

/// A command entry in the command palette.
class TuiCommand {
  const TuiCommand({
    required this.name,
    required this.description,
    this.shortcut,
    required this.action,
    this.category = '',
  });

  final String name;
  final String description;
  final String? shortcut;
  final TuiAction action;
  final String category;
}

/// Fuzzy-searchable command palette overlay (Ctrl+K).
/// Inspired by VS Code command palette.
class TuiCommandPalette extends StatefulWidget {
  const TuiCommandPalette({
    super.key,
    required this.onAction,
    required this.onDismiss,
  });

  final void Function(TuiAction action) onAction;
  final VoidCallback onDismiss;

  @override
  State<TuiCommandPalette> createState() => _TuiCommandPaletteState();
}

class _TuiCommandPaletteState extends State<TuiCommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  int _selectedIndex = 0;
  List<TuiCommand> _filteredCommands = [];

  static const List<TuiCommand> _allCommands = [
    // Playback
    TuiCommand(
      name: 'Play / Pause',
      description: 'Toggle playback',
      shortcut: 'Space',
      action: TuiAction.playPause,
      category: 'Playback',
    ),
    TuiCommand(
      name: 'Next Track',
      description: 'Skip to next track in queue',
      shortcut: 'n',
      action: TuiAction.nextTrack,
      category: 'Playback',
    ),
    TuiCommand(
      name: 'Previous Track',
      description: 'Go to previous track',
      shortcut: 'p',
      action: TuiAction.previousTrack,
      category: 'Playback',
    ),
    TuiCommand(
      name: 'Stop',
      description: 'Stop playback',
      shortcut: 'S',
      action: TuiAction.stop,
      category: 'Playback',
    ),
    TuiCommand(
      name: 'Toggle Shuffle',
      description: 'Shuffle the current queue',
      shortcut: 's',
      action: TuiAction.toggleShuffle,
      category: 'Playback',
    ),
    TuiCommand(
      name: 'Toggle Repeat',
      description: 'Cycle repeat mode (off → all → one)',
      shortcut: 'R',
      action: TuiAction.toggleRepeat,
      category: 'Playback',
    ),

    // Seek
    TuiCommand(
      name: 'Seek Forward',
      description: 'Skip forward 5 seconds',
      shortcut: 't / →',
      action: TuiAction.seekForward,
      category: 'Seek',
    ),
    TuiCommand(
      name: 'Seek Backward',
      description: 'Skip backward 5 seconds',
      shortcut: 'r / ←',
      action: TuiAction.seekBackward,
      category: 'Seek',
    ),
    TuiCommand(
      name: 'Seek Forward (Large)',
      description: 'Skip forward 60 seconds',
      shortcut: '.',
      action: TuiAction.seekForwardLarge,
      category: 'Seek',
    ),
    TuiCommand(
      name: 'Seek Backward (Large)',
      description: 'Skip backward 60 seconds',
      shortcut: ',',
      action: TuiAction.seekBackwardLarge,
      category: 'Seek',
    ),

    // Volume
    TuiCommand(
      name: 'Volume Up',
      description: 'Increase volume by 5%',
      shortcut: '+ / =',
      action: TuiAction.volumeUp,
      category: 'Volume',
    ),
    TuiCommand(
      name: 'Volume Down',
      description: 'Decrease volume by 5%',
      shortcut: '-',
      action: TuiAction.volumeDown,
      category: 'Volume',
    ),
    TuiCommand(
      name: 'Toggle Mute',
      description: 'Mute or unmute audio',
      shortcut: 'm',
      action: TuiAction.toggleMute,
      category: 'Volume',
    ),

    // Navigation
    TuiCommand(
      name: 'Search',
      description: 'Search tracks in your library',
      shortcut: '/',
      action: TuiAction.search,
      category: 'Navigation',
    ),
    TuiCommand(
      name: 'Go to Top',
      description: 'Jump to first item in list',
      shortcut: 'gg / Home',
      action: TuiAction.goToTop,
      category: 'Navigation',
    ),
    TuiCommand(
      name: 'Go to Bottom',
      description: 'Jump to last item in list',
      shortcut: 'G / End',
      action: TuiAction.goToBottom,
      category: 'Navigation',
    ),
    TuiCommand(
      name: 'Cycle Section',
      description: 'Switch to next sidebar section',
      shortcut: 'Tab',
      action: TuiAction.cycleSection,
      category: 'Navigation',
    ),
    TuiCommand(
      name: 'Jump Next Letter',
      description: 'Jump to next alphabetic group',
      shortcut: 'a',
      action: TuiAction.jumpNextLetter,
      category: 'Navigation',
    ),
    TuiCommand(
      name: 'Jump Previous Letter',
      description: 'Jump to previous alphabetic group',
      shortcut: 'A',
      action: TuiAction.jumpPrevLetter,
      category: 'Navigation',
    ),

    // Queue
    TuiCommand(
      name: 'Add to Queue',
      description: 'Add selected track to queue',
      shortcut: 'e',
      action: TuiAction.addToQueue,
      category: 'Queue',
    ),
    TuiCommand(
      name: 'Clear Queue',
      description: 'Remove all tracks from queue',
      shortcut: 'E',
      action: TuiAction.clearQueue,
      category: 'Queue',
    ),
    TuiCommand(
      name: 'Delete from Queue',
      description: 'Remove selected track from queue',
      shortcut: 'x / d',
      action: TuiAction.deleteFromQueue,
      category: 'Queue',
    ),
    TuiCommand(
      name: 'Move Queue Item Up',
      description: 'Move selected queue item up',
      shortcut: 'K',
      action: TuiAction.moveQueueUp,
      category: 'Queue',
    ),
    TuiCommand(
      name: 'Move Queue Item Down',
      description: 'Move selected queue item down',
      shortcut: 'J',
      action: TuiAction.moveQueueDown,
      category: 'Queue',
    ),

    // A-B Loop
    TuiCommand(
      name: 'Set Loop Start (A)',
      description: 'Mark the start of an A-B loop',
      shortcut: '[',
      action: TuiAction.setLoopStart,
      category: 'Loop',
    ),
    TuiCommand(
      name: 'Set Loop End (B)',
      description: 'Mark the end of an A-B loop',
      shortcut: ']',
      action: TuiAction.setLoopEnd,
      category: 'Loop',
    ),
    TuiCommand(
      name: 'Clear Loop',
      description: 'Remove A-B loop markers',
      shortcut: r'\',
      action: TuiAction.clearLoop,
      category: 'Loop',
    ),

    // Other
    TuiCommand(
      name: 'Toggle Favorite',
      description: 'Mark/unmark current track as favorite',
      shortcut: 'f',
      action: TuiAction.toggleFavorite,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Cycle Theme',
      description: 'Switch to the next color theme',
      shortcut: 'T',
      action: TuiAction.cycleTheme,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Toggle Visualizer',
      description: 'Show or hide the spectrum visualizer',
      shortcut: 'v',
      action: TuiAction.toggleVisualizer,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Show Help',
      description: 'Display keybinding reference',
      shortcut: '?',
      action: TuiAction.toggleHelp,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Full Reset',
      description: 'Stop playback and clear queue',
      shortcut: 'X',
      action: TuiAction.fullReset,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Piano',
      description: 'Open the hidden piano keyboard',
      shortcut: 'P',
      action: TuiAction.togglePiano,
      category: 'Other',
    ),
    TuiCommand(
      name: 'Quit',
      description: 'Exit Nautune TUI',
      shortcut: 'q',
      action: TuiAction.quit,
      category: 'Other',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _filteredCommands = List.of(_allCommands);
    _controller.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final query = _controller.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredCommands = List.of(_allCommands);
      } else {
        _filteredCommands = _allCommands.where((cmd) {
          return _fuzzyMatch(cmd.name.toLowerCase(), query) ||
              _fuzzyMatch(cmd.description.toLowerCase(), query) ||
              _fuzzyMatch(cmd.category.toLowerCase(), query) ||
              (cmd.shortcut != null && cmd.shortcut!.toLowerCase().contains(query));
        }).toList();

        // Sort by match quality
        _filteredCommands.sort((a, b) {
          final aNameMatch = a.name.toLowerCase().startsWith(query) ? 0 : 1;
          final bNameMatch = b.name.toLowerCase().startsWith(query) ? 0 : 1;
          if (aNameMatch != bNameMatch) return aNameMatch.compareTo(bNameMatch);

          final aContains = a.name.toLowerCase().contains(query) ? 0 : 1;
          final bContains = b.name.toLowerCase().contains(query) ? 0 : 1;
          return aContains.compareTo(bContains);
        });
      }
      _selectedIndex = 0;
    });
  }

  /// Simple fuzzy match: all query characters appear in order in the target.
  bool _fuzzyMatch(String target, String query) {
    var ti = 0;
    for (var qi = 0; qi < query.length; qi++) {
      final found = target.indexOf(query[qi], ti);
      if (found < 0) return false;
      ti = found + 1;
    }
    return true;
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedIndex = (_selectedIndex - 1).clamp(0, _filteredCommands.length - 1);
      });
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedIndex = (_selectedIndex + 1).clamp(0, _filteredCommands.length - 1);
      });
      return;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (_filteredCommands.isNotEmpty) {
        final cmd = _filteredCommands[_selectedIndex];
        widget.onDismiss();
        widget.onAction(cmd.action);
      }
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TuiColors.background.withValues(alpha: 0.95),
      child: KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: _handleKey,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    '${TuiChars.topLeftDouble}${TuiChars.horizontalDouble * 3} ',
                    style: TuiTextStyles.accent,
                  ),
                  Text(
                    'Command Palette',
                    style: TuiTextStyles.title.copyWith(color: TuiColors.accent),
                  ),
                  Text(
                    ' ${TuiChars.horizontalDouble * 50}${TuiChars.topRightDouble}',
                    style: TuiTextStyles.accent,
                  ),
                ],
              ),
            ),

            // Search input
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: TuiColors.border),
              ),
              child: Row(
                children: [
                  Text('> ', style: TuiTextStyles.accent),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      style: TuiTextStyles.normal,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Type to search commands...',
                        hintStyle: TuiTextStyles.dim,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      cursorColor: TuiColors.accent,
                    ),
                  ),
                  Text(
                    '${_filteredCommands.length}/${_allCommands.length}',
                    style: TuiTextStyles.dim,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // Command list
            Expanded(
              child: _filteredCommands.isEmpty
                  ? Center(
                      child: Text('No matching commands', style: TuiTextStyles.dim),
                    )
                  : ListView.builder(
                      itemCount: _filteredCommands.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemBuilder: (context, index) {
                        final cmd = _filteredCommands[index];
                        final isSelected = index == _selectedIndex;

                        // Category header
                        Widget? categoryHeader;
                        if (index == 0 ||
                            _filteredCommands[index - 1].category != cmd.category) {
                          categoryHeader = Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 4),
                            child: Text(
                              '[ ${cmd.category} ]',
                              style: TuiTextStyles.bold.copyWith(
                                color: TuiColors.accent,
                                fontSize: 12,
                              ),
                            ),
                          );
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ?categoryHeader,
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              color: isSelected
                                  ? TuiColors.selection
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  Text(
                                    isSelected ? '${TuiChars.cursor} ' : '  ',
                                    style: isSelected
                                        ? TuiTextStyles.selection
                                        : TuiTextStyles.normal,
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          cmd.name,
                                          style: isSelected
                                              ? TuiTextStyles.selection
                                              : TuiTextStyles.normal,
                                        ),
                                        Text(
                                          cmd.description,
                                          style: isSelected
                                              ? TuiTextStyles.selection
                                                  .copyWith(
                                                  fontWeight: FontWeight.normal,
                                                )
                                              : TuiTextStyles.dim,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (cmd.shortcut != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: isSelected
                                              ? TuiColors.selectionText
                                              : TuiColors.border,
                                        ),
                                      ),
                                      child: Text(
                                        cmd.shortcut!,
                                        style: isSelected
                                            ? TuiTextStyles.selection.copyWith(
                                                fontSize: 12,
                                              )
                                            : TuiTextStyles.dim.copyWith(
                                                fontSize: 12,
                                              ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _footerHint('↑↓', 'navigate'),
                  const SizedBox(width: 16),
                  _footerHint('Enter', 'execute'),
                  const SizedBox(width: 16),
                  _footerHint('Esc', 'dismiss'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footerHint(String key, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: TuiColors.border),
          ),
          child: Text(key, style: TuiTextStyles.accent.copyWith(fontSize: 12)),
        ),
        const SizedBox(width: 4),
        Text(label, style: TuiTextStyles.dim.copyWith(fontSize: 12)),
      ],
    );
  }
}
