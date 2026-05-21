import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/color_utils.dart';

void main() {
  group('extractColorsFromBytes', () {
    test('returns empty list for an empty buffer', () {
      expect(extractColorsFromBytes(Uint8List(0)), isEmpty);
    });

    test('returns empty list when buffer is shorter than 3 bytes', () {
      // Sampler reads i, i+1, i+2 — anything smaller has no full pixel.
      expect(extractColorsFromBytes(Uint8List.fromList([0xFF])), isEmpty);
      expect(extractColorsFromBytes(Uint8List.fromList([0xFF, 0x00])), isEmpty);
    });

    test('packs RGB into ARGB with full alpha', () {
      // Single RGBA pixel: R=0x11, G=0x22, B=0x33, A=anything
      final pixels = Uint8List.fromList([0x11, 0x22, 0x33, 0xFF]);
      final colors = extractColorsFromBytes(pixels);
      expect(colors, hasLength(1));
      expect(colors.first, 0xFF112233);
    });

    test('samples every 400 bytes (stride)', () {
      // 801 bytes -> indices 0, 400, 800 are sampled (3 pixels).
      final pixels = Uint8List(801);
      // Pixel @ 0: white-ish (high luma)
      pixels[0] = 0xFF; pixels[1] = 0xFF; pixels[2] = 0xFF;
      // Pixel @ 400: mid-gray
      pixels[400] = 0x80; pixels[401] = 0x80; pixels[402] = 0x80;
      // Pixel @ 800: black
      pixels[800] = 0x00;
      // pixels[801] / pixels[802] don't exist but the loop's `i+2 < length`
      // guard rejects index 800 since 800+2 = 802 is out of bounds.
      // So we expect 2 sampled pixels: indices 0 and 400.
      final colors = extractColorsFromBytes(pixels);
      expect(colors, hasLength(2));
    });

    test('sorts colors by luminance ascending (Rec. 601 weights)', () {
      // Three pixels at strides 0, 400, 800; each is one ARGB color.
      // We need a buffer of at least 803 bytes for the third pixel to be valid.
      final pixels = Uint8List(803);
      // index 0: pure red (low luma)
      pixels[0] = 0xFF; pixels[1] = 0x00; pixels[2] = 0x00;
      // index 400: pure green (medium luma — Rec. 601 weighted heavily)
      pixels[400] = 0x00; pixels[401] = 0xFF; pixels[402] = 0x00;
      // index 800: pure blue (lowest luma)
      pixels[800] = 0x00; pixels[801] = 0x00; pixels[802] = 0xFF;

      final colors = extractColorsFromBytes(pixels);
      // Sorted ascending by luminance: blue (0.114*255) < red (0.299*255) < green (0.587*255)
      expect(colors, hasLength(3));
      expect(colors[0], 0xFF0000FF); // blue first (darkest)
      expect(colors[1], 0xFFFF0000); // red middle
      expect(colors[2], 0xFF00FF00); // green last (brightest)
    });
  });
}
