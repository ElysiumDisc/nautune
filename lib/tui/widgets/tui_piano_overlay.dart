import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/listening_analytics_service.dart';
import '../../services/piano_synth_service.dart';
import '../tui_theme.dart';

/// ASCII piano overlay for TUI mode.
/// Full-screen overlay with box-drawing art and key highlighting.
class TuiPianoOverlay extends StatefulWidget {
  const TuiPianoOverlay({
    super.key,
    required this.onDismiss,
  });

  final VoidCallback onDismiss;

  @override
  State<TuiPianoOverlay> createState() => _TuiPianoOverlayState();
}

class _TuiPianoOverlayState extends State<TuiPianoOverlay> {
  final PianoSynthService _synth = PianoSynthService();
  final FocusNode _focusNode = FocusNode();
  final Set<int> _pressedKeys = {};

  int _octaveBase = 60; // C4
  int _notesPlayed = 0;
  late final Stopwatch _sessionTimer;
  bool _initialized = false;

  // Key map: same upiano-style layout as GUI
  static final Map<LogicalKeyboardKey, int> _keyMap = {
    LogicalKeyboardKey.keyA: 0,
    LogicalKeyboardKey.keyW: 1,
    LogicalKeyboardKey.keyS: 2,
    LogicalKeyboardKey.keyE: 3,
    LogicalKeyboardKey.keyD: 4,
    LogicalKeyboardKey.keyF: 5,
    LogicalKeyboardKey.keyT: 6,
    LogicalKeyboardKey.keyG: 7,
    LogicalKeyboardKey.keyY: 8,
    LogicalKeyboardKey.keyH: 9,
    LogicalKeyboardKey.keyU: 10,
    LogicalKeyboardKey.keyJ: 11,
    LogicalKeyboardKey.keyK: 12,
    LogicalKeyboardKey.keyO: 13,
    LogicalKeyboardKey.keyL: 14,
    LogicalKeyboardKey.keyP: 15,
    LogicalKeyboardKey.semicolon: 16,
    LogicalKeyboardKey.quoteSingle: 17,
    LogicalKeyboardKey.bracketRight: 18,
    LogicalKeyboardKey.backslash: 19,
  };

  // Display labels for keys
  static const List<String> _whiteLabels = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'", '\\'];
  static const List<String> _blackLabels = ['W', 'E', '', 'T', 'Y', 'U', '', 'O', 'P', '', ']', ''];
  static const List<String> _noteLabels = ['C', 'D', 'E', 'F', 'G', 'A', 'B', 'C', 'D', 'E', 'F', 'G'];

