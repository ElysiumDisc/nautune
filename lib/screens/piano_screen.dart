import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/listening_analytics_service.dart';
import '../services/piano_synth_service.dart';

/// A playable piano keyboard easter egg.
/// Supports touch plus hardware-keyboard mapping (upiano-style) on iPad.
class PianoScreen extends StatefulWidget {
  const PianoScreen({super.key});

  @override
  State<PianoScreen> createState() => _PianoScreenState();
}

class _PianoScreenState extends State<PianoScreen> {
  final PianoSynthService _synth = PianoSynthService();
  final FocusNode _focusNode = FocusNode();
  final Set<int> _pressedKeys = {};

  /// Touch pointer → the MIDI note it is holding down.
  final Map<int, int> _pointerNotes = {};

  // Current octave base (MIDI note of the leftmost C)
  int _octaveBase = 60; // C4

  // Analytics
  int _notesPlayed = 0;
  late final Stopwatch _sessionTimer;

  bool _initialized = false;

  // Hardware keyboard → MIDI note offset mapping (upiano-style), by key
  // position so it's the same piano layout on AZERTY/QWERTZ keyboards.
  // Lower octave: a w s e d f t g y h u j
  // Upper octave: k o l p ; ' ] \   (US key positions)
  static final Map<PhysicalKeyboardKey, int> _keyMap = {
    // Lower octave (offsets from _octaveBase)
    PhysicalKeyboardKey.keyA: 0,   // C
    PhysicalKeyboardKey.keyW: 1,   // C#
    PhysicalKeyboardKey.keyS: 2,   // D
    PhysicalKeyboardKey.keyE: 3,   // D#
    PhysicalKeyboardKey.keyD: 4,   // E
    PhysicalKeyboardKey.keyF: 5,   // F
    PhysicalKeyboardKey.keyT: 6,   // F#
    PhysicalKeyboardKey.keyG: 7,   // G
    PhysicalKeyboardKey.keyY: 8,   // G#
    PhysicalKeyboardKey.keyH: 9,   // A
    PhysicalKeyboardKey.keyU: 10,  // A#
    PhysicalKeyboardKey.keyJ: 11,  // B
    // Upper octave
    PhysicalKeyboardKey.keyK: 12,  // C
    PhysicalKeyboardKey.keyO: 13,  // C#
    PhysicalKeyboardKey.keyL: 14,  // D
    PhysicalKeyboardKey.keyP: 15,  // D#
    PhysicalKeyboardKey.semicolon: 16, // E
    PhysicalKeyboardKey.quote: 17, // F
    PhysicalKeyboardKey.bracketRight: 18, // F#
    PhysicalKeyboardKey.backslash: 19, // G
  };

  @override
  void initState() {
    super.initState();
    _sessionTimer = Stopwatch()..start();
    _initSynth();
  }

  Future<void> _initSynth() async {
    await _synth.init();
    // Preload 2 octaves starting at current base
    await _synth.preloadRange(_octaveBase, 24);
    if (mounted) {
      setState(() => _initialized = true);
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

  // Touch keys use raw pointer events rather than tap gestures: they fire on
  // contact without waiting for the gesture arena (e.g. the iOS back-swipe
  // strip over the lowest key), and each finger is tracked on its own.
  void _onPointerDown(PointerDownEvent event, int midiNote) {
    _pointerNotes[event.pointer] = midiNote;
    _onNoteOn(midiNote);
  }

  void _onPointerUp(PointerEvent event) {
    final midiNote = _pointerNotes.remove(event.pointer);
    // Keep the key down while another finger still holds it.
    if (midiNote != null && !_pointerNotes.containsValue(midiNote)) {
      _onNoteOff(midiNote);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    final offset = _keyMap[event.physicalKey];
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
        _pointerNotes.clear();
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
            // Keep the end keys clear of the notch and rounded corners in
            // landscape (the app bar already covers the top inset).
            : SafeArea(
                top: false,
                child: Column(
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
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _onPointerDown(e, midiNote),
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerUp,
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

                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) => _onPointerDown(e, midiNote),
                        onPointerUp: _onPointerUp,
                        onPointerCancel: _onPointerUp,
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
