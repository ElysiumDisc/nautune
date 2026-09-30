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

  /// Slider drags change a band many times a second: the native tap gets at
  /// most one update per [_applyInterval] (always ending with the latest
  /// values), and the settings are saved once the changes settle.
  static const Duration _applyInterval = Duration(milliseconds: 50);
  static const Duration _saveDelay = Duration(milliseconds: 500);

  PlaybackStateStore? _store;
  Timer? _applyTimer;
  bool _applyPending = false;
  Timer? _saveTimer;
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
    _scheduleApply();
    _scheduleSave();
  }

  /// Throttle: apply now, then coalesce further changes within
  /// [_applyInterval] into one trailing apply of the latest settings.
  void _scheduleApply() {
    if (_applyTimer != null) {
      _applyPending = true;
      return;
    }
    unawaited(_apply());
    _applyTimer = Timer(_applyInterval, () {
      _applyTimer = null;
      if (_applyPending) {
        _applyPending = false;
        _scheduleApply();
      }
    });
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final store = _store;
    if (store == null) return;
    await store.saveUiState(
      equalizerEnabled: _enabled,
      equalizerGains: List<double>.of(_gains),
    );
  }

  /// Save a pending change now (e.g. when a slider drag ends).
  Future<void> flush() async {
    final timer = _saveTimer;
    if (timer == null) return;
    timer.cancel();
    _saveTimer = null;
    await _save();
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