  @override
  void initState() {
    super.initState();
    _sessionTimer = Stopwatch()..start();
    _initSynth();
    _markDiscovered();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  Future<void> _initSynth() async {
    await _synth.init();
    await _synth.preloadRange(_octaveBase, 24);
    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  void _markDiscovered() {
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized) {
      analytics.markPianoDiscovered();
    }
  }

  @override
  void dispose() {
    _sessionTimer.stop();
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized && _notesPlayed > 0) {
      analytics.recordPianoSession(
        notesPlayed: _notesPlayed,
        sessionDuration: _sessionTimer.elapsed,
      );
    }
    _synth.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onDismiss();
        return;
      }
      // Octave shift with < / >  (comma/period without shift since those are mapped in TUI)
      if (event.logicalKey == LogicalKeyboardKey.comma) {
        _shiftOctave(-1);
        return;
      }
      if (event.logicalKey == LogicalKeyboardKey.period) {
        _shiftOctave(1);
        return;
      }
    }

    final offset = _keyMap[event.logicalKey];
    if (offset != null) {
      final midiNote = _octaveBase + offset;
      if (event is KeyDownEvent) {
        if (!_pressedKeys.contains(midiNote)) {
          setState(() => _pressedKeys.add(midiNote));
          _synth.playNote(midiNote);
          _notesPlayed++;
        }
      } else if (event is KeyUpEvent) {
        setState(() => _pressedKeys.remove(midiNote));
      }
    }
  }

  void _shiftOctave(int delta) {
    final newBase = _octaveBase + delta * 12;
    if (newBase >= 36 && newBase <= 84) {
      setState(() {
        _octaveBase = newBase;
        _pressedKeys.clear();
      });
      _synth.preloadRange(_octaveBase, 24);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TuiColors.background.withValues(alpha: 0.95),
      child: KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              if (!_initialized)
                Center(child: Text('Loading...', style: TuiTextStyles.dim))
              else ...[
                _buildOctaveInfo(),
                const SizedBox(height: 16),
                _buildAsciiPiano(),
                const SizedBox(height: 16),
                _buildKeyMappingHelp(),
              ],
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'Esc to close  |  ,/. to shift octave  |  Notes: $_notesPlayed',
                  style: TuiTextStyles.dim,
                ),
              ),
            ],
          ),
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
        Text('Piano', style: TuiTextStyles.title.copyWith(color: TuiColors.accent)),
        Text(
          ' ${TuiChars.horizontalDouble * 58}${TuiChars.topRightDouble}',
          style: TuiTextStyles.accent,
        ),
      ],
    );
  }

  Widget _buildOctaveInfo() {
    final octaveName = 'C${_octaveBase ~/ 12 - 1}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('< ', style: _octaveBase > 36 ? TuiTextStyles.accent : TuiTextStyles.dim),
        Text('Octave: $octaveName ', style: TuiTextStyles.normal),
        Text('>', style: _octaveBase < 84 ? TuiTextStyles.accent : TuiTextStyles.dim),
      ],
    );
  }

  Widget _buildAsciiPiano() {
    // Which offsets within an octave are "black" keys
    const blackOffsets = {1, 3, 6, 8, 10};
    // White key MIDI offsets: 0,2,4,5,7,9,11 (per octave)
    const whiteOffsets = [0, 2, 4, 5, 7, 9, 11];

    // Build the ASCII art lines
    // Top border
    final topLine = StringBuffer('  ${TuiChars.topLeft}');
    for (int i = 0; i < 12; i++) {
      topLine.write('${TuiChars.horizontal * 5}${i < 11 ? TuiChars.teeTop : TuiChars.topRight}');
    }

    // Black key row
    final blackLine = StringBuffer('  ${TuiChars.vertical}');
    for (int i = 0; i < 12; i++) {
      final octave = i < 7 ? 0 : 1;
      final noteIdx = i < 7 ? i : i - 7;
      final midiOffset = whiteOffsets[noteIdx < whiteOffsets.length ? noteIdx : 0];
      // Check adjacent black keys
      final blackLabel = _blackLabels[i];
      if (blackLabel.isNotEmpty) {
        final bMidi = _octaveBase + (octave * 12) + (blackOffsets.contains(midiOffset + 1) ? midiOffset + 1 : midiOffset);
        final isPressed = _pressedKeys.contains(bMidi);
        if (isPressed) {
          blackLine.write(' [$blackLabel] ${TuiChars.vertical}');
        } else {
          blackLine.write('  $blackLabel  ${TuiChars.vertical}');
        }
      } else {
        blackLine.write('     ${TuiChars.vertical}');
      }
    }

    // White key label row
    final whiteLine = StringBuffer('  ${TuiChars.vertical}');
    for (int i = 0; i < 12; i++) {
      final octave = i < 7 ? 0 : 1;
      final noteInOctave = i < 7 ? i : i - 7;
      final midiNote = _octaveBase + octave * 12 + whiteOffsets[noteInOctave < whiteOffsets.length ? noteInOctave : 0];
      final isPressed = _pressedKeys.contains(midiNote);
      final label = _whiteLabels[i];
      if (isPressed) {
        whiteLine.write(' [$label] ${TuiChars.vertical}');
      } else {
        whiteLine.write('  $label  ${TuiChars.vertical}');
      }
    }

    // Note name row
    final noteLine = StringBuffer('  ${TuiChars.vertical}');
    for (int i = 0; i < 12; i++) {
      final note = _noteLabels[i];
      noteLine.write('  $note  ${TuiChars.vertical}');
    }

    // Bottom border
    final bottomLine = StringBuffer('  ${TuiChars.bottomLeft}');
    for (int i = 0; i < 12; i++) {
      bottomLine.write('${TuiChars.horizontal * 5}${i < 11 ? TuiChars.teeBottom : TuiChars.bottomRight}');
    }

    // Build colored text spans
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPianoLine(topLine.toString(), {}),
        _buildPianoLineWithHighlights(1),
        _buildPianoLineWithHighlights(2),
        _buildPianoLine(noteLine.toString(), {}),
        _buildPianoLine(bottomLine.toString(), {}),
      ],
    );
  }

  Widget _buildPianoLine(String text, Set<int> highlightPositions) {
    return Text(text, style: TuiTextStyles.normal);
  }

  Widget _buildPianoLineWithHighlights(int row) {
    // Simplified rendering - build spans with highlights for pressed keys
    const whiteOffsets = [0, 2, 4, 5, 7, 9, 11];

    final spans = <TextSpan>[];
    spans.add(TextSpan(text: '  ${TuiChars.vertical}', style: TuiTextStyles.normal));

    for (int i = 0; i < 12; i++) {
      final octave = i < 7 ? 0 : 1;
      final noteInOctave = i < 7 ? i : i - 7;

      if (row == 1) {
        // Black key labels row
        final label = i < _blackLabels.length ? _blackLabels[i] : '';
        if (label.isNotEmpty) {
          // Find actual MIDI note for this black key
          final whiteBase = whiteOffsets[noteInOctave < whiteOffsets.length ? noteInOctave : 0];
          final blackMidi = _octaveBase + octave * 12 + whiteBase + 1;
          final isPressed = _pressedKeys.contains(blackMidi);
          if (isPressed) {
            spans.add(TextSpan(
              text: ' [$label] ',
              style: TuiTextStyles.normal.copyWith(
                color: TuiColors.accent,
                fontWeight: FontWeight.bold,
              ),
            ));
          } else {
            spans.add(TextSpan(text: '  $label  ', style: TuiTextStyles.dim));
          }
        } else {
          spans.add(TextSpan(text: '     ', style: TuiTextStyles.normal));
        }
      } else {
        // White key labels row
        final whiteBase = whiteOffsets[noteInOctave < whiteOffsets.length ? noteInOctave : 0];
        final midiNote = _octaveBase + octave * 12 + whiteBase;
        final isPressed = _pressedKeys.contains(midiNote);
        final label = i < _whiteLabels.length ? _whiteLabels[i] : ' ';
        if (isPressed) {
          spans.add(TextSpan(
            text: ' [$label] ',
            style: TuiTextStyles.normal.copyWith(
              color: TuiColors.accent,
              fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          spans.add(TextSpan(text: '  $label  ', style: TuiTextStyles.normal));
        }
      }

      spans.add(TextSpan(text: TuiChars.vertical, style: TuiTextStyles.normal));
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildKeyMappingHelp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '[ Key Mapping ]',
          style: TuiTextStyles.bold.copyWith(color: TuiColors.accent),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 200,
              child: Text('Lower: A W S E D F T G Y H U J', style: TuiTextStyles.dim),
            ),
            Text('C C# D D# E F F# G G# A A# B', style: TuiTextStyles.normal),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            SizedBox(
              width: 200,
              child: Text("Upper: K O L P ; ' ] \\", style: TuiTextStyles.dim),
            ),
            Text("C C# D D# E F F# G", style: TuiTextStyles.normal),
          ],
        ),
      ],
    );
  }
}
