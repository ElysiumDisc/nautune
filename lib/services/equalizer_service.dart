import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import '../models/equalizer_preset.dart';

/// Abstract equalizer service interface.
/// Platform-specific implementations handle the actual audio processing.
abstract class EqualizerService {
  /// Get the platform-appropriate equalizer service instance
  static EqualizerService get instance {
    if (Platform.isLinux) {
      return LinuxEqualizerService.instance;
    } else if (Platform.isIOS) {
      return IOSEqualizerService.instance;
    }
    return _UnsupportedEqualizerService();
  }

  /// Whether EQ is available on this platform
  bool get isAvailable;

  /// Whether EQ is currently enabled
  bool get isEnabled;

  /// Stream of enabled state changes
  Stream<bool> get enabledStream;

  /// Current active preset
  EqualizerPreset get currentPreset;

  /// Stream of preset changes
  Stream<EqualizerPreset> get presetStream;

  /// Current band gains (10 values, -12 to +12 dB)
  List<double> get currentGains;

  /// Initialize the equalizer
  Future<bool> initialize();

  /// Enable or disable the equalizer
  Future<void> setEnabled(bool enabled);

  /// Set a single band's gain (-12 to +12 dB)
  Future<void> setBand(int bandIndex, double gainDb);

  /// Set all band gains at once
  Future<void> setAllBands(List<double> gains);

  /// Apply a preset
  Future<void> applyPreset(EqualizerPreset preset);

  /// Reset to flat response
  Future<void> reset();

  /// Dispose resources
  Future<void> dispose();
}

/// Linux equalizer using PulseAudio LADSPA plugin
class LinuxEqualizerService extends EqualizerService {
  static LinuxEqualizerService? _instance;
  static LinuxEqualizerService get instance => _instance ??= LinuxEqualizerService._();

  LinuxEqualizerService._();

  bool _initialized = false;
  bool _enabled = false;
  EqualizerPreset _currentPreset = BuiltInPresets.flat;
  List<double> _gains = List.filled(10, 0.0);
  int? _moduleId;

  final _enabledController = BehaviorSubject<bool>.seeded(false);
  final _presetController = BehaviorSubject<EqualizerPreset>.seeded(BuiltInPresets.flat);

  @override
  bool get isAvailable => Platform.isLinux;

  @override
  bool get isEnabled => _enabled;

  @override
  Stream<bool> get enabledStream => _enabledController.stream;

  @override
  EqualizerPreset get currentPreset => _currentPreset;

  @override
  Stream<EqualizerPreset> get presetStream => _presetController.stream;

  @override
  List<double> get currentGains => List.unmodifiable(_gains);

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (!Platform.isLinux) return false;

    try {
      // Check if pactl is available
      final result = await Process.run('which', ['pactl']);
      if (result.exitCode != 0) {
        debugPrint('🎛️ EQ: pactl not found');
        return false;
      }

      _initialized = true;
      debugPrint('🎛️ EQ: Linux equalizer initialized');
      return true;
    } catch (e) {
      debugPrint('🎛️ EQ: Init error: $e');
      return false;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!_initialized || _enabled == enabled) return;

    try {
      if (enabled) {
        await _loadEqualizerModule();
      } else {
        await _unloadEqualizerModule();
      }
      _enabled = enabled;
      _enabledController.add(_enabled);
      debugPrint('🎛️ EQ: ${enabled ? "Enabled" : "Disabled"}');
    } catch (e) {
      debugPrint('🎛️ EQ: Error setting enabled: $e');
    }
  }

  Future<void> _loadEqualizerModule() async {
    // Load LADSPA multiband EQ module
    // Using mbeq (15-band EQ) or similar
    try {
      final result = await Process.run('pactl', [
        'load-module',
        'module-ladspa-sink',
        'sink_name=nautune_eq',
        'sink_properties=device.description=Nautune_EQ',
        'plugin=mbeq_1197',
        'label=mbeq',
        'control=${_gains.map((g) => g.toString()).join(",")}',
      ]);

      if (result.exitCode == 0) {
        _moduleId = int.tryParse(result.stdout.toString().trim());
        debugPrint('🎛️ EQ: Loaded module $_moduleId');

        // Set as default sink
        await Process.run('pactl', ['set-default-sink', 'nautune_eq']);
      } else {
        // Fallback: try simpler equalizer approach using module-equalizer-sink
        debugPrint('🎛️ EQ: LADSPA failed, trying equalizer-sink...');
        final fallback = await Process.run('pactl', [
          'load-module',
          'module-equalizer-sink',
          'sink_name=nautune_eq',
        ]);
        if (fallback.exitCode == 0) {
          _moduleId = int.tryParse(fallback.stdout.toString().trim());
          debugPrint('🎛️ EQ: Loaded equalizer-sink module $_moduleId');
        }
      }
    } catch (e) {
      debugPrint('🎛️ EQ: Error loading module: $e');
    }
  }

  Future<void> _unloadEqualizerModule() async {
    if (_moduleId == null) return;

    try {
      await Process.run('pactl', ['unload-module', _moduleId.toString()]);
      debugPrint('🎛️ EQ: Unloaded module $_moduleId');
      _moduleId = null;
    } catch (e) {
      debugPrint('🎛️ EQ: Error unloading module: $e');
    }
  }

  @override
  Future<void> setBand(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= 10) return;
    _gains[bandIndex] = gainDb.clamp(-12.0, 12.0);
    await _applyGains();
  }

  @override
  Future<void> setAllBands(List<double> gains) async {
    if (gains.length != 10) return;
    _gains = gains.map((g) => g.clamp(-12.0, 12.0)).toList();
    await _applyGains();
  }

  Future<void> _applyGains() async {
    if (!_enabled || _moduleId == null) return;

    // Update EQ settings via pactl or dbus
    // This depends on which module we loaded
    try {
      // For module-equalizer-sink, use qpaeq or dbus
      // For now, we reload the module with new settings
      await _unloadEqualizerModule();
      await _loadEqualizerModule();
    } catch (e) {
      debugPrint('🎛️ EQ: Error applying gains: $e');
    }
  }

  @override
  Future<void> applyPreset(EqualizerPreset preset) async {
    _currentPreset = preset;
    _gains = List.from(preset.gains);
    _presetController.add(_currentPreset);
    await _applyGains();
    debugPrint('🎛️ EQ: Applied preset "${preset.name}"');
  }

  @override
  Future<void> reset() async {
    await applyPreset(BuiltInPresets.flat);
  }

  @override
  Future<void> dispose() async {
    await setEnabled(false);
    await _enabledController.close();
    await _presetController.close();
  }
}

