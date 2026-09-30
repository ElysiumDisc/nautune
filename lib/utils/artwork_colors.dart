import 'dart:typed_data';

import 'package:material_color_utilities/material_color_utilities.dart';

/// Converts `ui.ImageByteFormat.rawRgba` bytes (R, G, B, A per pixel) into
/// the `0xAARRGGBB` ints material_color_utilities expects.
///
/// Reading the bytes through `asUint32List()` instead gives `0xAABBGGRR` on
/// little-endian devices, which swaps red and blue.
List<int> rgbaBytesToArgb(Uint8List rgba) {
  final count = rgba.length ~/ 4;
  final argb = List<int>.filled(count, 0);
  for (var p = 0, i = 0; p < count; p++, i += 4) {
    argb[p] = (rgba[i + 3] << 24) |
        (rgba[i] << 16) |
        (rgba[i + 1] << 8) |
        rgba[i + 2];
  }
  return argb;
}

/// Top-level function for compute() - extracts vibrant colors from raw RGBA
/// image bytes (`image.toByteData()`) in an isolate. Returns up to 4
/// distinct, saturated colours, most vibrant first.
Future<List<int>> extractArtworkColorsInIsolate(Uint8List rgbaBytes) async {
  // Run the quantization to find the dominant color clusters
  final result =
      await QuantizerCelebi().quantize(rgbaBytesToArgb(rgbaBytes), 128);
  final colorToCount = result.colorToCount;

  // RAW VIBRANCY SCORING
  // Score = Population * (Chroma^2)
  final sortedEntries = colorToCount.entries.toList()
    ..sort((a, b) {
      final hctA = Hct.fromInt(a.key);
      final hctB = Hct.fromInt(b.key);
      final scoreA = a.value * (hctA.chroma * hctA.chroma);
      final scoreB = b.value * (hctB.chroma * hctB.chroma);
      return scoreB.compareTo(scoreA);
    });

  final selectedColors = <int>[];

  for (final entry in sortedEntries) {
    if (selectedColors.length >= 4) break;

    final colorInt = entry.key;
    final hct = Hct.fromInt(colorInt);

    // Skip absolute greys
    if (hct.chroma < 5) continue;

    // Distinctness check
    bool isDistinct = true;
    for (final existing in selectedColors) {
      final existingHct = Hct.fromInt(existing);
      final hueDiff = (hct.hue - existingHct.hue).abs();
      final normalizedHueDiff = hueDiff > 180 ? 360 - hueDiff : hueDiff;
      if (normalizedHueDiff < 15) {
        isDistinct = false;
        break;
      }
    }

    if (isDistinct) {
      // Add with full alpha
      selectedColors.add(colorInt | 0xFF000000);
    }
  }

  // Fallback if we found nothing (e.g. B&W image)
  if (selectedColors.isEmpty) {
    final populationSorted = colorToCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in populationSorted.take(4)) {
      selectedColors.add(entry.key | 0xFF000000);
    }
  }

  return selectedColors;
}
