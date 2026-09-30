import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/services/healing_frequency_service.dart';

void main() {
  group('HealingFrequencyService.generateLoopWav', () {
    Int16List pcm(Uint8List wav) =>
        wav.buffer.asInt16List(wav.offsetInBytes + 44, (wav.length - 44) ~/ 2);

    for (final hz in [174.0, 528.0, 68.05, 117.3, 501.12, 4225.0]) {
      test('$hz Hz loops without a step at the wrap', () {
        final samples = pcm(HealingFrequencyService.generateLoopWav(hz));
        final seconds = samples.length / 44100;
        expect(seconds, inInclusiveRange(10, 20.001));

        // Starts at phase 0, so the sample after the last one is 0 again.
        expect(samples.first, 0);
        // The wrap (last -> first) must look like any other step of the
        // sine near a zero crossing: at most one sample's worth of slope.
        final maxStep = 0.5 * 32767 * 2 * pi * hz / 44100;
        final wrapStep = (samples.first - samples.last).abs();
        expect(wrapStep, lessThanOrEqualTo(maxStep * 1.05));
        // And the last sample is where the sine is one sample before phase 0
        // (within a small fraction of a sample's slope): the loop is a whole
        // number of cycles, not just "close".
        final expectedLast = -sin(2 * pi * hz / 44100) * 0.5 * 32767;
        expect((samples.last - expectedLast).abs(),
            lessThanOrEqualTo(maxStep * 0.02 + 1));
      });
    }

    test('clamps sub-audible input to 20 Hz', () {
      final samples = pcm(HealingFrequencyService.generateLoopWav(7.83));
      // 20 Hz at 44.1 kHz: a whole cycle is 2205 samples.
      expect(samples.length % 2205, 0);
    });
  });
}
