import 'package:flutter/material.dart';

/// One healing frequency entry.
///
/// [hz] is the notional frequency (what the label shows).
/// For inaudible frequencies (e.g. Schumann 7.83 Hz) an [audibleOctaveHz] is
/// provided — this is what actually gets synthesized so the user can hear
/// something.
class HealingFrequency {
  final String name;
  final double hz;
  final String? description;
  final bool isInaudible;
  final double? audibleOctaveHz;

  const HealingFrequency({
    required this.name,
    required this.hz,
    this.description,
    this.isInaudible = false,
    this.audibleOctaveHz,
  });

  /// The frequency to synthesize (audible octave for inaudible entries).
  double get playbackHz => isInaudible ? (audibleOctaveHz ?? hz) : hz;
}

class HealingCategory {
  final String name;
  final String blurb;
  final IconData icon;
  final List<HealingFrequency> frequencies;

  const HealingCategory({
    required this.name,
    required this.blurb,
    required this.icon,
    required this.frequencies,
  });
}

/// All 12 categories mirrored from the source project
/// (https://github.com/evoluteur/healing-frequencies, MIT © Olivier Giulieri).
/// Labels and Hz values match the reference directory; a Schumann category is
/// added on top (inaudible, plays an audible octave).
const List<HealingCategory> kHealingCategories = [
  HealingCategory(
    name: 'Solfeggio',
    blurb: 'Ancient sound healing scale',
    icon: Icons.auto_awesome,
    frequencies: [
      HealingFrequency(name: 'UT', hz: 174, description: 'Physical pain & stress relief'),
      HealingFrequency(name: 'RE', hz: 285, description: 'Tissue restoration & healing'),
      HealingFrequency(name: 'MI', hz: 396, description: 'Guilt & fear diminishment'),
      HealingFrequency(name: 'FA', hz: 417, description: 'Trauma healing'),
      HealingFrequency(name: 'SOL', hz: 528, description: 'Relaxation & sleep improvement'),
      HealingFrequency(name: 'LA', hz: 639, description: 'Mental balance'),
      HealingFrequency(name: 'SI', hz: 741, description: 'Detoxification of mind & body'),
      HealingFrequency(name: '852', hz: 852, description: 'Anxiety & nervousness relief'),
      HealingFrequency(name: '963', hz: 963, description: 'Positive energy & clarity'),
      HealingFrequency(name: '1152', hz: 1152, description: 'Spiritual purification'),
      HealingFrequency(name: '2172', hz: 2172, description: 'Enlightenment & transcendence'),
    ],
  ),
  HealingCategory(
    name: 'Healing',
    blurb: 'Tuning-fork frequencies for restoration',
    icon: Icons.healing,
    frequencies: [
      HealingFrequency(name: '128', hz: 128, description: 'Circulation, sleep, stress relief'),
      HealingFrequency(name: '256', hz: 256, description: 'Cell growth & pain relief'),
      HealingFrequency(name: '512', hz: 512, description: 'Mental clarity & relaxation'),
      HealingFrequency(name: '1024', hz: 1024, description: 'Energy balance & immunity'),
    ],
  ),
  HealingCategory(
    name: 'Organs',
    blurb: 'Body-system resonance',
    icon: Icons.favorite,
    frequencies: [
      HealingFrequency(name: 'Stomach', hz: 110),
      HealingFrequency(name: 'Pancreas', hz: 117.3),
      HealingFrequency(name: 'Gall Bladder', hz: 164.3),
      HealingFrequency(name: 'Colon', hz: 176),
      HealingFrequency(name: 'Lungs', hz: 220),
      HealingFrequency(name: 'Intestines', hz: 281),
      HealingFrequency(name: 'Fat Cells', hz: 295.8),
      HealingFrequency(name: 'Brain', hz: 315.8),
      HealingFrequency(name: 'Liver', hz: 317.83),
      HealingFrequency(name: 'Kidneys', hz: 319.88),
      HealingFrequency(name: 'Blood', hz: 321.9),
      HealingFrequency(name: 'Muscles', hz: 324),
      HealingFrequency(name: 'Bladder', hz: 352),
      HealingFrequency(name: 'Bone', hz: 418.3),
      HealingFrequency(name: 'Adrenals', hz: 492.8),
    ],
  ),
  HealingCategory(
    name: 'Mineral Nutrients',
    blurb: 'Elemental resonance',
    icon: Icons.grain,
    frequencies: [
      HealingFrequency(name: 'Sulphur', hz: 256),
      HealingFrequency(name: 'Selenium & Chlorine', hz: 272),
      HealingFrequency(name: 'Potassium', hz: 304),
      HealingFrequency(name: 'Platinum', hz: 312),
      HealingFrequency(name: 'Gold', hz: 316),
      HealingFrequency(name: 'Calcium', hz: 320),
      HealingFrequency(name: 'Molybdenum', hz: 336),
      HealingFrequency(name: 'Magnesium', hz: 341),
      HealingFrequency(name: 'Sodium', hz: 352),
      HealingFrequency(name: 'Silver', hz: 376),
      HealingFrequency(name: 'Chromium', hz: 384),
      HealingFrequency(name: 'Manganese', hz: 400),
      HealingFrequency(name: 'Iron', hz: 416),
      HealingFrequency(name: 'Iodine', hz: 424),
      HealingFrequency(name: 'Silica', hz: 448),
      HealingFrequency(name: 'Copper', hz: 464),
      HealingFrequency(name: 'Phosphorus & Zinc', hz: 480),
    ],
  ),
  HealingCategory(
    name: 'Ohm',
    blurb: 'Foundational vibration — 4 intensities',
    icon: Icons.spa,
    frequencies: [
      HealingFrequency(name: 'Low Ohm', hz: 68.05),
      HealingFrequency(name: 'Mid Ohm', hz: 136.1),
      HealingFrequency(name: 'High Ohm', hz: 272.2),
      HealingFrequency(name: 'Ultra High Ohm', hz: 544.4),
    ],
  ),
  HealingCategory(
    name: 'Chakras',
    blurb: 'Yoga energy centers',
    icon: Icons.blur_circular,
    frequencies: [
      HealingFrequency(name: 'Earth star', hz: 68.05, description: 'Vasundhara'),
      HealingFrequency(name: 'Solar Plexus', hz: 126.22, description: 'Manipura'),
      HealingFrequency(name: 'Heart', hz: 136.1, description: 'Anahata'),
      HealingFrequency(name: 'Throat', hz: 141.27, description: 'Vishuddha'),
      HealingFrequency(name: 'Crown', hz: 172.06, description: 'Sahasrara'),
      HealingFrequency(name: 'Root', hz: 194.18, description: 'Muladhara'),
      HealingFrequency(name: 'Sacral', hz: 210.42, description: 'Svadhisthana'),
      HealingFrequency(name: 'Third Eye', hz: 221.23, description: 'Ajna'),
      HealingFrequency(name: 'Soul star', hz: 272.2, description: 'Vyapini'),
    ],
  ),
  HealingCategory(
    name: 'DNA Nucleotides',
    blurb: 'Genetic building blocks',
    icon: Icons.biotech,
    frequencies: [
      HealingFrequency(name: 'Cytosine', hz: 537.8),
      HealingFrequency(name: 'Thymine', hz: 543.4),
      HealingFrequency(name: 'Adenine', hz: 545.6),
      HealingFrequency(name: 'Guanine', hz: 550),
    ],
  ),
  HealingCategory(
    name: 'Nikola Tesla 3·6·9',
    blurb: "Tesla's harmonic numbers",
    icon: Icons.flash_on,
    frequencies: [
      HealingFrequency(name: '333', hz: 333, description: 'Healing, balance, harmony'),
      HealingFrequency(name: '639', hz: 639, description: 'Connection & communication'),
      HealingFrequency(name: '999', hz: 999, description: 'Spiritual awakening'),
    ],
  ),
  HealingCategory(
    name: 'Cosmic Octave',
    blurb: 'Planetary harmonics (Cousto)',
    icon: Icons.public,
    frequencies: [
      HealingFrequency(name: 'Sun', hz: 126.22),
      HealingFrequency(name: 'Pluto', hz: 140.25),
      HealingFrequency(name: 'Mercury', hz: 141.27),
      HealingFrequency(name: 'Mars', hz: 144.72),
      HealingFrequency(name: 'Saturn', hz: 147.85),
      HealingFrequency(name: 'Jupiter', hz: 183.58),
      HealingFrequency(name: 'Earth', hz: 194.18),
      HealingFrequency(name: 'Uranus', hz: 207.36),
      HealingFrequency(name: 'Moon', hz: 210.42),
      HealingFrequency(name: 'Neptune', hz: 211.44),
      HealingFrequency(name: 'Venus', hz: 221.23),
    ],
  ),
  HealingCategory(
    name: 'Osteopathic (Otto)',
    blurb: 'Low-frequency structural tones',
    icon: Icons.accessibility_new,
    frequencies: [
      HealingFrequency(name: '32', hz: 32, description: 'Immune system — may be inaudible on small speakers'),
      HealingFrequency(name: '64', hz: 64, description: 'Nervous system — barely audible'),
      HealingFrequency(name: '128', hz: 128, description: 'Joint mobility'),
    ],
  ),
  HealingCategory(
    name: 'Angels',
    blurb: 'High & numerological tones',
    icon: Icons.star,
    frequencies: [
      HealingFrequency(name: '111', hz: 111, description: 'Holy frequency'),
      HealingFrequency(name: '222', hz: 222, description: 'Energy balancer'),
      HealingFrequency(name: '333', hz: 333, description: 'Angelic frequency'),
      HealingFrequency(name: '444', hz: 444, description: 'Spiritual detoxer'),
      HealingFrequency(name: '555', hz: 555, description: 'Divine change'),
      HealingFrequency(name: '666', hz: 666, description: 'Physical/spiritual balance'),
      HealingFrequency(name: '777', hz: 777, description: 'Divine sound'),
      HealingFrequency(name: '888', hz: 888, description: 'Infinite possibilities'),
      HealingFrequency(name: '999', hz: 999, description: 'Higher self'),
      HealingFrequency(name: '4096', hz: 4096, description: "Jacob's ladder"),
      HealingFrequency(name: '4160', hz: 4160, description: 'Pillar of light'),
      HealingFrequency(name: '4225', hz: 4225, description: 'Stairway to heaven'),
    ],
  ),
  HealingCategory(
    name: 'Schumann',
    blurb: 'Earth resonance — inaudible; plays audible octave',
    icon: Icons.language,
    frequencies: [
      HealingFrequency(
        name: 'Earth',
        hz: 7.83,
        description: 'Inaudible — 501 Hz audible octave plays',
        isInaudible: true,
        audibleOctaveHz: 501.12, // 7.83 * 64 (6 octaves up)
      ),
    ],
  ),
];
