import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/equalizer_presets.dart';
import 'playback_state_store.dart';

/// The 10-band equalizer: holds the user's settings, saves them, and sends
/// them to the native audio tap (ios/Runner/AudioEffectsPlugin.swift),
/// which applies them to music playback live.
class EqualizerService extends ChangeNotifier {
  EqualizerService._();
  static final EqualizerService instance = EqualizerService._();

  static const _channel = MethodChannel('com.nautune.audio_effects');

  PlaybackStateStore? _store;
  bool _enabled = false;
  List<double> _gains = List<double>.filled(kEqualizerBands.length, 0);

  bool get enabled => _enabled;
  List<double> get gains => List.unmodifiable(_gains);
  EqualizerPreset get preset => EqualizerPreset.matching(_gains);

  /// Load saved settings and apply them.
  Future<void> initialize(PlaybackStateStore store) async {
    _store = store;
    final state = await store.load();
    if (state != null) {
      _enabled = state.equalizerEnabled;
      _gains = normalizeEqualizerGains(state.equalizerGains);
    }
    await _apply();
    notifyListeners();
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    _changed();
  }

  void setGain(int band, double gainDb) {
    if (band < 0 || band >= _gains.length) return;
    _gains = [..._gains]..[band] = gainDb.clamp(-kEqualizerMaxGainDb, kEqualizerMaxGainDb);
    _changed();
  }

  void applyPreset(EqualizerPreset preset) {
    if (preset == EqualizerPreset.custom) return;
    _gains = List<double>.of(preset.gains);
    _enabled = true;
    _changed();
  }

  void _changed() {
    notifyListeners();
    unawaited(_apply());
    unawaited(_store?.saveUiState(
      equalizerEnabled: _enabled,
      equalizerGains: List<double>.of(_gains),
    ));
  }

  Future<void> _apply() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<bool>('setEqualizer', {
        'enabled': _enabled,
        'preampDb': equalizerPreampDb(_gains),
        'gains': _gains,
      });
    } on MissingPluginException {
      // Not available (tests, other platforms).
    } catch (e) {
      debugPrint('🎚️ Equalizer update failed: $e');
    }
  }
}
