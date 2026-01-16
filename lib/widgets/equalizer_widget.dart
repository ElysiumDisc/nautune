import 'dart:async';
import 'package:flutter/material.dart';
import '../models/equalizer_preset.dart';
import '../services/equalizer_service.dart';

/// Beautiful 10-band graphic equalizer widget
class EqualizerWidget extends StatefulWidget {
  const EqualizerWidget({super.key});

  @override
  State<EqualizerWidget> createState() => _EqualizerWidgetState();
}

class _EqualizerWidgetState extends State<EqualizerWidget> {
  late EqualizerService _eqService;
  StreamSubscription? _enabledSub;
  StreamSubscription? _presetSub;

  bool _enabled = false;
  EqualizerPreset _currentPreset = BuiltInPresets.flat;
  List<double> _gains = List.filled(10, 0.0);
  bool _isCustom = false;

  @override
  void initState() {
    super.initState();
    _eqService = EqualizerService.instance;
    _initEQ();
  }

  Future<void> _initEQ() async {
    await _eqService.initialize();

    _enabled = _eqService.isEnabled;
    _currentPreset = _eqService.currentPreset;
    _gains = List.from(_eqService.currentGains);

    _enabledSub = _eqService.enabledStream.listen((enabled) {
      if (mounted) setState(() => _enabled = enabled);
    });

    _presetSub = _eqService.presetStream.listen((preset) {
      if (mounted) {
        setState(() {
          _currentPreset = preset;
          _gains = List.from(preset.gains);
          _isCustom = false;
        });
      }
    });

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _enabledSub?.cancel();
    _presetSub?.cancel();
    super.dispose();
  }

  void _onBandChanged(int index, double value) {
    setState(() {
      _gains[index] = value;
      _isCustom = true;
    });
    _eqService.setBand(index, value);
  }

  void _onPresetSelected(EqualizerPreset preset) {
    _eqService.applyPreset(preset);
  }

  void _toggleEnabled(bool value) {
    _eqService.setEnabled(value);
  }

  void _resetToFlat() {
    _eqService.reset();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAvailable = _eqService.isAvailable;

    if (!isAvailable) {
      return _buildUnavailable(theme);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with toggle
        _buildHeader(theme),
        const SizedBox(height: 16),

        // Preset selector
        _buildPresetSelector(theme),
        const SizedBox(height: 20),

        // EQ sliders
        AnimatedOpacity(
          opacity: _enabled ? 1.0 : 0.4,
          duration: const Duration(milliseconds: 200),
          child: AbsorbPointer(
            absorbing: !_enabled,
            child: _buildEQSliders(theme),
          ),
        ),

        const SizedBox(height: 12),

        // Reset button
        if (_enabled && _isCustom)
          Center(
            child: TextButton.icon(
              onPressed: _resetToFlat,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reset to Flat'),
            ),
          ),
      ],
    );
  }

  Widget _buildUnavailable(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(
            Icons.equalizer,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            'Equalizer not available',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'EQ is supported on Linux and iOS',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        Icon(
          Icons.equalizer,
          color: _enabled ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Equalizer',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Switch(
          value: _enabled,
          onChanged: _toggleEnabled,
        ),
      ],
    );
  }

  Widget _buildPresetSelector(ThemeData theme) {
    return Row(
      children: [
        Text(
          'Preset:',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: DropdownButton<String>(
              value: _isCustom ? null : _currentPreset.id,
              hint: Text(
                _isCustom ? 'Custom' : _currentPreset.name,
                style: TextStyle(
                  color: _isCustom
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                  fontWeight: _isCustom ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              items: BuiltInPresets.all.map((preset) {
                return DropdownMenuItem(
                  value: preset.id,
                  child: Text(preset.name),
                );
              }).toList(),
              onChanged: _enabled
                  ? (id) {
                      if (id != null) {
                        final preset = BuiltInPresets.getById(id);
                        if (preset != null) {
                          _onPresetSelected(preset);
                        }
                      }
                    }
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEQSliders(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          // dB labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 8),
              Text(
                '+12',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),
              Text(
                'dB',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),

          // Sliders
          SizedBox(
            height: 180,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(10, (index) {
                return _buildBandSlider(theme, index);
              }),
            ),
          ),

          // Zero line indicator
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(width: 8),
              Text(
                '-12',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),
            ],
          ),

          const SizedBox(height: 8),

          // Frequency labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(10, (index) {
              return SizedBox(
                width: 32,
                child: Text(
                  kEqualizerLabels[index],
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildBandSlider(ThemeData theme, int index) {
    final gain = _gains[index];
    final normalizedValue = (gain + 12) / 24; // Convert -12..+12 to 0..1

    // Theme-aware colors
    final activeColor = gain > 0
        ? theme.colorScheme.primary
        : theme.colorScheme.secondary;
    final inactiveColor = theme.colorScheme.primary.withValues(alpha: 0.15);
    final thumbColor = gain != 0
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return SizedBox(
      width: 32,
      child: Column(
        children: [
          Expanded(
            child: RotatedBox(
              quarterTurns: 3, // Rotate slider to be vertical
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 6,
                  activeTrackColor: activeColor,
                  inactiveTrackColor: inactiveColor,
                  thumbColor: thumbColor,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                  overlayColor: theme.colorScheme.primary.withValues(alpha: 0.12),
                ),
                child: Slider(
                  value: normalizedValue,
                  onChanged: (value) {
                    final newGain = (value * 24) - 12; // Convert 0..1 to -12..+12
                    _onBandChanged(index, newGain);
                  },
                ),
              ),
            ),
          ),
          // Current value indicator
          Text(
            gain >= 0 ? '+${gain.round()}' : '${gain.round()}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: gain != 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              fontWeight: gain != 0 ? FontWeight.w600 : FontWeight.normal,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}
