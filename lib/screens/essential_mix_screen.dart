import 'dart:async';
import 'dart:io';

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
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _errorMessage;

  // Listening time tracking
  DateTime? _playStartTime;

  // Animation for artwork
  late AnimationController _artworkController;

  // FFT for visualizer (with smoothing)
  StreamSubscription? _fftSubscription;
  double _bassLevel = 0.0;
  double _midLevel = 0.0;
  double _trebleLevel = 0.0;
  // Smoothed values for less twitchy animation
  double _smoothBass = 0.0;
  double _smoothMid = 0.0;
  double _smoothTreble = 0.0;
  static const double _smoothingFactor = 0.08; // Lower = smoother

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
    )..repeat();

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

    // Position updates
    _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() {
          _position = position;
        });
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
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
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

  void _initPowerModeListener() {
    if (!Platform.isIOS) return;

    final powerService = PowerModeService.instance;

    // Check initial state
    _visualizerEnabled = !powerService.isLowPowerMode;

    // Listen for changes
    _powerModeSubscription = powerService.lowPowerModeStream.listen((isLowPower) {
      if (mounted) {
        setState(() {
          _visualizerEnabled = !isLowPower;
        });
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

  void _onServiceChanged() {
    if (mounted) {
      setState(() {});
      // When download completes, extract waveform
      if (_service.isDownloaded && _waveformData == null && !_isExtractingWaveform) {
        _extractWaveform();
      }
    }
  }

  @override
  void dispose() {
    _recordListenTime();
    _stopFFT(resetLevels: false); // Don't call setState during dispose
    _powerModeSubscription?.cancel();
    _artworkController.dispose();
    _audioPlayer.dispose();
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  // ==================== FFT Integration ====================

  void _startFFT() {
    if (!_service.isPlayingOffline) return;
    if (!_visualizerEnabled) return; // Disabled in low power mode

    final audioPath = _service.getPlaybackUrl();

    if (Platform.isIOS) {
      // iOS FFT using MTAudioProcessingTap
      IOSFFTService.instance.setAudioUrl('file://$audioPath');
      IOSFFTService.instance.startCapture();
      _fftSubscription = IOSFFTService.instance.fftStream.listen((data) {
        if (mounted) {
          setState(() {
            _bassLevel = data.bass;
            _midLevel = data.mid;
            _trebleLevel = data.treble;
            // Apply smoothing (lerp toward target)
            _smoothBass += (_bassLevel - _smoothBass) * _smoothingFactor;
            _smoothMid += (_midLevel - _smoothMid) * _smoothingFactor;
            _smoothTreble += (_trebleLevel - _smoothTreble) * _smoothingFactor;
          });
        }
      });
    } else if (Platform.isLinux) {
      // Linux FFT using PulseAudio
      PulseAudioFFTService.instance.startCapture();
      _fftSubscription = PulseAudioFFTService.instance.fftStream.listen((data) {
        if (mounted) {
          setState(() {
            _bassLevel = data.bass;
            _midLevel = data.mid;
            _trebleLevel = data.treble;
            // Apply smoothing (lerp toward target)
            _smoothBass += (_bassLevel - _smoothBass) * _smoothingFactor;
            _smoothMid += (_midLevel - _smoothMid) * _smoothingFactor;
            _smoothTreble += (_trebleLevel - _smoothTreble) * _smoothingFactor;
          });
        }
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

    // Only reset levels and call setState if widget is still mounted
    // and we're not being called from dispose
    if (resetLevels && mounted) {
      _bassLevel = 0.0;
      _midLevel = 0.0;
      _trebleLevel = 0.0;
      _smoothBass = 0.0;
      _smoothMid = 0.0;
      _smoothTreble = 0.0;
      setState(() {});
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
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Seekable waveform or simple progress bar
                      GestureDetector(
                        onTapDown: (details) => _seekFromTap(details.localPosition.dx, context),
                        onHorizontalDragUpdate: (details) => _seekFromTap(details.localPosition.dx, context),
                        child: SizedBox(
                          height: 56,
                          child: _waveformData != null
                              ? _buildSeekableWaveform(theme, progress)
                              : _buildSimpleProgressBar(theme, progress),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _formatDuration(_position),
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
                          blurRadius: 20,
                          spreadRadius: 2,
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
        // Calculate sizes - visualizer ring around artwork
        final maxSize = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        final visualizerSize = maxSize;
        final artworkSize = maxSize * 0.68; // Artwork size (bigger)
        final visualizerOuterSize = maxSize * 1.2; // Bars extend 20% beyond container

        // Show visualizer only when playing, downloaded, and enabled (not in low power mode)
        final showVisualizer = _isPlaying && _service.isDownloaded && _visualizerEnabled;

        return SizedBox(
          width: visualizerSize,
          height: visualizerSize,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none, // Allow bars to extend beyond
            children: [
              // Radial FFT visualizer (behind artwork)
              if (showVisualizer)
                CustomPaint(
                  size: Size(visualizerOuterSize, visualizerOuterSize),
                  painter: _RadialVisualizerPainter(
                    bass: _smoothBass,
                    mid: _smoothMid,
                    treble: _smoothTreble,
                    color: theme.colorScheme.primary,
                    innerRadius: artworkSize / 2 + 6, // Start just outside artwork
                    maxBarLength: (visualizerOuterSize - artworkSize) / 2 - 6, // Bars can be longer
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
            // Waveform
            CustomPaint(
              painter: _WaveformPainter(
                waveform: _waveformData!,
                progress: progress.clamp(0.0, 1.0),
                playedColor: theme.colorScheme.primary,
                unplayedColor: theme.colorScheme.primary.withValues(alpha: 0.25),
              ),
              size: Size(constraints.maxWidth, 56),
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
                  boxShadow: [
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
                  boxShadow: [
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

    return AnimatedBuilder(
      animation: _artworkController,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: _isPlaying ? 0.6 : 0.3),
                blurRadius: _isPlaying ? 40 : 20,
                spreadRadius: _isPlaying ? 10 : 5,
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
      },
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

/// Radial visualizer painter - draws bars radiating outward from center circle
class _RadialVisualizerPainter extends CustomPainter {
  final double bass;
  final double mid;
  final double treble;
  final Color color;
  final double innerRadius;
  final double maxBarLength;

  static const int _barCount = 64;
  static const double _pi = 3.14159265359;

  _RadialVisualizerPainter({
    required this.bass,
    required this.mid,
    required this.treble,
    required this.color,
    required this.innerRadius,
    required this.maxBarLength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final angleStep = (2 * _pi) / _barCount;
    final barWidth = 3.0;

    for (int i = 0; i < _barCount; i++) {
      // Smooth distribution: each bar blends bass/mid/treble based on position
      final position = i / _barCount;
      final amplitude = _getAmplitudeForPosition(position);

      final barLength = amplitude * maxBarLength + 6; // Min 6px
      final angle = i * angleStep - _pi / 2; // Start from top

      final cosA = _cos(angle);
      final sinA = _sin(angle);

      final startX = center.dx + innerRadius * cosA;
      final startY = center.dy + innerRadius * sinA;
      final endX = center.dx + (innerRadius + barLength) * cosA;
      final endY = center.dy + (innerRadius + barLength) * sinA;

      final paint = Paint()
        ..color = color.withValues(alpha: 0.6 + amplitude * 0.4)
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), paint);
    }
  }

  // Smooth amplitude based on position around circle
  // No random variation - just smooth interpolation
  double _getAmplitudeForPosition(double position) {
    // Sine-wave distribution for smooth visual
    // Bass dominates bottom (position ~0.75-1.0 and 0-0.25)
    // Treble dominates top (position ~0.25-0.75)
    // Mid blends in between

    final bassWeight = _cos(position * 2 * _pi).clamp(0.0, 1.0);
    final trebleWeight = (-_cos(position * 2 * _pi)).clamp(0.0, 1.0);
    final midWeight = _sin(position * 2 * _pi).abs();

    final total = bassWeight + midWeight + trebleWeight;
    if (total == 0) return (bass + mid + treble) / 3;

    return ((bass * bassWeight + mid * midWeight + treble * trebleWeight) / total)
        .clamp(0.0, 1.0);
  }

  static double _cos(double x) {
    x = x % (2 * _pi);
    if (x > _pi) x -= 2 * _pi;
    final x2 = x * x;
    return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720 + x2 * x2 * x2 * x2 / 40320;
  }

  static double _sin(double x) {
    return _cos(x - _pi / 2);
  }

  @override
  bool shouldRepaint(covariant _RadialVisualizerPainter oldDelegate) {
    return bass != oldDelegate.bass ||
        mid != oldDelegate.mid ||
        treble != oldDelegate.treble;
  }
}

/// Waveform painter
class _WaveformPainter extends CustomPainter {
  final WaveformData waveform;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  _WaveformPainter({
    required this.waveform,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

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

      final paint = Paint()
        ..color = i <= progressIndex ? playedColor : unplayedColor
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth * 0.8, barHeight),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        waveform != oldDelegate.waveform;
  }
}
