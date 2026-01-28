import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Result of a key binding match.
enum TuiAction {
  none,
  moveUp,
  moveDown,
  moveLeft,
  moveRight,
  goToTop,
  goToBottom,
  select,
  playPause,
  nextTrack,
  previousTrack,
  volumeUp,
  volumeDown,
  search,
  quit,
  escape,
  pageUp,
  pageDown,
  toggleMute,
  toggleShuffle,
  toggleRepeat,
  stop,
  clearQueue,
  deleteFromQueue,
}

/// Vim-style key binding handler with multi-key sequence support.
/// Handles sequences like 'gg' with a timeout state machine.
class TuiKeyBindings extends ChangeNotifier {
  TuiKeyBindings() {
    _resetSequence();
  }

  String _pendingSequence = '';
  Timer? _sequenceTimer;
  static const Duration _sequenceTimeout = Duration(milliseconds: 500);

  /// Current pending key sequence (for display).
  String get pendingSequence => _pendingSequence;

  /// Process a key event and return the resulting action.
  TuiAction handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return TuiAction.none;
    }

    final key = event.logicalKey;
    final char = event.character;

    // Handle special keys first
    if (key == LogicalKeyboardKey.escape) {
      _resetSequence();
      return TuiAction.escape;
    }

    if (key == LogicalKeyboardKey.enter) {
      _resetSequence();
      return TuiAction.select;
    }

    if (key == LogicalKeyboardKey.space) {
      _resetSequence();
      return TuiAction.playPause;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      _resetSequence();
      return TuiAction.moveUp;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      _resetSequence();
      return TuiAction.moveDown;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      _resetSequence();
      return TuiAction.moveLeft;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      _resetSequence();
      return TuiAction.moveRight;
    }

    if (key == LogicalKeyboardKey.pageUp) {
      _resetSequence();
      return TuiAction.pageUp;
    }

    if (key == LogicalKeyboardKey.pageDown) {
      _resetSequence();
      return TuiAction.pageDown;
    }

    if (key == LogicalKeyboardKey.home) {
      _resetSequence();
      return TuiAction.goToTop;
    }

    if (key == LogicalKeyboardKey.end) {
      _resetSequence();
      return TuiAction.goToBottom;
    }

    // Handle character keys for vim bindings
    if (char != null && char.isNotEmpty) {
      return _handleCharacter(char);
    }

    return TuiAction.none;
  }

  TuiAction _handleCharacter(String char) {
    // Add to pending sequence
    _pendingSequence += char;
    _startSequenceTimer();
    notifyListeners();

    // Check for complete sequences
    final action = _matchSequence(_pendingSequence);
    if (action != TuiAction.none) {
      _resetSequence();
      return action;
    }

    // Check if this could be the start of a longer sequence
    if (_isPotentialPrefix(_pendingSequence)) {
      return TuiAction.none; // Wait for more input
    }

    // No match possible, reset and try single char
    _resetSequence();
    return _matchSequence(char);
  }

  TuiAction _matchSequence(String sequence) {
    switch (sequence) {
      // Movement
      case 'j':
        return TuiAction.moveDown;
      case 'k':
        return TuiAction.moveUp;
      case 'h':
        return TuiAction.moveLeft;
      case 'l':
        return TuiAction.moveRight;

      // Multi-key sequences
      case 'gg':
        return TuiAction.goToTop;
      case 'G':
        return TuiAction.goToBottom;

      // Playback controls
      case 'n':
        return TuiAction.nextTrack;
      case 'p':
        return TuiAction.previousTrack;

      // Volume
      case '+':
      case '=':
        return TuiAction.volumeUp;
      case '-':
        return TuiAction.volumeDown;
      case 'm':
        return TuiAction.toggleMute;

      // Search
      case '/':
        return TuiAction.search;

      // Quit
      case 'q':
        return TuiAction.quit;

      // Shuffle and repeat
      case 's':
        return TuiAction.toggleShuffle;
      case 'r':
        return TuiAction.toggleRepeat;

      // Stop and queue management
      case 'S':
        return TuiAction.stop;
      case 'c':
        return TuiAction.clearQueue;
      case 'x':
      case 'd':
        return TuiAction.deleteFromQueue;

      default:
        return TuiAction.none;
    }
  }

  bool _isPotentialPrefix(String sequence) {
    // Check if this could be the start of 'gg'
    return sequence == 'g';
  }

  void _startSequenceTimer() {
    _sequenceTimer?.cancel();
    _sequenceTimer = Timer(_sequenceTimeout, () {
      if (_pendingSequence.isNotEmpty) {
        // Timeout - try to match what we have
        final action = _matchSequence(_pendingSequence);
        _resetSequence();
        if (action != TuiAction.none) {
          // Need to notify somehow - for now just log
          debugPrint('TUI: Sequence timeout, action: $action');
        }
      }
    });
  }

  void _resetSequence() {
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _pendingSequence = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _sequenceTimer?.cancel();
    super.dispose();
  }
}
