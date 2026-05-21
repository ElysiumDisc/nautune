import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../services/listening_analytics_service.dart';

/// Ambient sound mixer screen with vertical sliders for Rain, Thunder, Campfire, Waves, and Loon.
class RelaxModeScreen extends StatefulWidget {
  const RelaxModeScreen({super.key});

  @override
  State<RelaxModeScreen> createState() => _RelaxModeScreenState();
}

class _RelaxModeScreenState extends State<RelaxModeScreen> {
  // Audio players for each ambient sound
  late final AudioPlayer _rainPlayer;
  late final AudioPlayer _thunderPlayer;
  late final AudioPlayer _campfirePlayer;
  late final AudioPlayer _wavePlayer;
  late final AudioPlayer _loonPlayer;

  // Volume levels (0.0 to 1.0)
  double _rainVolume = 0.0;
  double _thunderVolume = 0.0;
  double _campfireVolume = 0.0;
  double _waveVolume = 0.0;
  double _loonVolume = 0.0;

  // Track initialization state
  bool _initialized = false;

  // Analytics tracking — fully event-driven. Each sound has an optional
  // start timestamp set when its volume transitions 0 → >0 and cleared
  // (with accumulated time flushed) on >0 → 0 or on dispose. Active-listening
  // is the union of any sound being on; tracked the same way via
  // `_anyActiveStartedAt`. No periodic timer.
  int _activeListeningMs = 0; // Time when at least one sound is playing
  int _rainUsageMs = 0;
  int _thunderUsageMs = 0;
  int _campfireUsageMs = 0;
  int _waveUsageMs = 0;
  int _loonUsageMs = 0;

  DateTime? _anyActiveStartedAt;
  DateTime? _rainStartedAt;
  DateTime? _thunderStartedAt;
  DateTime? _campfireStartedAt;
  DateTime? _waveStartedAt;
  DateTime? _loonStartedAt;

  @override
  void initState() {
    super.initState();
    _initAudio();
  }

  bool get _isAnySoundActive =>
      _rainVolume > 0 ||
      _thunderVolume > 0 ||
      _campfireVolume > 0 ||
      _waveVolume > 0 ||
      _loonVolume > 0;

  /// Update the "any sound active" window when a slider changes.
  void _refreshAnyActiveTracking() {
    final active = _isAnySoundActive;
    if (active && _anyActiveStartedAt == null) {
      _anyActiveStartedAt = DateTime.now();
    } else if (!active && _anyActiveStartedAt != null) {
      _activeListeningMs +=
          DateTime.now().difference(_anyActiveStartedAt!).inMilliseconds;
      _anyActiveStartedAt = null;
    }
  }

  /// Flush a single sound's open interval into its accumulator.
  void _flushSound(DateTime? startedAt, void Function(int deltaMs) accumulate) {
    if (startedAt == null) return;
    accumulate(DateTime.now().difference(startedAt).inMilliseconds);
  }

  Future<void> _initAudio() async {
    _rainPlayer = AudioPlayer();
    _thunderPlayer = AudioPlayer();
    _campfirePlayer = AudioPlayer();
    _wavePlayer = AudioPlayer();
    _loonPlayer = AudioPlayer();

    await Future.wait([
      _rainPlayer.setReleaseMode(ReleaseMode.loop),
      _thunderPlayer.setReleaseMode(ReleaseMode.loop),
      _campfirePlayer.setReleaseMode(ReleaseMode.loop),
      _wavePlayer.setReleaseMode(ReleaseMode.loop),
      _loonPlayer.setReleaseMode(ReleaseMode.loop),
    ]);

    await Future.wait([
      _rainPlayer.setSource(AssetSource('relax/rain.mp3')),
      _thunderPlayer.setSource(AssetSource('relax/thunder.mp3')),
      _campfirePlayer.setSource(AssetSource('relax/campfire.mp3')),
      _wavePlayer.setSource(AssetSource('relax/wave.mp3')),
      _loonPlayer.setSource(AssetSource('relax/loon.mp3')),
    ]);

    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  @override
  void dispose() {
    // Flush any still-open per-sound intervals so the final session reflects
    // listening up to the moment the user leaves the screen.
    _flushSound(_rainStartedAt, (ms) => _rainUsageMs += ms);
    _flushSound(_thunderStartedAt, (ms) => _thunderUsageMs += ms);
    _flushSound(_campfireStartedAt, (ms) => _campfireUsageMs += ms);
    _flushSound(_waveStartedAt, (ms) => _waveUsageMs += ms);
    _flushSound(_loonStartedAt, (ms) => _loonUsageMs += ms);
    _flushSound(_anyActiveStartedAt, (ms) => _activeListeningMs += ms);

    // Record session to analytics only if user actually listened (> 5 seconds of active sound)
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized && _activeListeningMs > 5000) {
      analytics.recordRelaxModeSession(
        sessionDuration: Duration(milliseconds: _activeListeningMs),
        rainUsage: Duration(milliseconds: _rainUsageMs),
        thunderUsage: Duration(milliseconds: _thunderUsageMs),
        campfireUsage: Duration(milliseconds: _campfireUsageMs),
        waveUsage: Duration(milliseconds: _waveUsageMs),
        loonUsage: Duration(milliseconds: _loonUsageMs),
      );
    }

    // Dispose audio players
    if (_initialized) {
      _rainPlayer.dispose();
      _thunderPlayer.dispose();
      _campfirePlayer.dispose();
      _wavePlayer.dispose();
      _loonPlayer.dispose();
    }
    super.dispose();
  }

