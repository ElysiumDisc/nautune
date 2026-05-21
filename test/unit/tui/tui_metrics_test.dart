import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/tui/tui_metrics.dart';

void main() {
  group('TuiMetrics.sidebarCharsForTotalChars', () {
    test('returns 18 for narrow windows (<90 cols)', () {
      // Big enough that the content-pane guarantee doesn't clamp lower.
      expect(TuiMetrics.sidebarCharsForTotalChars(80), 18);
      expect(TuiMetrics.sidebarCharsForTotalChars(89), 18);
    });

    test('returns 22 for medium windows (90..120 cols inclusive)', () {
      expect(TuiMetrics.sidebarCharsForTotalChars(90), 22);
      expect(TuiMetrics.sidebarCharsForTotalChars(100), 22);
      expect(TuiMetrics.sidebarCharsForTotalChars(120), 22);
    });

    test('returns 26 for wide windows (>120 cols)', () {
      expect(TuiMetrics.sidebarCharsForTotalChars(121), 26);
      expect(TuiMetrics.sidebarCharsForTotalChars(200), 26);
    });

    test('clamps sidebar so the content pane has at least 32 chars', () {
      // total=60, raw sidebar=18, max=60-32=28 -> stays 18
      expect(TuiMetrics.sidebarCharsForTotalChars(60), 18);
      // total=46, max=46-32=14 -> sidebar=18 clamped down to 14
      expect(TuiMetrics.sidebarCharsForTotalChars(46), 14);
      // total=44, max=44-32=12 -> sidebar=18 clamped down to 12
      expect(TuiMetrics.sidebarCharsForTotalChars(44), 12);
    });

    test('floor of 12 chars even on absurdly narrow windows', () {
      // total=30, max=(30-32).clamp(12,32)=12
      expect(TuiMetrics.sidebarCharsForTotalChars(30), 12);
      // total=0, max=(-32).clamp(12,32)=12 -> sidebar.clamp(12,12)=12
      expect(TuiMetrics.sidebarCharsForTotalChars(0), 12);
    });
  });
}
