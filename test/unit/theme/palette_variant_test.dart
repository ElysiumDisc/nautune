import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/models/appearance.dart';
import 'package:nautune/theme/nautune_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final palettes = [
    ...NautunePalettes.presets,
    NautuneColorPalette.custom(
      primary: const Color(0xFFFFEB3B),
      secondary: const Color(0xFF00BCD4),
      isLight: false,
    ),
  ];

  for (final palette in palettes) {
    for (final brightness in Brightness.values) {
      if (brightness == palette.brightness) continue; // user-designed
      test('${palette.name} generated ${brightness.name} variant is readable', () {
        final v = palette.variant(brightness);
        expect(v.brightness, brightness);
        final theme = v.buildTheme();
        final scheme = theme.colorScheme;
        expect(_contrast(scheme.onSurface, scheme.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(scheme.primary, scheme.surface), greaterThanOrEqualTo(3));
        expect(_contrast(scheme.onPrimary, scheme.primary), greaterThanOrEqualTo(3));
      });
    }
  }

  test('a variant at the palette\'s own brightness is the palette', () {
    final p = NautunePalettes.purpleOcean;
    expect(identical(p.variant(Brightness.dark), p), isTrue);
  });

  test('Now Playing accent keeps contrast on the surface', () {
    for (final palette in NautunePalettes.presets) {
      for (final accent in const [Color(0xFF101010), Color(0xFFFFFFF0), Color(0xFF2040FF)]) {
        final themed = palette.withAccent(accent).buildTheme();
        expect(
          _contrast(themed.colorScheme.primary, themed.colorScheme.surface),
          greaterThanOrEqualTo(3),
          reason: '${palette.name} + $accent',
        );
      }
    }
  });

  test('theme carries the NautuneStyle extension and corner style', () {
    final theme = NautunePalettes.purpleOcean.buildTheme(
      style: const NautuneStyle(cornerStyle: CornerStyle.rounded, frostedBlur: false),
    );
    final style = theme.extension<NautuneStyle>()!;
    expect(style.frostedBlur, isFalse);
    expect(style.shape(12), isA<RoundedRectangleBorder>());
    expect(const NautuneStyle().shape(12), isA<RoundedSuperellipseBorder>());
  });
}
