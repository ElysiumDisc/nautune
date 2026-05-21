import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/fft_math.dart';

void main() {
  group('rmsAverageRange', () {
    test('returns 0 for empty list', () {
      expect(rmsAverageRange(const [], 0, 10), 0.0);
    });

    test('returns 0 when start >= end', () {
      expect(rmsAverageRange(const [1.0, 2.0, 3.0], 2, 2), 0.0);
      expect(rmsAverageRange(const [1.0, 2.0, 3.0], 3, 1), 0.0);
    });

    test('clamps out-of-range indices', () {
      expect(rmsAverageRange(const [1.0, 1.0], -5, 10), 1.0);
    });

    test('matches RMS formula on a known input', () {
      final data = [1.0, 2.0, 3.0, 4.0];
      // sqrt((1+4+9+16)/4) = sqrt(7.5)
      final expected = math.sqrt(7.5);
      expect(rmsAverageRange(data, 0, 4), closeTo(expected, 1e-12));
    });

    test('respects the [start, end) sub-range', () {
      final data = [1.0, 2.0, 3.0, 4.0];
      // sqrt((4+9)/2) over indices [1,3)
      final expected = math.sqrt(6.5);
      expect(rmsAverageRange(data, 1, 3), closeTo(expected, 1e-12));
    });

    test('handles single-element range', () {
      expect(rmsAverageRange(const [5.0], 0, 1), 5.0);
    });

    test('handles all-zero input', () {
      final data = List<double>.filled(8, 0.0);
      expect(rmsAverageRange(data, 0, 8), 0.0);
    });
  });
}
