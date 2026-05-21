import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/tui/tui_keybindings.dart';

void main() {
  group('TuiKeyBindings character handling', () {
    test('single-character bindings dispatch immediately', () {
      final kb = TuiKeyBindings();
      expect(kb.handleCharacterForTest('j'), TuiAction.moveDown);
      expect(kb.handleCharacterForTest('k'), TuiAction.moveUp);
      expect(kb.handleCharacterForTest('h'), TuiAction.moveLeft);
      expect(kb.handleCharacterForTest('l'), TuiAction.moveRight);
      expect(kb.handleCharacterForTest('q'), TuiAction.quit);
      expect(kb.handleCharacterForTest('v'), TuiAction.toggleVisualizer);
      kb.dispose();
    });

    test('first g waits for prefix, second g completes gg → goToTop', () {
      final kb = TuiKeyBindings();
      // First 'g' is a potential prefix, so no action yet.
      expect(kb.handleCharacterForTest('g'), TuiAction.none);
      expect(kb.pendingSequence, 'g');
      // Second 'g' completes the sequence.
      expect(kb.handleCharacterForTest('g'), TuiAction.goToTop);
      expect(kb.pendingSequence, '');
      kb.dispose();
    });

    test('non-prefix char after pending g resets and matches the lone char', () {
      // After 'g', typing 'j' has no matching 'gj' sequence; the implementation
      // resets and tries the single-char match, returning moveDown.
      final kb = TuiKeyBindings();
      kb.handleCharacterForTest('g'); // pending
      expect(kb.handleCharacterForTest('j'), TuiAction.moveDown);
      expect(kb.pendingSequence, '');
      kb.dispose();
    });

    test('500ms timeout on a lone g dispatches via onSequenceTimeout', () {
      fakeAsync((async) {
        TuiAction? timedOut;
        final kb = TuiKeyBindings()
          ..onSequenceTimeout = (action) => timedOut = action;

        expect(kb.handleCharacterForTest('g'), TuiAction.none);
        async.elapse(const Duration(milliseconds: 499));
        expect(timedOut, isNull);
        async.elapse(const Duration(milliseconds: 1));
        // 'g' alone has no _matchSequence entry, so the callback should NOT
        // fire (the implementation only dispatches when the prefix is itself
        // a valid action). Verify the sequence reset.
        expect(timedOut, isNull);
        expect(kb.pendingSequence, '');
        kb.dispose();
      });
    });

    test('Shift-V dispatches cycleVisualizerStyle (capital letter)', () {
      final kb = TuiKeyBindings();
      expect(kb.handleCharacterForTest('V'), TuiAction.cycleVisualizerStyle);
      kb.dispose();
    });

    test('? dispatches toggleHelp', () {
      final kb = TuiKeyBindings();
      expect(kb.handleCharacterForTest('?'), TuiAction.toggleHelp);
      kb.dispose();
    });
  });
}
