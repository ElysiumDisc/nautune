import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/pulseaudio_fft_service.dart';

void main() {
  group('PcmChunker', () {
    test('empty input yields no chunks and no pending bytes', () {
      final c = PcmChunker(4);
      expect(c.takeChunk(), isNull);
      expect(c.pendingLength, 0);
    });

    test('less than chunkSize: nothing emitted, all bytes pending', () {
      final c = PcmChunker(8);
      c.add(Uint8List.fromList([1, 2, 3]));
      expect(c.takeChunk(), isNull);
      expect(c.pendingLength, 3);
    });

    test('exactly one chunkSize: one chunk emitted, no remainder', () {
      final c = PcmChunker(4);
      c.add(Uint8List.fromList([10, 20, 30, 40]));
      final chunk = c.takeChunk();
      expect(chunk, isNotNull);
      expect(chunk!, Uint8List.fromList([10, 20, 30, 40]));
      expect(c.takeChunk(), isNull);
      expect(c.pendingLength, 0);
    });

    test('2.5 x chunkSize in one write: two chunks, half-chunk remainder', () {
      final c = PcmChunker(4);
      c.add(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));

      final first = c.takeChunk();
      expect(first, isNotNull);
      expect(first!, Uint8List.fromList([1, 2, 3, 4]));

      final second = c.takeChunk();
      expect(second, isNotNull);
      expect(second!, Uint8List.fromList([5, 6, 7, 8]));

      // Two bytes remain.
      expect(c.takeChunk(), isNull);
      expect(c.pendingLength, 2);
    });

    test('many small writes accumulate into a full chunk', () {
      final c = PcmChunker(4);
      c.add(Uint8List.fromList([1]));
      c.add(Uint8List.fromList([2]));
      expect(c.takeChunk(), isNull);
      c.add(Uint8List.fromList([3, 4, 5]));
      final chunk = c.takeChunk();
      expect(chunk, isNotNull);
      expect(chunk!, Uint8List.fromList([1, 2, 3, 4]));
      expect(c.pendingLength, 1);
    });

    test('clear() drops pending bytes', () {
      final c = PcmChunker(4);
      c.add(Uint8List.fromList([1, 2, 3]));
      expect(c.pendingLength, 3);
      c.clear();
      expect(c.pendingLength, 0);
      expect(c.takeChunk(), isNull);
    });

    test('asserts on non-positive chunkSize', () {
      expect(() => PcmChunker(0), throwsA(isA<AssertionError>()));
      expect(() => PcmChunker(-1), throwsA(isA<AssertionError>()));
    });
  });
}
