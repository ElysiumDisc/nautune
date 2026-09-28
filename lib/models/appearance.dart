/// Light/dark choice. [palette] keeps each palette's own brightness (the
/// pre-10 behaviour); the others force or follow the system.
enum AppearanceMode {
  palette('Palette'),
  system('System'),
  light('Light'),
  dark('Dark');

  const AppearanceMode(this.label);
  final String label;

  static AppearanceMode fromName(String? name) => AppearanceMode.values
      .firstWhere((m) => m.name == name, orElse: () => AppearanceMode.palette);
}

/// Corner geometry for cards, sheets and buttons.
enum CornerStyle {
  /// Circular-arc corners.
  rounded('Rounded'),

  /// Continuous (superellipse) corners, as drawn by iOS.
  squircle('Squircle');

  const CornerStyle(this.label);
  final String label;

  static CornerStyle fromName(String? name) => CornerStyle.values
      .firstWhere((c) => c.name == name, orElse: () => CornerStyle.squircle);
}

/// Where the app's accent colour comes from.
enum AccentSource {
  palette('Palette'),
  nowPlaying('Now Playing');

  const AccentSource(this.label);
  final String label;

  static AccentSource fromName(String? name) => AccentSource.values
      .firstWhere((a) => a.name == name, orElse: () => AccentSource.palette);
}
