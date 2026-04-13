import 'dart:async';

import 'package:flutter/material.dart';

import '../data/healing_frequencies.dart';
import '../services/healing_frequency_service.dart';
import '../services/listening_analytics_service.dart';

/// Healing Frequencies Easter egg.
/// Inspired by https://github.com/evoluteur/healing-frequencies (MIT © Olivier Giulieri).
/// All tones are synthesized locally — works fully offline.
class HealingFrequenciesScreen extends StatefulWidget {
  const HealingFrequenciesScreen({super.key});

  @override
  State<HealingFrequenciesScreen> createState() =>
      _HealingFrequenciesScreenState();
}

class _HealingFrequenciesScreenState extends State<HealingFrequenciesScreen> {
  final HealingFrequencyService _service = HealingFrequencyService();
  StreamSubscription<double?>? _sub;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
    _markDiscovered();
  }

  Future<void> _init() async {
    await _service.init();
    _sub = _service.currentHzStream.listen((_) {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() => _ready = true);
  }

  void _markDiscovered() {
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized) {
      analytics.markHealingFrequenciesDiscovered();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _service.dispose();
    super.dispose();
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Healing Frequencies',
      applicationVersion: 'Easter Egg',
      children: const [
        SizedBox(height: 8),
        Text(
          'Inspired by Healing Frequencies by Olivier Giulieri — MIT.\n'
          'https://github.com/evoluteur/healing-frequencies',
        ),
        SizedBox(height: 12),
        Text(
          '100% synthesized locally on this device — works offline.',
        ),
        SizedBox(height: 12),
        Text(
          'These frequencies are for exploration and meditation. '
          'They are not medical treatment.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  Future<void> _onPillTap(HealingFrequency freq) async {
    final playing = _service.currentHz == freq.playbackHz;
    if (playing) {
      await _service.stop();
    } else {
      await _service.play(freq.playbackHz);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Healing Frequencies'),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: 'Stop',
            onPressed: _service.currentHz == null
                ? null
                : () => _service.stop(),
          ),
          PopupMenuButton<void>(
            tooltip: 'Volume',
            icon: const Icon(Icons.volume_up),
            itemBuilder: (ctx) => [
              PopupMenuItem<void>(
                enabled: false,
                child: StatefulBuilder(
                  builder: (ctx, setInner) {
                    return SizedBox(
                      width: 200,
                      child: Row(
                        children: [
                          const Icon(Icons.volume_down, size: 18),
                          Expanded(
                            child: Slider(
                              value: _service.volume,
                              onChanged: (v) {
                                _service.setVolume(v);
                                setInner(() {});
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                          const Icon(Icons.volume_up, size: 18),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: _showAbout,
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: kHealingCategories.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) return _buildHeader(theme);
                return _buildCategory(theme, kHealingCategories[i - 1]);
              },
            ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tap a frequency to play. Tap again to stop.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                'Works offline — tones are synthesized on-device.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategory(ThemeData theme, HealingCategory category) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: Icon(category.icon, color: theme.colorScheme.primary),
        title: Text(
          category.name,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(category.blurb),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        initiallyExpanded: category.name == 'Solfeggio',
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final freq in category.frequencies)
                _FreqPill(
                  freq: freq,
                  isPlaying: _service.currentHz == freq.playbackHz,
                  onTap: () => _onPillTap(freq),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FreqPill extends StatefulWidget {
  final HealingFrequency freq;
  final bool isPlaying;
  final VoidCallback onTap;

  const _FreqPill({
    required this.freq,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  State<_FreqPill> createState() => _FreqPillState();
}

class _FreqPillState extends State<_FreqPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = widget.isPlaying;
    final bg = playing
        ? theme.colorScheme.primary
        : theme.colorScheme.primaryContainer;
    final fg = playing
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onPrimaryContainer;

    final label = widget.freq.name.isEmpty
        ? '${_formatHz(widget.freq.hz)} Hz'
        : '${widget.freq.name} · ${_formatHz(widget.freq.hz)} Hz';

    final tooltipMsg = widget.freq.description ??
        (widget.freq.isInaudible ? 'Playing audible octave' : '');

    return AnimatedBuilder(
      animation: _pulse,
      builder: (ctx, child) {
        final glow = playing ? (0.35 + 0.35 * _pulse.value) : 0.0;
        return Material(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          elevation: playing ? 2 : 0,
          shadowColor: playing
              ? theme.colorScheme.primary.withValues(alpha: glow)
              : null,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: playing
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.primary
                              .withValues(alpha: glow),
                          blurRadius: 14 + 10 * _pulse.value,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.freq.isInaudible) ...[
                    Icon(Icons.hearing_disabled, size: 14, color: fg),
                    const SizedBox(width: 6),
                  ] else if (playing) ...[
                    Icon(Icons.graphic_eq, size: 14, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Tooltip(
                    message: tooltipMsg,
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg,
                        fontWeight:
                            playing ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatHz(double hz) {
    if (hz == hz.toInt()) return hz.toInt().toString();
    return hz.toStringAsFixed(2);
  }
}
