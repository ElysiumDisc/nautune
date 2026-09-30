import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/utils/artwork_colors.dart';

Uint8List _solidRgba(int r, int g, int b, {int pixels = 64}) {
  final bytes = Uint8List(pixels * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = r;
    bytes[i + 1] = g;
    bytes[i + 2] = b;
    bytes[i + 3] = 0xFF;
  }
  return bytes;
}

void main() {
  test('rgbaBytesToArgb reorders R,G,B,A bytes into 0xAARRGGBB', () {
    final argb = rgbaBytesToArgb(
      Uint8List.fromList([0x11, 0x22, 0x33, 0x44, 0xFF, 0x00, 0x80, 0xFF]),
    );
    expect(argb, [0x44112233, 0xFFFF0080]);
  });

  test('rgbaBytesToArgb ignores a trailing partial pixel', () {
    expect(rgbaBytesToArgb(Uint8List.fromList([1, 2, 3, 4, 5, 6])), [0x04010203]);
    expect(rgbaBytesToArgb(Uint8List(0)), isEmpty);
  });

  test('a red image yields a red colour, not blue', () async {
    final colors = await extractArtworkColorsInIsolate(_solidRgba(0xE0, 0x20, 0x10));
    expect(colors, isNotEmpty);
    final c = Color(colors.first);
    expect((c.r * 255).round(), greaterThan((c.b * 255).round()));
  });

  test('a blue image yields a blue colour, not red', () async {
    final colors = await extractArtworkColorsInIsolate(_solidRgba(0x10, 0x30, 0xE0));
    expect(colors, isNotEmpty);
    final c = Color(colors.first);
    expect((c.b * 255).round(), greaterThan((c.r * 255).round()));
  });
}
