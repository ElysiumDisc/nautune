import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/progress_throttle.dart';

void main() {
  group('ProgressThrottle', () {
    late DateTime now;
    late ProgressThrottle throttle;

    setUp(() {
      now = DateTime(2026, 1, 1);
      throttle = ProgressThrottle(
        interval: const Duration(milliseconds: 250),
        byteInterval: 1000,
        clock: () => now,
      );
    });

    test('emits on the first chunk', () {
      expect(throttle.shouldEmit(10, 5000), isTrue);
    });

    test('suppresses rapid small chunks, emits once the interval passes', () {
      throttle.shouldEmit(10, 5000);
      now = now.add(const Duration(milliseconds: 100));
      expect(throttle.shouldEmit(20, 5000), isFalse);
      now = now.add(const Duration(milliseconds: 160));
      expect(throttle.shouldEmit(30, 5000), isTrue);
    });

    test('emits when enough bytes arrive even within the interval', () {
      throttle.shouldEmit(10, 50000);
      now = now.add(const Duration(milliseconds: 10));
      expect(throttle.shouldEmit(500, 50000), isFalse);
      expect(throttle.shouldEmit(1010, 50000), isTrue);
    });

    test('always emits when the transfer completes', () {
      throttle.shouldEmit(10, 100);
      expect(throttle.shouldEmit(100, 100), isTrue);
    });

    test('variable chunk sizes still produce updates (no modulo dependency)', () {
      var emits = 0;
      var bytes = 0;
      for (var i = 0; i < 100; i++) {
        bytes += 777; // never a multiple of anything useful
        now = now.add(const Duration(milliseconds: 50));
        if (throttle.shouldEmit(bytes, 0)) emits++;
      }
      expect(emits, greaterThan(10));
    });
  });
}
