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

  test('Light Lavender secondary text meets WCAG AA on its surface', () {
    const p = NautunePalettes.lightLavender;
    expect(_contrast(p.textSecondary, p.surface), greaterThanOrEqualTo(4.5));
    final scheme = p.buildTheme().colorScheme;
    expect(_contrast(scheme.onSurfaceVariant, scheme.surface), greaterThanOrEqualTo(4.5));
  });

  test('every preset keeps secondary text readable at its own brightness', () {
    for (final palette in NautunePalettes.presets) {
      final theme = palette.buildTheme();
      expect(
        _contrast(theme.colorScheme.onSurfaceVariant, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: palette.name,
      );
      expect(
        _contrast(theme.textTheme.labelMedium!.color!, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
        reason: palette.name,
      );
    }
  });

  group('custom palettes are contrast-fixed at their own brightness', () {
    // Deliberately unreadable picks: near-surface colours for every role.
    const picks = [
      (primary: Color(0xFF101018), secondary: Color(0xFF151520), accent: Color(0xFF0A0A40), isLight: false),
      (primary: Color(0xFFFFFF80), secondary: Color(0xFFF0F0F0), accent: Color(0xFFFFFFE0), isLight: true),
      (primary: Color(0xFF6B21A8), secondary: Color(0xFF9333EA), accent: Color(0xFF1A1A2E), isLight: false),
    ];
    for (final pick in picks) {
      test('${pick.isLight ? 'light' : 'dark'} ${pick.primary}', () {
        final palette = NautuneColorPalette.custom(
          primary: pick.primary,
          secondary: pick.secondary,
          accent: pick.accent,
          isLight: pick.isLight,
        );
        final scheme = palette.buildTheme().colorScheme;
        expect(_contrast(scheme.onSurface, scheme.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(scheme.onSurfaceVariant, scheme.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(scheme.primary, scheme.surface), greaterThanOrEqualTo(3));
        expect(_contrast(scheme.secondary, scheme.surface), greaterThanOrEqualTo(3));
        expect(_contrast(palette.textPrimary, palette.surface), greaterThanOrEqualTo(4.5));
      });
    }
  });
}
