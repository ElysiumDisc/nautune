import 'dart:async';

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
  // Audio players for each ambient sound — lazy-initialized on first use
  AudioPlayer? _rainPlayer;
  AudioPlayer? _thunderPlayer;
  AudioPlayer? _campfirePlayer;
  AudioPlayer? _wavePlayer;
  AudioPlayer? _loonPlayer;

  // Volume levels (0.0 to 1.0)
  double _rainVolume = 0.0;
  double _thunderVolume = 0.0;
  double _campfireVolume = 0.0;
  double _waveVolume = 0.0;
  double _loonVolume = 0.0;

  // Track initialization state
  bool _initialized = false;

  // Analytics tracking
  Timer? _usageTimer;
  int _activeListeningMs = 0; // Time when at least one sound is playing
  int _rainUsageMs = 0;
  int _thunderUsageMs = 0;
  int _campfireUsageMs = 0;
  int _waveUsageMs = 0;
  int _loonUsageMs = 0;

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
    if (_usageTimer != null) return;

    // Track slider usage every second
    // Only count time when at least one sound is actively playing
    _usageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final isAnySoundActive = _rainVolume > 0 || _thunderVolume > 0 ||
          _campfireVolume > 0 || _waveVolume > 0 || _loonVolume > 0;

      // Only count active listening time (when at least one sound is on)
      if (isAnySoundActive) {
        _activeListeningMs += 1000;
      }

      // Track individual sound usage
      if (_rainVolume > 0) {
        _rainUsageMs += 1000;
      }
      if (_thunderVolume > 0) {
        _thunderUsageMs += 1000;
      }
      if (_campfireVolume > 0) {
        _campfireUsageMs += 1000;
      }
      if (_waveVolume > 0) {
        _waveUsageMs += 1000;
      }
      if (_loonVolume > 0) {
        _loonUsageMs += 1000;
      }
    });
  }

  Future<void> _initAudio() async {
    // Players are lazy-initialized on first volume > 0
    // Just mark as ready so UI renders
    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  /// Lazy-initialize and start an audio player for an ambient sound.
  Future<AudioPlayer> _ensurePlayer(AudioPlayer? player, String assetName) async {
    if (player != null) return player;
    final p = AudioPlayer();
    await p.setReleaseMode(ReleaseMode.loop);
    await p.setVolume(0.0);
    await p.setSource(AssetSource(assetName));
    return p;
  }

  @override
  void dispose() {
    // Stop tracking
    _usageTimer?.cancel();

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

    // Dispose audio players (only those that were initialized)
    _rainPlayer?.dispose();
    _thunderPlayer?.dispose();
    _campfirePlayer?.dispose();
    _wavePlayer?.dispose();
    _loonPlayer?.dispose();
    super.dispose();
  }

  Future<void> _onRainVolumeChanged(double value) async {
    setState(() => _rainVolume = value);
    if (value > 0) {
      _rainPlayer = await _ensurePlayer(_rainPlayer, 'relax/rain.mp3');
      _rainPlayer!.setVolume(value);
      if (_rainPlayer!.state != PlayerState.playing) _rainPlayer!.resume();
      _ensureTrackingStarted();
    } else {
      _rainPlayer?.setVolume(0);
    }
    HapticService.selectionClick();
  }

  Future<void> _onThunderVolumeChanged(double value) async {
    setState(() => _thunderVolume = value);
    if (value > 0) {
      _thunderPlayer = await _ensurePlayer(_thunderPlayer, 'relax/thunder.mp3');
      _thunderPlayer!.setVolume(value);
      if (_thunderPlayer!.state != PlayerState.playing) _thunderPlayer!.resume();
      _ensureTrackingStarted();
    } else {
      _thunderPlayer?.setVolume(0);
    }
    HapticService.selectionClick();
  }

  Future<void> _onCampfireVolumeChanged(double value) async {
    setState(() => _campfireVolume = value);
    if (value > 0) {
      _campfirePlayer = await _ensurePlayer(_campfirePlayer, 'relax/campfire.mp3');
      _campfirePlayer!.setVolume(value);
      if (_campfirePlayer!.state != PlayerState.playing) _campfirePlayer!.resume();
      _ensureTrackingStarted();
    } else {
      _campfirePlayer?.setVolume(0);
    }
    HapticService.selectionClick();
  }

  Future<void> _onWaveVolumeChanged(double value) async {
    setState(() => _waveVolume = value);
    if (value > 0) {
      _wavePlayer = await _ensurePlayer(_wavePlayer, 'relax/wave.mp3');
      _wavePlayer!.setVolume(value);
      if (_wavePlayer!.state != PlayerState.playing) _wavePlayer!.resume();
      _ensureTrackingStarted();
    } else {
      _wavePlayer?.setVolume(0);
    }
    HapticService.selectionClick();
  }

  Future<void> _onLoonVolumeChanged(double value) async {
    setState(() => _loonVolume = value);
    if (value > 0) {
      _loonPlayer = await _ensurePlayer(_loonPlayer, 'relax/loon.mp3');
      _loonPlayer!.setVolume(value);
      if (_loonPlayer!.state != PlayerState.playing) _loonPlayer!.resume();
      _ensureTrackingStarted();
    } else {
      _loonPlayer?.setVolume(0);
    }
    HapticService.selectionClick();
  }

  /// Start analytics tracking only when at least one sound is active.
  void _ensureTrackingStarted() {
    if (_usageTimer == null) {
      _startTracking();
    }
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