  void _onRainVolumeChanged(double value) {
    final wasOn = _rainVolume > 0;
    final isOn = value > 0;
    setState(() => _rainVolume = value);
    _rainPlayer.setVolume(value);
    if (isOn && _rainPlayer.state != PlayerState.playing) {
      _rainPlayer.resume();
    }
    if (isOn && !wasOn) {
      _rainStartedAt = DateTime.now();
    } else if (!isOn && wasOn) {
      _flushSound(_rainStartedAt, (ms) => _rainUsageMs += ms);
      _rainStartedAt = null;
    }
    _refreshAnyActiveTracking();
    HapticService.selectionClick();
  }

  void _onThunderVolumeChanged(double value) {
    final wasOn = _thunderVolume > 0;
    final isOn = value > 0;
    setState(() => _thunderVolume = value);
    _thunderPlayer.setVolume(value);
    if (isOn && _thunderPlayer.state != PlayerState.playing) {
      _thunderPlayer.resume();
    }
    if (isOn && !wasOn) {
      _thunderStartedAt = DateTime.now();
    } else if (!isOn && wasOn) {
      _flushSound(_thunderStartedAt, (ms) => _thunderUsageMs += ms);
      _thunderStartedAt = null;
    }
    _refreshAnyActiveTracking();
    HapticService.selectionClick();
  }

  void _onCampfireVolumeChanged(double value) {
    final wasOn = _campfireVolume > 0;
    final isOn = value > 0;
    setState(() => _campfireVolume = value);
    _campfirePlayer.setVolume(value);
    if (isOn && _campfirePlayer.state != PlayerState.playing) {
      _campfirePlayer.resume();
    }
    if (isOn && !wasOn) {
      _campfireStartedAt = DateTime.now();
    } else if (!isOn && wasOn) {
      _flushSound(_campfireStartedAt, (ms) => _campfireUsageMs += ms);
      _campfireStartedAt = null;
    }
    _refreshAnyActiveTracking();
    HapticService.selectionClick();
  }

  void _onWaveVolumeChanged(double value) {
    final wasOn = _waveVolume > 0;
    final isOn = value > 0;
    setState(() => _waveVolume = value);
    _wavePlayer.setVolume(value);
    if (isOn && _wavePlayer.state != PlayerState.playing) {
      _wavePlayer.resume();
    }
    if (isOn && !wasOn) {
      _waveStartedAt = DateTime.now();
    } else if (!isOn && wasOn) {
      _flushSound(_waveStartedAt, (ms) => _waveUsageMs += ms);
      _waveStartedAt = null;
    }
    _refreshAnyActiveTracking();
    HapticService.selectionClick();
  }

  void _onLoonVolumeChanged(double value) {
    final wasOn = _loonVolume > 0;
    final isOn = value > 0;
    setState(() => _loonVolume = value);
    _loonPlayer.setVolume(value);
    if (isOn && _loonPlayer.state != PlayerState.playing) {
      _loonPlayer.resume();
    }
    if (isOn && !wasOn) {
      _loonStartedAt = DateTime.now();
    } else if (!isOn && wasOn) {
      _flushSound(_loonStartedAt, (ms) => _loonUsageMs += ms);
      _loonStartedAt = null;
    }
    _refreshAnyActiveTracking();
    HapticService.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.waves),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: _initialized
            ? _buildSliders(theme)
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildSliders(ThemeData theme) {
    // Use responsive padding for narrow screens (5 sliders need more space)
    final screenWidth = MediaQuery.of(context).size.width;
    final horizontalPadding = screenWidth < 400 ? 16.0 : 32.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildAmbientSlider(
            theme: theme,
            icon: Icons.water_drop,
            color: theme.colorScheme.primary,
            value: _rainVolume,
            onChanged: _onRainVolumeChanged,
          ),
          _buildAmbientSlider(
            theme: theme,
            icon: Icons.thunderstorm,
            color: theme.colorScheme.secondary,
            value: _thunderVolume,
            onChanged: _onThunderVolumeChanged,
          ),
          _buildAmbientSlider(
            theme: theme,
            icon: Icons.local_fire_department,
            color: theme.colorScheme.tertiary,
            value: _campfireVolume,
            onChanged: _onCampfireVolumeChanged,
          ),
          _buildAmbientSlider(
            theme: theme,
            icon: Icons.waves,
            color: Colors.cyan,
            value: _waveVolume,
            onChanged: _onWaveVolumeChanged,
          ),
          _buildAmbientSlider(
            theme: theme,
            icon: Icons.nights_stay,
            color: Colors.indigo,
            value: _loonVolume,
            onChanged: _onLoonVolumeChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildAmbientSlider({
    required ThemeData theme,
    required IconData icon,
    required Color color,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    // Responsive sizing for narrow screens
    final screenWidth = MediaQuery.of(context).size.width;
    final iconSize = screenWidth < 400 ? 24.0 : 32.0;

    return Expanded(
      child: Column(
        children: [
          // Icon
          Icon(
            icon,
            color: value > 0 ? color : theme.colorScheme.onSurfaceVariant,
            size: iconSize,
          ),
          const SizedBox(height: 12),
          // Vertical slider
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: screenWidth < 400 ? 4 : 6,
                  activeTrackColor: color,
                  inactiveTrackColor: color.withValues(alpha: 0.15),
                  thumbColor: color,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: screenWidth < 400 ? 6 : 8,
                  ),
                  overlayShape: RoundSliderOverlayShape(
                    overlayRadius: screenWidth < 400 ? 12 : 16,
                  ),
                  overlayColor: color.withValues(alpha: 0.12),
                ),
                child: Slider(
                  value: value,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
