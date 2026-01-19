import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../services/haptic_service.dart';
import '../services/listening_analytics_service.dart';

/// Ambient sound mixer screen with vertical sliders for Rain, Thunder, and Campfire.
class RelaxModeScreen extends StatefulWidget {
  const RelaxModeScreen({super.key});

  @override
  State<RelaxModeScreen> createState() => _RelaxModeScreenState();
}

class _RelaxModeScreenState extends State<RelaxModeScreen> {
  // Audio players for each ambient sound
  final AudioPlayer _rainPlayer = AudioPlayer();
  final AudioPlayer _thunderPlayer = AudioPlayer();
  final AudioPlayer _campfirePlayer = AudioPlayer();

  // Volume levels (0.0 to 1.0)
  double _rainVolume = 0.0;
  double _thunderVolume = 0.0;
  double _campfireVolume = 0.0;

  // Track initialization state
  bool _initialized = false;

  // Analytics tracking
  final Stopwatch _sessionStopwatch = Stopwatch();
  Timer? _usageTimer;
  int _rainUsageMs = 0;
  int _thunderUsageMs = 0;
  int _campfireUsageMs = 0;

  @override
  void initState() {
    super.initState();
    _initAudio();
    _initAnalytics();
  }

  void _initAnalytics() {
    // Mark Relax Mode as discovered for the milestone
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized) {
      analytics.markRelaxModeDiscovered();
    }
  }

  void _startTracking() {
    if (_sessionStopwatch.isRunning) return;

    // Start session timer
    _sessionStopwatch.start();

    // Track slider usage every second (pure time - any volume > 0 counts)
    _usageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_rainVolume > 0) {
        _rainUsageMs += 1000;
      }
      if (_thunderVolume > 0) {
        _thunderUsageMs += 1000;
      }
      if (_campfireVolume > 0) {
        _campfireUsageMs += 1000;
      }
    });
  }

  Future<void> _initAudio() async {
    // Set release mode to loop for continuous ambient playback
    await _rainPlayer.setReleaseMode(ReleaseMode.loop);
    await _thunderPlayer.setReleaseMode(ReleaseMode.loop);
    await _campfirePlayer.setReleaseMode(ReleaseMode.loop);

    // Set initial volume to 0
    await _rainPlayer.setVolume(0.0);
    await _thunderPlayer.setVolume(0.0);
    await _campfirePlayer.setVolume(0.0);

    // Load and start playing (at volume 0)
    await _rainPlayer.setSource(AssetSource('relax/rain.mp3'));
    await _thunderPlayer.setSource(AssetSource('relax/thunder.mp3'));
    await _campfirePlayer.setSource(AssetSource('relax/campfire.mp3'));

    if (mounted) {
      setState(() => _initialized = true);
      // Start tracking only after audio is ready
      _startTracking();
    }
  }

  @override
  void dispose() {
    // Stop tracking
    _usageTimer?.cancel();
    _sessionStopwatch.stop();

    // Record session to analytics
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized && _sessionStopwatch.elapsed.inSeconds > 5) {
      analytics.recordRelaxModeSession(
        sessionDuration: _sessionStopwatch.elapsed,
        rainUsage: Duration(milliseconds: _rainUsageMs),
        thunderUsage: Duration(milliseconds: _thunderUsageMs),
        campfireUsage: Duration(milliseconds: _campfireUsageMs),
      );
    }

    // Dispose audio players
    _rainPlayer.dispose();
    _thunderPlayer.dispose();
    _campfirePlayer.dispose();
    super.dispose();
  }

  void _onRainVolumeChanged(double value) {
    setState(() => _rainVolume = value);
    _rainPlayer.setVolume(value);
    if (value > 0 && _rainPlayer.state != PlayerState.playing) {
      _rainPlayer.resume();
    }
    HapticService.selectionClick();
  }

  void _onThunderVolumeChanged(double value) {
    setState(() => _thunderVolume = value);
    _thunderPlayer.setVolume(value);
    if (value > 0 && _thunderPlayer.state != PlayerState.playing) {
      _thunderPlayer.resume();
    }
    HapticService.selectionClick();
  }

  void _onCampfireVolumeChanged(double value) {
    setState(() => _campfireVolume = value);
    _campfirePlayer.setVolume(value);
    if (value > 0 && _campfirePlayer.state != PlayerState.playing) {
      _campfirePlayer.resume();
    }
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
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
    return SizedBox(
      width: 64,
      child: Column(
        children: [
          // Icon
          Icon(
            icon,
            color: value > 0 ? color : theme.colorScheme.onSurfaceVariant,
            size: 32,
          ),
          const SizedBox(height: 16),
          // Vertical slider
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 6,
                  activeTrackColor: color,
                  inactiveTrackColor: color.withValues(alpha: 0.15),
                  thumbColor: color,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
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
