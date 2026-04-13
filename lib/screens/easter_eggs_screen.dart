import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/connectivity_provider.dart';
import 'essential_mix_screen.dart';
import 'frets_on_fire_screen.dart';
import 'healing_frequencies_screen.dart';
import 'network_screen.dart';
import 'piano_screen.dart';
import 'relax_mode_screen.dart';

/// A discoverable hub listing every Easter egg, with quick descriptions and
/// offline-capability chips. Reached from Settings → Your Music → Easter Eggs.
class EasterEggsScreen extends StatelessWidget {
  const EasterEggsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOffline =
        context.watch<ConnectivityProvider>().networkAvailable == false;

    final eggs = <_EasterEggEntry>[
      _EasterEggEntry(
        title: 'Relax Mode',
        description:
            'Ambient sound mixer — rain, thunder, campfire, waves, loons.',
        icon: Icons.spa,
        iconColor: const Color(0xFF8BC34A),
        keyword: 'relax',
        offlineCapable: true,
        builder: (_) => const RelaxModeScreen(),
      ),
      _EasterEggEntry(
        title: 'The Network',
        description:
            'Other People Radio 0–333. Downloaded channels play offline.',
        icon: Icons.radio,
        iconColor: Colors.white,
        background: Colors.black,
        keyword: 'network',
        offlineCapable: false,
        builder: (_) => const NetworkScreen(),
      ),
      _EasterEggEntry(
        title: 'Essential Mix',
        description: 'Soulwax / 2ManyDJs BBC Radio 1 archives.',
        icon: Icons.album,
        iconColor: Colors.deepPurple,
        background: const Color(0xFF1A1A2E),
        keyword: 'essential',
        offlineCapable: false,
        builder: (_) => const EssentialMixScreen(),
      ),
      _EasterEggEntry(
        title: 'Frets on Fire',
        description: 'Guitar Hero-style rhythm game over your music library.',
        icon: Icons.local_fire_department,
        iconColor: Colors.orange,
        background: Colors.deepOrange.shade900,
        keyword: 'fire',
        offlineCapable: true,
        builder: (_) => const FretsOnFireScreen(),
      ),
      _EasterEggEntry(
        title: 'Piano',
        description: 'Playable synth keyboard — in-memory additive synthesis.',
        icon: Icons.piano,
        iconColor: Colors.white,
        background: const Color(0xFF1A1A2E),
        keyword: 'piano',
        offlineCapable: true,
        builder: (_) => const PianoScreen(),
      ),
      _EasterEggEntry(
        title: 'Healing Frequencies',
        description:
            'Solfeggio, Chakras, Schumann — pure sine-wave synthesis.',
        icon: Icons.graphic_eq,
        iconColor: const Color(0xFF80DEEA),
        background: const Color(0xFF142B2E),
        keyword: 'solfeggio / healing / hz',
        offlineCapable: true,
        builder: (_) => const HealingFrequenciesScreen(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Easter Eggs')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: eggs.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return _buildHeader(theme);
          return _buildTile(context, theme, eggs[i - 1], isOffline);
        },
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hidden Features',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Search Library for secret keywords to find these, or jump in here.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    ThemeData theme,
    _EasterEggEntry egg,
    bool isOffline,
  ) {
    final disabledByOffline = isOffline && !egg.offlineCapable;
    final tile = Card(
      color: egg.background,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              (egg.background ?? theme.colorScheme.surface).withValues(
            alpha: 0.5,
          ),
          child: Icon(egg.icon, color: egg.iconColor),
        ),
        title: Text(
          egg.title,
          style: TextStyle(
            color: egg.background != null ? Colors.white : null,
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                egg.description,
                style: TextStyle(
                  color: egg.background != null ? Colors.white70 : null,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _chip(
                    theme,
                    egg.offlineCapable ? 'Works offline' : 'Needs downloads',
                    egg.offlineCapable ? Colors.green : Colors.amber,
                  ),
                  const SizedBox(width: 6),
                  _chip(
                    theme,
                    'Search: "${egg.keyword}"',
                    theme.colorScheme.primary,
                    subtle: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: egg.background != null ? Colors.white54 : null,
        ),
        onTap: () {
          if (disabledByOffline) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Offline — this egg needs downloads. Go online to download first.',
                ),
                duration: Duration(seconds: 3),
              ),
            );
            return;
          }
          Navigator.of(context).push(MaterialPageRoute(builder: egg.builder));
        },
      ),
    );

    return disabledByOffline ? Opacity(opacity: 0.6, child: tile) : tile;
  }

  Widget _chip(
    ThemeData theme,
    String label,
    Color base, {
    bool subtle = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withValues(alpha: subtle ? 0.12 : 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: base.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: base,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EasterEggEntry {
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final Color? background;
  final String keyword;
  final bool offlineCapable;
  final WidgetBuilder builder;

  const _EasterEggEntry({
    required this.title,
    required this.description,
    required this.icon,
    required this.iconColor,
    required this.keyword,
    required this.offlineCapable,
    required this.builder,
    this.background,
  });
}
