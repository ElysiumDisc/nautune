import 'dart:async';
import 'dart:io';
import 'dart:math' show min, cos, sin, pi;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/essential_mix_track.dart';
import '../providers/connectivity_provider.dart';
import '../providers/demo_mode_provider.dart';
import '../models/waveform_data.dart';
import '../services/essential_mix_service.dart';
import '../services/ios_fft_service.dart';
import '../services/listening_analytics_service.dart';
import '../services/power_mode_service.dart';
import '../services/pulseaudio_fft_service.dart';
import '../services/waveform_service.dart';

/// Essential Mix Easter Egg screen - Full player UI for the Soulwax/2ManyDJs mix.
class EssentialMixScreen extends StatefulWidget {
  const EssentialMixScreen({super.key});

  @override
  State<EssentialMixScreen> createState() => _EssentialMixScreenState();
}

class _EssentialMixScreenState extends State<EssentialMixScreen>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _audioPlayer = AudioPlayer();
  late EssentialMixService _service;
  final EssentialMixTrack _track = const EssentialMixTrack();

  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _duration = Duration.zero;
  String? _errorMessage;

  // Position notifier for iOS performance - avoids full rebuilds on position change
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(Duration.zero);

  // Listening time tracking
  DateTime? _playStartTime;

  // Animation for artwork
  late AnimationController _artworkController;

  // FFT for visualizer (with smoothing)
  // Using ValueNotifier to avoid full widget rebuilds on FFT updates (iOS performance)
  StreamSubscription? _fftSubscription;
  final ValueNotifier<_FFTData> _fftNotifier = ValueNotifier(const _FFTData(0, 0, 0, 0));
  double _smoothBass = 0.0;
  double _smoothMid = 0.0;
  double _smoothTreble = 0.0;
  double _visualizerRotation = 0.0;
  // Asymmetric smoothing: FAST attack, SLOW decay (matches fullscreen visualizers)
  static const double _attackFactor = 0.6; // Fast response to increases
  // iOS needs faster decay (0.25) since FFT values tend to stay elevated
  static final double _decayFactor = Platform.isIOS ? 0.25 : 0.12;
  static const double _rotationSpeed = 0.02; // Radians per FFT frame

  // Frame rate throttling for FFT updates (~30fps)
  DateTime _lastFrameTime = DateTime.now();
  static const _frameInterval = Duration(milliseconds: 33);

  // Throttle position updates on iOS to reduce rebuilds
  DateTime _lastPositionUpdate = DateTime.now();
  static const _positionUpdateInterval = Duration(milliseconds: 250); // 4 updates/sec on iOS

  // Waveform data
  WaveformData? _waveformData;
  bool _isExtractingWaveform = false;

  // Track ID for waveform storage
  static const String _trackId = 'essential-mix-soulwax-2017';

  // Low power mode (iOS) - disables visualizer to save battery
  StreamSubscription? _powerModeSubscription;
  bool _visualizerEnabled = true;

  @override
  void initState() {
    super.initState();
    _service = EssentialMixService.instance;

    _artworkController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    // Only run animation controller on non-iOS (iOS uses FFT-synced rotation)
    if (!Platform.isIOS) {
      _artworkController.repeat();
    }

    // Listen to player state changes
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        final wasPlaying = _isPlaying;
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });

        // Track listening time
        if (_isPlaying && !wasPlaying) {
          _playStartTime = DateTime.now();
          _startFFT();
        } else if (!_isPlaying && wasPlaying) {
          _recordListenTime();
          _stopFFT();
        }
      }
    });

    // Position updates - use ValueNotifier on iOS to avoid full rebuilds
    _audioPlayer.onPositionChanged.listen((position) {
      if (!mounted) return;

      // On iOS, throttle position updates to reduce UI rebuilds
      if (Platform.isIOS) {
        final now = DateTime.now();
        if (now.difference(_lastPositionUpdate) < _positionUpdateInterval) {
          return; // Skip this update - don't trigger any rebuilds
        }
        _lastPositionUpdate = now;
      }

      // Update position notifier (triggers ValueListenableBuilder rebuilds only)
      _positionNotifier.value = position;

      // On non-iOS, also call setState for any widgets not using the notifier
      if (!Platform.isIOS) {
        setState(() {});
      }
    });

    // Duration updates
    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });

    // Player completion
    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        _positionNotifier.value = Duration.zero;
        setState(() {
          _isPlaying = false;
        });
        _recordListenTime();
        _stopFFT();
      }
    });

    // Listen to download service changes
    _service.addListener(_onServiceChanged);

    // Mark Essential Mix as discovered for the milestone
    _markDiscovered();

    // Load waveform if downloaded
    _loadWaveform();

    // Listen for iOS low power mode changes
    _initPowerModeListener();
  }

  void _initPowerModeListener() async {
    if (!Platform.isIOS) return;

    final powerService = PowerModeService.instance;

    // Ensure PowerModeService is initialized before checking state
    await powerService.initialize();

    if (!mounted) return;

    // Check initial state - visualizer ON by default, OFF only if low power mode
    final isLowPower = powerService.isLowPowerMode;
    if (isLowPower) {
      setState(() {
        _visualizerEnabled = false;
      });
      // Stop FFT if already playing
      if (_isPlaying) {
        _stopFFT(resetLevels: true);
      }
    }

    // Listen for changes
    _powerModeSubscription = powerService.lowPowerModeStream.listen((isLowPower) {
      if (!mounted) return;

      final wasEnabled = _visualizerEnabled;
      _visualizerEnabled = !isLowPower;

      // Only rebuild if state actually changed
      if (wasEnabled != _visualizerEnabled) {
        setState(() {});

        // Stop FFT capture if entering low power mode
        if (isLowPower && _isPlaying) {
          _stopFFT(resetLevels: true);
        }
        // Restart FFT if exiting low power mode and playing
        if (!isLowPower && _isPlaying && _service.isPlayingOffline) {
          _startFFT();
        }
      }
    });
  }

  void _markDiscovered() {
    final analytics = ListeningAnalyticsService();
    if (analytics.isInitialized) {
      analytics.markEssentialMixDiscovered();
    }
  }

  // Track previous download state to avoid unnecessary rebuilds
  bool _wasDownloading = false;
  bool _wasDownloaded = false;
  double _lastReportedProgress = 0.0;

  void _onServiceChanged() {
    if (!mounted) return;

    // Only rebuild on meaningful state changes, not every progress tick
    final isDownloading = _service.isDownloading;
    final isDownloaded = _service.isDownloaded;
    final progress = _service.downloadProgress;

    // Rebuild when:
    // 1. Download state changed (started/stopped/completed)
    // 2. During download: only every 5% progress to update indicator
    final stateChanged = (isDownloading != _wasDownloading) ||
        (isDownloaded != _wasDownloaded);
    final progressChanged = isDownloading &&
        (progress - _lastReportedProgress).abs() >= 0.05;

    _wasDownloading = isDownloading;
    _wasDownloaded = isDownloaded;
    if (progressChanged) _lastReportedProgress = progress;

    if (stateChanged || progressChanged) {
      setState(() {});
    }

    // When download completes, extract waveform
    if (isDownloaded && _waveformData == null && !_isExtractingWaveform) {
      _extractWaveform();
    }
  }

  @override
  void dispose() {
    _recordListenTime();
    _stopFFT(resetLevels: false);
    _powerModeSubscription?.cancel();
    _artworkController.dispose();
    _fftNotifier.dispose();
    _positionNotifier.dispose();
    _audioPlayer.dispose();
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  // ==================== FFT Integration ====================

  void _startFFT() async {
    if (!_service.isPlayingOffline) return;
    if (!_visualizerEnabled) return;

    final audioPath = _service.getPlaybackUrl();

    if (Platform.isIOS) {
      // iOS FFT using MTAudioProcessingTap
      // IMPORTANT: Must initialize before using - Essential Mix uses its own AudioPlayer,
      // not AudioPlayerService which normally initializes the FFT service
      await IOSFFTService.instance.initialize();
      await IOSFFTService.instance.setAudioUrl('file://$audioPath');
      await IOSFFTService.instance.startCapture();
      _fftSubscription = IOSFFTService.instance.fftStream.listen((data) {
        if (!mounted) return;

        // Throttle updates to ~30fps to avoid excessive rebuilds
        final now = DateTime.now();
        if (now.difference(_lastFrameTime) < _frameInterval) return;
        _lastFrameTime = now;

        // Update smoothed values with FAST attack, SLOW decay (matches fullscreen visualizers)
        _smoothBass += (data.bass - _smoothBass) * (data.bass > _smoothBass ? _attackFactor : _decayFactor);
        _smoothMid += (data.mid - _smoothMid) * (data.mid > _smoothMid ? _attackFactor : _decayFactor);
        _smoothTreble += (data.treble - _smoothTreble) * (data.treble > _smoothTreble ? _attackFactor : _decayFactor);
        _visualizerRotation += _rotationSpeed;

        // Only updates the visualizer widget, not the entire screen
        _fftNotifier.value = _FFTData(_smoothBass, _smoothMid, _smoothTreble, _visualizerRotation);
      });
    } else if (Platform.isLinux) {
      // Linux FFT using PulseAudio
      PulseAudioFFTService.instance.startCapture();
      _fftSubscription = PulseAudioFFTService.instance.fftStream.listen((data) {
        if (!mounted) return;

        // Throttle updates to ~30fps to avoid excessive rebuilds
        final now = DateTime.now();
        if (now.difference(_lastFrameTime) < _frameInterval) return;
        _lastFrameTime = now;

        // Update smoothed values with FAST attack, SLOW decay (matches fullscreen visualizers)
        _smoothBass += (data.bass - _smoothBass) * (data.bass > _smoothBass ? _attackFactor : _decayFactor);
        _smoothMid += (data.mid - _smoothMid) * (data.mid > _smoothMid ? _attackFactor : _decayFactor);
        _smoothTreble += (data.treble - _smoothTreble) * (data.treble > _smoothTreble ? _attackFactor : _decayFactor);
        _visualizerRotation += _rotationSpeed;

        // Only updates the visualizer widget, not the entire screen
        _fftNotifier.value = _FFTData(_smoothBass, _smoothMid, _smoothTreble, _visualizerRotation);
      });
    }
  }

  void _stopFFT({bool resetLevels = true}) {
    _fftSubscription?.cancel();
    _fftSubscription = null;

    if (Platform.isIOS) {
      IOSFFTService.instance.stopCapture();
    } else if (Platform.isLinux) {
      PulseAudioFFTService.instance.stopCapture();
    }

    // Reset FFT values (no setState needed - notifier handles visualizer update)
    if (resetLevels) {
      _smoothBass = 0.0;
      _smoothMid = 0.0;
      _smoothTreble = 0.0;
      _visualizerRotation = 0.0;
      _fftNotifier.value = const _FFTData(0, 0, 0, 0);
    }
  }

  // ==================== Waveform Integration ====================

  Future<void> _loadWaveform() async {
    if (!_service.isDownloaded) return;

    final waveformService = WaveformService.instance;
    await waveformService.initialize();

    final data = await waveformService.getWaveform(_trackId);
    if (data != null && mounted) {
      setState(() {
        _waveformData = data;
      });
    } else if (_service.isDownloaded) {
      // Waveform not found, extract it
      _extractWaveform();
    }
  }

  Future<void> _extractWaveform() async {
    if (_isExtractingWaveform || !_service.isDownloaded) return;

    setState(() {
      _isExtractingWaveform = true;
    });

    try {
      final audioPath = _service.getPlaybackUrl();
      final waveformService = WaveformService.instance;
      await waveformService.initialize();

      // Extract waveform and listen to progress
      await for (final progress in waveformService.extractWaveform(_trackId, audioPath)) {
        debugPrint('Essential Mix: Waveform extraction progress: ${(progress * 100).toStringAsFixed(0)}%');
      }

      // Load the extracted waveform
      final data = await waveformService.getWaveform(_trackId);
      if (data != null && mounted) {
        setState(() {
          _waveformData = data;
        });
      }
    } catch (e) {
      debugPrint('Essential Mix: Waveform extraction failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isExtractingWaveform = false;
        });
      }
    }
  }

  // ==================== Playback ====================

  void _recordListenTime() {
    if (_playStartTime != null) {
      final seconds = DateTime.now().difference(_playStartTime!).inSeconds;
      if (seconds > 0) {
        _service.recordListenTime(seconds);
      }
      _playStartTime = null;
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isLoading) return;

    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      // Check if downloaded - archive.org blocks direct streaming
      if (!_service.isPlayingOffline) {
        // Check if we're in demo mode or offline
        final connectivity = context.read<ConnectivityProvider>();
        final demoMode = context.read<DemoModeProvider>();
        final isOffline = !connectivity.networkAvailable || demoMode.isDemoMode;

        if (isOffline) {
          // Can't download in demo/offline mode
          setState(() {
            _errorMessage = demoMode.isDemoMode
                ? 'Download the Essential Mix while online to listen in demo mode'
                : 'Download required - connect to internet to download';
          });
          return;
        }

        // Not downloaded - prompt to download
        setState(() {
          _errorMessage = 'Download required for playback';
        });

        // Auto-start download if not already downloading
        if (!_service.isDownloading) {
          _service.startDownload();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Starting download... Playback will begin automatically when ready.'),
              backgroundColor: Theme.of(context).colorScheme.primary,
              duration: const Duration(seconds: 3),
            ),
          );

          // Wait for download to complete, then play
          _waitForDownloadAndPlay();
        }
        return;
      }

      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      try {
        final playbackUrl = _service.getPlaybackUrl();

        debugPrint('Essential Mix: Playing from local: $playbackUrl');

        await _audioPlayer.setSourceDeviceFile(playbackUrl);

        // Set duration from track metadata
        setState(() {
          _duration = _track.duration;
        });

        await _audioPlayer.resume();

        setState(() {
          _isLoading = false;
        });
      } catch (e) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to play: $e';
        });
        debugPrint('Essential Mix playback error: $e');
      }
    }
  }

  /// Wait for download to complete, then auto-play.
  void _waitForDownloadAndPlay() {
    void listener() {
      if (!mounted) {
        _service.removeListener(listener);
        return;
      }

      if (_service.isDownloaded) {
        _service.removeListener(listener);
        // Clear error and play
        setState(() {
          _errorMessage = null;
        });
        _togglePlayPause();
      } else if (_service.state.status == EssentialMixDownloadStatus.failed) {
        _service.removeListener(listener);
        setState(() {
          _errorMessage = 'Download failed: ${_service.state.errorMessage}';
        });
      }
    }

    _service.addListener(listener);
  }

  Future<void> _seekTo(Duration position) async {
    await _audioPlayer.seek(position);

    // Sync FFT shadow player position on iOS
    if (Platform.isIOS && _isPlaying) {
      await IOSFFTService.instance.syncPosition(position.inMilliseconds / 1000.0);
    }
  }

  void _seekFromTap(double localX, BuildContext context) {
    if (_duration.inMilliseconds <= 0) return;

    // Get the width of the progress bar area (padding: 24 on each side)
    final progressBarWidth = MediaQuery.of(context).size.width - 48;
    final progress = (localX / progressBarWidth).clamp(0.0, 1.0);
    final newPosition = Duration(milliseconds: (progress * _duration.inMilliseconds).toInt());
    _seekTo(newPosition);
  }

  void _showDownloadOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => _buildDownloadSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: theme.colorScheme.onSurface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _audioPlayer.stop();
            Navigator.of(context).pop();
          },
        ),
        actions: [
          IconButton(
            icon: Icon(
              _service.isDownloaded ? Icons.download_done : Icons.download,
              color: _service.isDownloaded ? Colors.green : theme.colorScheme.onSurface,
            ),
            onPressed: _showDownloadOptions,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Artwork with radial visualizer
            Expanded(
              flex: 3,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: _buildArtworkWithVisualizer(theme),
                ),
              ),
            ),

                // Track info
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Text(
                        _track.name,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _track.artist,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_track.album} • ${_track.date.year}',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Seekable waveform/progress bar (combined)
                // Wrapped in ValueListenableBuilder to avoid full screen rebuilds on iOS
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: _positionNotifier,
                    builder: (context, position, _) {
                      final localProgress = _duration.inMilliseconds > 0
                          ? position.inMilliseconds / _duration.inMilliseconds
                          : 0.0;
                      return Column(
                        children: [
                          // Seekable waveform or simple progress bar
                          GestureDetector(
                            onTapDown: (details) => _seekFromTap(details.localPosition.dx, context),
                            onHorizontalDragUpdate: (details) => _seekFromTap(details.localPosition.dx, context),
                            child: SizedBox(
                              height: 56,
                              child: _waveformData != null
                                  ? _buildSeekableWaveform(theme, localProgress)
                                  : _buildSimpleProgressBar(theme, localProgress),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(position),
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  _formatDuration(_duration),
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // Play/Pause button
                GestureDetector(
                  onTap: _togglePlayPause,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.4),
                          blurRadius: Platform.isIOS ? 10 : 20,
                          spreadRadius: Platform.isIOS ? 1 : 2,
                        ),
                      ],
                    ),
                    child: Center(
                      child: _isLoading
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.onPrimary,
                              ),
                            )
                          : Icon(
                              _isPlaying ? Icons.pause : Icons.play_arrow,
                              color: theme.colorScheme.onPrimary,
                              size: 36,
                            ),
                    ),
                  ),
                ),

                // Error/Info message
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _errorMessage!.contains('Download required')
                            ? theme.colorScheme.primary.withValues(alpha: 0.2)
                            : theme.colorScheme.error.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _errorMessage!.contains('Download required')
                              ? theme.colorScheme.primary.withValues(alpha: 0.5)
                              : theme.colorScheme.error.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _errorMessage!.contains('Download required')
                                ? Icons.download
                                : Icons.error_outline,
                            color: _errorMessage!.contains('Download required')
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(
                                color: _errorMessage!.contains('Download required')
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.error,
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 16),

                // Download status indicator
                if (_service.isDownloading)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        LinearProgressIndicator(
                          value: _service.downloadProgress,
                          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Downloading... ${(_service.downloadProgress * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Offline indicator
                if (_service.isDownloaded && _service.isPlayingOffline)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.download_done, color: Colors.green, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'Playing offline',
                          style: TextStyle(
                            color: Colors.green.withValues(alpha: 0.8),
                            fontSize: 12,
                          ),
                        ),
                        if (_waveformData != null) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.graphic_eq, color: Colors.green, size: 14),
                        ],
                      ],
                    ),
                  ),

                // Waveform extraction status
                if (_isExtractingWaveform)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Generating waveform...',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Credit
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                'Source: ${_track.credit}',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  fontSize: 10,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtworkWithVisualizer(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate sizes - fit within available space (accounting for padding)
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final maxSize = min(availableWidth, availableHeight);

        // Don't exceed container - visualizer fits within maxSize
        final visualizerSize = maxSize;
        final artworkSize = maxSize * 0.60; // Smaller artwork = more room for bars
        final maxBarLength = (maxSize - artworkSize) / 2 - 4; // Longer bars

        // Show visualizer only when playing, downloaded, and enabled (not in low power mode)
        final showVisualizer = _isPlaying && _service.isDownloaded && _visualizerEnabled;

        return SizedBox(
          width: visualizerSize,
          height: visualizerSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Radial FFT visualizer (behind artwork) - wrapped in RepaintBoundary
              // On iOS: ValueListenableBuilder isolates rebuilds to visualizer only
              // On Linux: AnimatedBuilder for smooth 60fps rotation
              if (showVisualizer)
                RepaintBoundary(
                  child: Platform.isIOS
                      ? ValueListenableBuilder<_FFTData>(
                          valueListenable: _fftNotifier,
                          builder: (context, fft, _) {
                            return CustomPaint(
                              size: Size(visualizerSize, visualizerSize),
                              painter: _RadialVisualizerPainter(
                                bass: fft.bass,
                                mid: fft.mid,
                                treble: fft.treble,
                                color: theme.colorScheme.primary,
                                innerRadius: artworkSize / 2 + 6,
                                maxBarLength: maxBarLength,
                                rotation: fft.rotation,
                              ),
                            );
                          },
                        )
                      : AnimatedBuilder(
                          animation: _artworkController,
                          builder: (context, _) {
                            return CustomPaint(
                              size: Size(visualizerSize, visualizerSize),
                              painter: _RadialVisualizerPainter(
                                bass: _fftNotifier.value.bass,
                                mid: _fftNotifier.value.mid,
                                treble: _fftNotifier.value.treble,
                                color: theme.colorScheme.primary,
                                innerRadius: artworkSize / 2 + 6,
                                maxBarLength: maxBarLength,
                                rotation: _artworkController.value * 2 * pi,
                              ),
                            );
                          },
                        ),
                ),

              // Album artwork (centered)
              SizedBox(
                width: artworkSize,
                height: artworkSize,
                child: _buildArtwork(theme),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSeekableWaveform(ThemeData theme, double progress) {
    if (_waveformData == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final scrubberX = progress * constraints.maxWidth;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Waveform - wrapped in RepaintBoundary for isolation
            RepaintBoundary(
              child: CustomPaint(
                painter: _WaveformPainter(
                  waveform: _waveformData!,
                  progress: progress.clamp(0.0, 1.0),
                  playedColor: theme.colorScheme.primary,
                  unplayedColor: theme.colorScheme.primary.withValues(alpha: 0.25),
                ),
                size: Size(constraints.maxWidth, 56),
              ),
            ),
            // Scrubber line
            Positioned(
              left: scrubberX - 1.5,
              top: 0,
              bottom: 0,
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface,
                  borderRadius: BorderRadius.circular(1.5),
                  // Reduced shadow on iOS for performance
                  boxShadow: Platform.isIOS ? null : [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.5),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSimpleProgressBar(ThemeData theme, double progress) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scrubberX = progress * constraints.maxWidth;

        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Background track
            Container(
              height: 6,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Progress fill
            Container(
              height: 6,
              width: scrubberX,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Scrubber dot
            Positioned(
              left: scrubberX - 8,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  // Reduced shadow on iOS for performance
                  boxShadow: Platform.isIOS ? null : [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.4),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildArtwork(ThemeData theme) {
    final artworkUrl = _service.getArtworkUrl();
    final isLocal = artworkUrl.startsWith('file://');

    Widget artworkImage;
    if (isLocal) {
      final path = artworkUrl.substring(7);
      artworkImage = Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(theme),
      );
    } else {
      artworkImage = Image.network(
        artworkUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholderArt(theme),
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return _buildPlaceholderArt(theme, isLoading: true);
        },
      );
    }

    // On iOS: reduce shadow blur for performance (no AnimatedBuilder needed)
    // Shadow only changes based on _isPlaying state, not animation
    final shadowBlur = Platform.isIOS
        ? (_isPlaying ? 20.0 : 10.0)
        : (_isPlaying ? 40.0 : 20.0);
    final shadowSpread = Platform.isIOS
        ? (_isPlaying ? 4.0 : 2.0)
        : (_isPlaying ? 10.0 : 5.0);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withValues(alpha: _isPlaying ? 0.6 : 0.3),
            blurRadius: shadowBlur,
            spreadRadius: shadowSpread,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 1,
          child: artworkImage,
        ),
      ),
    );
  }

  Widget _buildPlaceholderArt(ThemeData theme, {bool isLoading = false}) {
    return Container(
      color: theme.colorScheme.primary.withValues(alpha: 0.3),
      child: Center(
        child: isLoading
            ? CircularProgressIndicator(color: theme.colorScheme.primary.withValues(alpha: 0.5), strokeWidth: 2)
            : Icon(Icons.album, color: theme.colorScheme.primary.withValues(alpha: 0.5), size: 64),
      ),
    );
  }

  Widget _buildDownloadSheet() {
    final theme = Theme.of(context);

    return StatefulBuilder(
      builder: (context, setSheetState) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DOWNLOAD FOR OFFLINE',
                style: TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 16),

              // File info
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.audiotrack, color: theme.colorScheme.primary),
                title: Text(
                  _track.name,
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
                subtitle: Text(
                  '${_track.formattedDuration} • ${_track.formattedFileSize}',
                  style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 12),
                ),
              ),

              Divider(color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),

              // Download/Delete button
              if (_service.isDownloading)
                Column(
                  children: [
                    LinearProgressIndicator(
                      value: _service.downloadProgress,
                      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Downloading... ${(_service.downloadProgress * 100).toStringAsFixed(0)}%',
                            style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _service.cancelDownload();
                            setSheetState(() {});
                          },
                          child: Text('Cancel', style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      ],
                    ),
                  ],
                )
              else if (_service.isDownloaded)
                FutureBuilder<EssentialMixStorageStats>(
                  future: _service.getStorageStats(),
                  builder: (context, snapshot) {
                    final stats = snapshot.data;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green, size: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'Downloaded',
                              style: TextStyle(color: Colors.green),
                            ),
                          ],
                        ),
                        if (stats != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Audio: ${stats.formattedAudio}',
                            style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 12),
                          ),
                          if (stats.artworkBytes > 0)
                            Text(
                              'Artwork: ${stats.formattedArtwork}',
                              style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 12),
                            ),
                          Text(
                            'Total: ${stats.formattedTotal}',
                            style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: theme.colorScheme.surface,
                                  title: Text(
                                    'Delete Download?',
                                    style: TextStyle(color: theme.colorScheme.onSurface),
                                  ),
                                  content: Text(
                                    'Remove the offline copy including audio and artwork? (${stats?.formattedTotal ?? "~234 MB"})',
                                    style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context, true),
                                      child: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await _service.deleteDownload();
                                // Also delete waveform
                                _waveformData = null;
                                setSheetState(() {});
                                if (context.mounted) {
                                  setState(() {});
                                }
                              }
                            },
                            icon: Icon(Icons.delete, color: theme.colorScheme.error),
                            label: Text('Delete Download', style: TextStyle(color: theme.colorScheme.error)),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: theme.colorScheme.error),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                )
              else
                Builder(
                  builder: (context) {
                    final connectivity = context.watch<ConnectivityProvider>();
                    final demoMode = context.watch<DemoModeProvider>();
                    final isOffline = !connectivity.networkAvailable || demoMode.isDemoMode;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isOffline
                              ? (demoMode.isDemoMode
                                  ? 'Download the Essential Mix while online to listen in demo mode.\n(${_track.formattedFileSize})'
                                  : 'Connect to internet to download.\n(${_track.formattedFileSize})')
                              : 'Download for offline playback with FFT visualizer and waveform support.\n(${_track.formattedFileSize})',
                          style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.7), fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: isOffline
                                ? null
                                : () async {
                                    _service.startDownload();
                                    setSheetState(() {});
                                  },
                            icon: const Icon(Icons.download),
                            label: Text(isOffline ? 'Offline' : 'Download'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                              disabledBackgroundColor: theme.colorScheme.primary.withValues(alpha: 0.3),
                              disabledForegroundColor: theme.colorScheme.onPrimary.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),

              // Listen time stats
              if (_service.listenTimeSeconds > 0) ...[
                const SizedBox(height: 24),
                Divider(color: theme.colorScheme.onSurface.withValues(alpha: 0.2)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.access_time, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                  title: Text(
                    'Total Listen Time',
                    style: TextStyle(color: theme.colorScheme.onSurface),
                  ),
                  trailing: Text(
                    _service.formattedListenTime,
                    style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
                  ),
                ),
              ],

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Enhanced radial visualizer with gradient colors, bass pulse ring, and smooth rotation
/// Optimized for performance - no blur effects, pre-computed geometry and colors
class _RadialVisualizerPainter extends CustomPainter {
  final double bass;
  final double mid;
  final double treble;
  final Color color;
  final double innerRadius;
  final double maxBarLength;
  final double rotation; // Slow rotation from animation controller

  // Bar count
  static final int _barCount = Platform.isIOS ? 32 : 48;

  // Pre-computed static geometry (computed once, reused across all instances)
  static List<double>? _baseAngles; // Base angles without rotation
  static List<_BarWeights>? _weights;
  static int _cachedBarCount = 0;

  // Cached gradient colors (recomputed only when primary color changes)
  static Color? _cachedPrimaryColor;
  static List<Color>? _gradientColors;

  // Reusable paint objects
  late final Paint _barPaint;
  late final Paint _ringPaint;

  _RadialVisualizerPainter({
    required this.bass,
    required this.mid,
    required this.treble,
    required this.color,
    required this.innerRadius,
    required this.maxBarLength,
    required this.rotation,
  }) {
    _barPaint = Paint()
      ..strokeWidth = Platform.isIOS ? 4.0 : 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    _ringPaint = Paint()
      ..style = PaintingStyle.stroke;

    // Initialize static geometry cache if needed
    if (_baseAngles == null || _cachedBarCount != _barCount) {
      _initGeometryCache();
    }

    // Cache gradient colors when primary color changes
    if (_cachedPrimaryColor != color) {
      _cacheGradientColors(color);
    }
  }

  /// Pre-compute base angles and weights (only done once)
  static void _initGeometryCache() {
    _cachedBarCount = _barCount;
    _baseAngles = List<double>.filled(_barCount, 0.0);
    _weights = List<_BarWeights>.filled(_barCount, const _BarWeights(0, 0, 0, 1));

    final angleStep = (2 * pi) / _barCount;

    for (int i = 0; i < _barCount; i++) {
      _baseAngles![i] = i * angleStep - pi / 2; // Start from top

      // Pre-compute bass/mid/treble weights for this position
      final position = i / _barCount;
      final bassWeight = cos(position * 2 * pi).clamp(0.0, 1.0);
      final trebleWeight = (-cos(position * 2 * pi)).clamp(0.0, 1.0);
      final midWeight = sin(position * 2 * pi).abs();
      final total = bassWeight + midWeight + trebleWeight;
      _weights![i] = _BarWeights(bassWeight, midWeight, trebleWeight, total);
    }
  }

  /// Pre-compute gradient colors for each bar position (only when color changes)
  static void _cacheGradientColors(Color primaryColor) {
    _cachedPrimaryColor = primaryColor;
    _gradientColors = List<Color>.filled(_barCount, primaryColor);

    final hsl = HSLColor.fromColor(primaryColor);
    final baseHue = hsl.hue;
    final baseSaturation = hsl.saturation;
    final baseLightness = hsl.lightness;

    for (int i = 0; i < _barCount; i++) {
      final position = i / _barCount;
      final hueShift = -40 + (position * 80); // -40 to +40 degrees
      final newHue = (baseHue + hueShift) % 360;
      final saturation = (baseSaturation * 0.95).clamp(0.0, 1.0);
      final lightness = (baseLightness * 1.1).clamp(0.35, 0.8);

      _gradientColors![i] = HSLColor.fromAHSL(1.0, newHue, saturation, lightness).toColor();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final center = Offset(centerX, centerY);

    // === Bass pulse ring (sonar ping effect) ===
    if (bass > 0.15) {
      final ringRadius = innerRadius - 2 + (bass * 10);
      _ringPaint
        ..color = color.withValues(alpha: bass * 0.5)
        ..strokeWidth = 2.0 + bass * 2;
      canvas.drawCircle(center, ringRadius, _ringPaint);

      // Second outer ring on strong bass
      if (bass > 0.4) {
        final outerRingRadius = innerRadius + maxBarLength * bass * 0.4;
        _ringPaint
          ..color = color.withValues(alpha: (bass - 0.4) * 0.4)
          ..strokeWidth = 1.5;
        canvas.drawCircle(center, outerRingRadius, _ringPaint);
      }
    }

    // === Draw bars with gradient colors and rotation ===
    for (int i = 0; i < _barCount; i++) {
      final w = _weights![i];
      final amplitude = w.total == 0
          ? (bass + mid + treble) / 3
          : ((bass * w.bass + mid * w.mid + treble * w.treble) / w.total).clamp(0.0, 1.0);

      final barLength = amplitude * maxBarLength + 4;

      // Apply rotation to base angle
      final angle = _baseAngles![i] + rotation;
      final cosA = cos(angle);
      final sinA = sin(angle);

      final startX = centerX + innerRadius * cosA;
      final startY = centerY + innerRadius * sinA;
      final endX = centerX + (innerRadius + barLength) * cosA;
      final endY = centerY + (innerRadius + barLength) * sinA;

      // Gradient color with amplitude-based alpha
      _barPaint.color = _gradientColors![i].withValues(alpha: 0.6 + amplitude * 0.4);
      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), _barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadialVisualizerPainter oldDelegate) {
    // Always repaint when rotation changes (smooth animation)
    // Small tolerance for FFT values
    const tolerance = 0.005;
    return rotation != oldDelegate.rotation ||
        (bass - oldDelegate.bass).abs() > tolerance ||
        (mid - oldDelegate.mid).abs() > tolerance ||
        (treble - oldDelegate.treble).abs() > tolerance ||
        color != oldDelegate.color;
  }
}

/// Pre-computed bass/mid/treble weights for a bar position
class _BarWeights {
  final double bass;
  final double mid;
  final double treble;
  final double total;

  const _BarWeights(this.bass, this.mid, this.treble, this.total);
}

/// Waveform painter - optimized with cached Paint objects
class _WaveformPainter extends CustomPainter {
  final WaveformData waveform;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  late final Paint _playedPaint;
  late final Paint _unplayedPaint;

  _WaveformPainter({
    required this.waveform,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  }) {
    _playedPaint = Paint()
      ..color = playedColor
      ..style = PaintingStyle.fill;
    _unplayedPaint = Paint()
      ..color = unplayedColor
      ..style = PaintingStyle.fill;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final amplitudes = waveform.amplitudes;
    if (amplitudes.isEmpty) return;

    final barWidth = size.width / amplitudes.length;
    final progressIndex = (progress * amplitudes.length).floor();

    for (int i = 0; i < amplitudes.length; i++) {
      final amplitude = amplitudes[i].clamp(0.0, 1.0);
      final barHeight = amplitude * size.height * 0.9;
      final x = i * barWidth;
      final y = (size.height - barHeight) / 2;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth * 0.8, barHeight),
          const Radius.circular(1),
        ),
        i <= progressIndex ? _playedPaint : _unplayedPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    // Use tolerance to avoid repainting for tiny progress changes
    // 0.002 = ~0.2% change needed to repaint (for a 2hr mix, ~14 seconds)
    const progressTolerance = 0.002;
    return (progress - oldDelegate.progress).abs() > progressTolerance ||
        waveform != oldDelegate.waveform ||
        playedColor != oldDelegate.playedColor ||
        unplayedColor != oldDelegate.unplayedColor;
  }
}

/// Immutable FFT data for ValueNotifier (avoids full widget rebuilds on iOS)
class _FFTData {
  final double bass;
  final double mid;
  final double treble;
  final double rotation;

  const _FFTData(this.bass, this.mid, this.treble, this.rotation);
}
