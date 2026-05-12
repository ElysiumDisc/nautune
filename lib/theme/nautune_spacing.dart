import 'package:flutter/widgets.dart';

/// Spacing constants used across Nautune screens. Co-located with NautuneRadius
/// in a single file so importers only need one symbol when polishing layouts.
///
/// Scale rationale: 4/8/12/16/24/32 covers the in-the-wild gaps without giving
/// authors enough granularity to drift. Reach for the closest token rather
/// than introducing a one-off `SizedBox(height: 14)`.
class NautuneSpacing {
  const NautuneSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Border-radius constants. Use the `.allXxx` variants when constructing a
/// `Container` decoration so the BorderRadius itself can be `const`.
///
/// Signature radii (14 in the hero ring, 20 in the Essential Mix badge) are
/// intentionally not represented here — those shapes are part of the visual
/// identity and should be left as one-offs at their call sites.
class NautuneRadius {
  const NautuneRadius._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;

  static const BorderRadius allXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius allSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius allMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius allLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius allXl = BorderRadius.all(Radius.circular(xl));
}
