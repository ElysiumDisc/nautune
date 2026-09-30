import 'dart:async';

import 'package:flutter/material.dart';

import '../services/equalizer_service.dart';
import '../theme/nautune_spacing.dart';
import '../theme/nautune_theme.dart';
import '../utils/equalizer_presets.dart';
import '../widgets/ios/grouped_section.dart';

/// 10-band equalizer: on/off, presets and a slider per band.
class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = EqualizerService.instance;
    final theme = Theme.of(context);
    final style = NautuneStyle.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: ListenableBuilder(
        listenable: eq,
        builder: (context, _) {
          final current = eq.preset;
          return ListView(
            children: [
              GroupedSection(
                footer: 'Applies to music playback. Boosts are balanced by a '
                    'matching volume cut, so loud songs never distort.',
                children: [
                  GroupedTile(
                    icon: Icons.equalizer,
                    title: 'Equalizer',
                    trailing: Switch.adaptive(
                      value: eq.enabled,
                      onChanged: eq.setEnabled,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    NautuneSpacing.lg, 0, NautuneSpacing.lg, NautuneSpacing.sm),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in EqualizerPreset.values)
                      if (preset != EqualizerPreset.custom || current == EqualizerPreset.custom)
                        ChoiceChip(
                          label: Text(preset.label),
                          selected: current == preset,
                          showCheckmark: false,
                          onSelected: preset == EqualizerPreset.custom
                              ? null
                              : (_) => eq.applyPreset(preset),
                        ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(NautuneSpacing.lg),
                child: Material(
                  color: style.groupedCell,
                  shape: style.shape(NautuneRadius.md),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: NautuneSpacing.lg),
                    child: AnimatedOpacity(
                      opacity: eq.enabled ? 1 : 0.45,
                      duration: const Duration(milliseconds: 200),
                      child: SizedBox(
                        height: 260,
                        child: Row(
                          children: [
                            for (var i = 0; i < kEqualizerBands.length; i++)
                              Expanded(
                                child: _BandSlider(
                                  label: equalizerBandLabel(kEqualizerBands[i]),
                                  value: eq.gains[i],
                                  enabled: eq.enabled,
                                  onChanged: (v) => eq.setGain(i, v),
                                  onChangeEnd: (_) => unawaited(eq.flush()),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: TextButton(
                  onPressed: eq.enabled ? () => eq.applyPreset(EqualizerPreset.flat) : null,
                  child: Text('Reset to Flat', style: theme.textTheme.subhead),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final db = value.round();
    return Column(
      children: [
        Text(db > 0 ? '+$db' : '$db', style: theme.textTheme.caption),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value,
                min: -kEqualizerMaxGainDb,
                max: kEqualizerMaxGainDb,
                divisions: 24,
                semanticFormatterCallback: (v) => '$label hertz, ${v.round()} decibels',
                onChanged: enabled ? onChanged : null,
                onChangeEnd: enabled ? onChangeEnd : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.caption),
      ],
    );
  }
}
