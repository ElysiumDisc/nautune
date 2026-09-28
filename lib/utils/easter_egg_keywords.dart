/// Hidden features that surface as a special card when the user searches for
/// their exact keyword.
enum EasterEgg {
  relaxMode,
  network,
  essentialMix,
  fretsOnFire,
  piano,
  healingFrequencies,
}

const Map<EasterEgg, Set<String>> _keywords = {
  EasterEgg.relaxMode: {'relax', 'relax mode'},
  EasterEgg.network: {'network', 'the network'},
  EasterEgg.essentialMix: {'essential', 'essential mix'},
  EasterEgg.fretsOnFire: {'fire', 'frets', 'frets on fire'},
  EasterEgg.piano: {'piano'},
  EasterEgg.healingFrequencies: {
    'solfeggio',
    'healing',
    'healing frequencies',
    'frequency',
    'frequencies',
    'hz',
  },
};

/// Returns the easter egg whose keyword matches the *whole* search query
/// (trimmed, case-insensitive, internal whitespace collapsed), or null.
///
/// Whole-query matching keeps real searches like "Arcade Fire" or "432hz"
/// from triggering an easter-egg card.
EasterEgg? matchEasterEgg(String query) {
  final normalized = query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  for (final entry in _keywords.entries) {
    if (entry.value.contains(normalized)) return entry.key;
  }
  return null;
}
