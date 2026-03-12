import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/listening_analytics_service.dart';
import '../services/piano_synth_service.dart';

/// A playable piano keyboard easter egg.
/// Supports touch/click on mobile and desktop keyboard mapping (upiano-style).
class PianoScreen extends StatefulWidget {
  const PianoScreen({super.key});

  @override
  State<PianoScreen> createState() => _PianoScreenState();
}

class _PianoScreenState extends State<PianoScreen> {
  final PianoSynthService _synth = PianoSynthService();
  final FocusNode _focusNode = FocusNode();
  final Set<int> _pressedKeys = {};

  // Current octave base (MIDI note of the leftmost C)
  int _octaveBase = 60; // C4

  // Analytics
  int _notesPlayed = 0;
  late final Stopwatch _sessionTimer;

  bool _initialized = false;

  // Desktop keyboard → MIDI note offset mapping (upiano-style)
  // Lower octave: a w s e d f t g y h u j
  // Upper octave: k o l p ; ' ] \
  static final Map<LogicalKeyboardKey, int> _keyMap = {
    // Lower octave (offsets from _octaveBase)
    LogicalKeyboardKey.keyA: 0,   // C
    LogicalKeyboardKey.keyW: 1,   // C#
    LogicalKeyboardKey.keyS: 2,   // D
    LogicalKeyboardKey.keyE: 3,   // D#
    LogicalKeyboardKey.keyD: 4,   // E
    LogicalKeyboardKey.keyF: 5,   // F
    LogicalKeyboardKey.keyT: 6,   // F#
    LogicalKeyboardKey.keyG: 7,   // G
    LogicalKeyboardKey.keyY: 8,   // G#
    LogicalKeyboardKey.keyH: 9,   // A
    LogicalKeyboardKey.keyU: 10,  // A#
    LogicalKeyboardKey.keyJ: 11,  // B
    // Upper octave
    LogicalKeyboardKey.keyK: 12,  // C
    LogicalKeyboardKey.keyO: 13,  // C#
    LogicalKeyboardKey.keyL: 14,  // D
    LogicalKeyboardKey.keyP: 15,  // D#
    LogicalKeyboardKey.semicolon: 16, // E
    LogicalKeyboardKey.quoteSingle: 17, // F
    LogicalKeyboardKey.bracketRight: 18, // F#
    LogicalKeyboardKey.backslash: 19, // G
  };

  @override
  void initState() {
    super.initState();
    _sessionTimer = Stopwatch()..start();
    _initSynth();
    _markDiscovered();
  }