/// iOS equalizer using AVAudioEngine
class IOSEqualizerService extends EqualizerService {
  static IOSEqualizerService? _instance;
  static IOSEqualizerService get instance => _instance ??= IOSEqualizerService._();

  IOSEqualizerService._();

  bool _initialized = false;
  bool _enabled = false;
  EqualizerPreset _currentPreset = BuiltInPresets.flat;
  List<double> _gains = List.filled(10, 0.0);

  final _enabledController = BehaviorSubject<bool>.seeded(false);
  final _presetController = BehaviorSubject<EqualizerPreset>.seeded(BuiltInPresets.flat);

  @override
  bool get isAvailable => Platform.isIOS;

  @override
  bool get isEnabled => _enabled;

  @override
  Stream<bool> get enabledStream => _enabledController.stream;

  @override
  EqualizerPreset get currentPreset => _currentPreset;

  @override
  Stream<EqualizerPreset> get presetStream => _presetController.stream;

  @override
  List<double> get currentGains => List.unmodifiable(_gains);

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (!Platform.isIOS) return false;

    // iOS EQ will be implemented via platform channel to native Swift code
    // For now, mark as initialized but not functional
    _initialized = true;
    debugPrint('🎛️ EQ: iOS equalizer initialized (UI only - native impl pending)');
    return true;
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!_initialized) return;
    _enabled = enabled;
    _enabledController.add(_enabled);
    // TODO: Call native iOS code via platform channel
    debugPrint('🎛️ EQ: iOS ${enabled ? "Enabled" : "Disabled"} (pending native impl)');
  }

  @override
  Future<void> setBand(int bandIndex, double gainDb) async {
    if (bandIndex < 0 || bandIndex >= 10) return;
    _gains[bandIndex] = gainDb.clamp(-12.0, 12.0);
    // TODO: Call native iOS code via platform channel
  }

  @override
  Future<void> setAllBands(List<double> gains) async {
    if (gains.length != 10) return;
    _gains = gains.map((g) => g.clamp(-12.0, 12.0)).toList();
    // TODO: Call native iOS code via platform channel
  }

  @override
  Future<void> applyPreset(EqualizerPreset preset) async {
    _currentPreset = preset;
    _gains = List.from(preset.gains);
    _presetController.add(_currentPreset);
    // TODO: Call native iOS code via platform channel
    debugPrint('🎛️ EQ: Applied preset "${preset.name}" (pending native impl)');
  }

  @override
  Future<void> reset() async {
    await applyPreset(BuiltInPresets.flat);
  }

  @override
  Future<void> dispose() async {
    await _enabledController.close();
    await _presetController.close();
  }
}

/// Unsupported platform stub
class _UnsupportedEqualizerService extends EqualizerService {
  @override
  bool get isAvailable => false;

  @override
  bool get isEnabled => false;

  @override
  Stream<bool> get enabledStream => Stream.value(false);

  @override
  EqualizerPreset get currentPreset => BuiltInPresets.flat;

  @override
  Stream<EqualizerPreset> get presetStream => Stream.value(BuiltInPresets.flat);

  @override
  List<double> get currentGains => List.filled(10, 0.0);

  @override
  Future<bool> initialize() async => false;

  @override
  Future<void> setEnabled(bool enabled) async {}

  @override
  Future<void> setBand(int bandIndex, double gainDb) async {}

  @override
  Future<void> setAllBands(List<double> gains) async {}

  @override
  Future<void> applyPreset(EqualizerPreset preset) async {}

  @override
  Future<void> reset() async {}

  @override
  Future<void> dispose() async {}
}