  Future<void> _initSynth() async {
    await _synth.init();
    // Preload 2 octaves starting at current base
    _synth.preloadRange(_octaveBase, 24);
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
    // Record piano session
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

  void _onNoteOn(int midiNote) {
    if (_pressedKeys.contains(midiNote)) return;
    setState(() => _pressedKeys.add(midiNote));
    _synth.playNote(midiNote);
    _notesPlayed++;
  }

  void _onNoteOff(int midiNote) {
    setState(() => _pressedKeys.remove(midiNote));
  }

  void _handleKeyEvent(KeyEvent event) {
    final offset = _keyMap[event.logicalKey];
    if (offset != null) {
      final midiNote = _octaveBase + offset;
      if (event is KeyDownEvent) {
        _onNoteOn(midiNote);
      } else if (event is KeyUpEvent) {
        _onNoteOff(midiNote);
      }
    }
  }

  void _shiftOctave(int delta) {
    final newBase = _octaveBase + delta * 12;
    if (newBase >= 36 && newBase <= 84) { // C2 to C6
      setState(() {
        _octaveBase = newBase;
        _pressedKeys.clear();
      });
      _synth.preloadRange(_octaveBase, 24);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final octaveName = 'C${_octaveBase ~/ 12 - 1}';

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        title: const Text('Piano'),
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            tooltip: 'Octave down',
            onPressed: _octaveBase > 36 ? () => _shiftOctave(-1) : null,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              octaveName,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'monospace',
                fontSize: 16,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            tooltip: 'Octave up',
            onPressed: _octaveBase < 84 ? () => _shiftOctave(1) : null,
          ),
        ],
      ),
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: !_initialized
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // Keyboard hint
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Use keyboard: A-J (lower) K-\\ (upper) | Click/tap keys',
                      style: TextStyle(
                        color: Colors.white38,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  // Piano keyboard
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: _buildKeyboard(theme),
                    ),
                  ),
                  // Note labels
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Notes played: $_notesPlayed',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildKeyboard(ThemeData theme) {
    // Build 2 octaves (14 white keys)
    return LayoutBuilder(
      builder: (context, constraints) {
        const whiteKeysPerOctave = 7;
        const totalWhiteKeys = whiteKeysPerOctave * 2;
        final whiteKeyWidth = constraints.maxWidth / totalWhiteKeys;
        final blackKeyWidth = whiteKeyWidth * 0.6;
        final blackKeyHeight = constraints.maxHeight * 0.6;

        // White key MIDI offsets within an octave: C D E F G A B → 0,2,4,5,7,9,11
        const whiteOffsets = [0, 2, 4, 5, 7, 9, 11];
        // Black key positions (index among white keys, and MIDI offset)
        // C# between C-D, D# between D-E, F# between F-G, G# between G-A, A# between A-B
        const blackKeys = [
          (whiteIndex: 0, offset: 1),  // C#
          (whiteIndex: 1, offset: 3),  // D#
          (whiteIndex: 3, offset: 6),  // F#
          (whiteIndex: 4, offset: 8),  // G#
          (whiteIndex: 5, offset: 10), // A#
        ];

        final accent = theme.colorScheme.primary;

        return Stack(
          children: [
            // White keys
            Row(
              children: List.generate(totalWhiteKeys, (i) {
                final octave = i ~/ whiteKeysPerOctave;
                final noteInOctave = i % whiteKeysPerOctave;
                final midiNote = _octaveBase + octave * 12 + whiteOffsets[noteInOctave];
                final isPressed = _pressedKeys.contains(midiNote);

                return Expanded(
                  child: GestureDetector(
                    onTapDown: (_) => _onNoteOn(midiNote),
                    onTapUp: (_) => _onNoteOff(midiNote),
                    onTapCancel: () => _onNoteOff(midiNote),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: isPressed
                            ? accent.withValues(alpha: 0.3)
                            : Colors.white,
                        borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(6),
                        ),
                        border: Border.all(
                          color: isPressed ? accent : Colors.grey.shade400,
                          width: isPressed ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _noteNames[whiteOffsets[noteInOctave]]!,
                        style: TextStyle(
                          color: isPressed ? accent : Colors.grey.shade600,
                          fontSize: 11,
                          fontWeight: isPressed ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            // Black keys
            for (int octave = 0; octave < 2; octave++)
              for (final bk in blackKeys)
                Positioned(
                  left: (octave * whiteKeysPerOctave + bk.whiteIndex) * whiteKeyWidth +
                      whiteKeyWidth - blackKeyWidth / 2,
                  top: 0,
                  width: blackKeyWidth,
                  height: blackKeyHeight,
                  child: Builder(
                    builder: (context) {
                      final midiNote = _octaveBase + octave * 12 + bk.offset;
                      final isPressed = _pressedKeys.contains(midiNote);

                      return GestureDetector(
                        onTapDown: (_) => _onNoteOn(midiNote),
                        onTapUp: (_) => _onNoteOff(midiNote),
                        onTapCancel: () => _onNoteOff(midiNote),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isPressed ? accent : Colors.black,
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(4),
                            ),
                            border: Border.all(
                              color: isPressed
                                  ? accent
                                  : Colors.grey.shade800,
                              width: isPressed ? 2 : 1,
                            ),
                            boxShadow: isPressed
                                ? null
                                : const [
                                    BoxShadow(
                                      color: Colors.black54,
                                      blurRadius: 3,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
          ],
        );
      },
    );
  }

  static const Map<int, String> _noteNames = {
    0: 'C',
    1: 'C#',
    2: 'D',
    3: 'D#',
    4: 'E',
    5: 'F',
    6: 'F#',
    7: 'G',
    8: 'G#',
    9: 'A',
    10: 'A#',
    11: 'B',
  };
}
