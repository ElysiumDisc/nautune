import 'dart:async';

import 'package:flutter/material.dart';

import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key, required this.audioService});

  final AudioPlayerService audioService;

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen> {
  StreamSubscription? _trackSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _playingSub;

  @override
  void initState() {
    super.initState();
    _trackSub = widget.audioService.currentTrackStream.listen((_) {
      if (mounted) setState(() {});
    });
    _positionSub = widget.audioService.positionStream.listen((_) {
      if (mounted) setState(() {});
    });
    _playingSub = widget.audioService.playingStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  double _sliderValue(Duration position, Duration duration) {
    if (duration.inMilliseconds > 0) {
      final max = duration.inMilliseconds.toDouble();
      final raw = position.inMilliseconds.toDouble();
      if (raw < 0) return 0.0;
      if (raw > max) return max;
      return raw;
    }
    return 0.0;
  }

  double _sliderMax(Duration position, Duration duration) {
    if (duration.inMilliseconds > 0) {
      return duration.inMilliseconds.toDouble();
    }
    final pos = position.inMilliseconds.toDouble();
    if (pos <= 0) {
      return 1.0;
    }
    return pos;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 600;

    return StreamBuilder<bool>(
      stream: widget.audioService.playingStream,
      builder: (context, playingSnapshot) {
        final isPlaying = playingSnapshot.data ?? false;

        return StreamBuilder<Duration>(
          stream: widget.audioService.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;

            return StreamBuilder<Duration?>(
              stream: widget.audioService.durationStream,
              builder: (context, durationSnapshot) {
                final duration = durationSnapshot.data ?? Duration.zero;
                final track = widget.audioService.currentTrack;

                if (track == null) {
                  return Scaffold(
                    appBar: AppBar(
                      title: const Text('Now Playing'),
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    body: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.music_note, size: 64, color: theme.colorScheme.secondary),
                          const SizedBox(height: 16),
                          Text(
                            'No track playing',
                            style: theme.textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final artwork = _buildArtwork(
                  track: track,
                  isDesktop: isDesktop,
                  theme: theme,
                );

                return Scaffold(
                  body: SafeArea(
                    child: Column(
                      children: [
                        // Header
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.expand_more),
                                onPressed: () => Navigator.of(context).pop(),
                                tooltip: 'Close',
                              ),
                              const Spacer(),
                              Text(
                                'Now Playing',
                                style: theme.textTheme.titleMedium,
                              ),
                              const Spacer(),
                              const SizedBox(width: 48),
                            ],
                          ),
                        ),

                        Expanded(
                          child: SingleChildScrollView(
                            padding: EdgeInsets.symmetric(
                              horizontal: isDesktop ? size.width * 0.2 : 32,
                              vertical: 16,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Artwork
                                SizedBox(
                                  width: isDesktop ? 400 : size.width - 64,
                                  child: artwork,
                                ),
                                
                                SizedBox(height: isDesktop ? 48 : 32),

                                // Track Info
                                Text(
                                  track.name,
                                  style: (isDesktop
                                          ? theme.textTheme.headlineMedium
                                          : theme.textTheme.headlineSmall)
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                
                                const SizedBox(height: 12),
                                
                                Text(
                                  track.displayArtist,
                                  style: (isDesktop
                                          ? theme.textTheme.titleLarge
                                          : theme.textTheme.titleMedium)
                                      ?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                
                                if (track.album != null) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    track.album!,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],

                                SizedBox(height: isDesktop ? 48 : 32),

                                // Progress
                                Column(
                                  children: [
                                    SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 4,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 8,
                                        ),
                                        overlayShape: const RoundSliderOverlayShape(
                                          overlayRadius: 16,
                                        ),
                                      ),
                                      child: Slider(
                                        value: _sliderValue(position, duration),
                                        min: 0,
                                        max: _sliderMax(position, duration),
                                        onChanged: duration.inMilliseconds > 0
                                            ? (value) {
                                                widget.audioService.seek(
                                                  Duration(milliseconds: value.toInt()),
                                                );
                                              }
                                            : null,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            _formatDuration(position),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                          Text(
                                            _formatDuration(duration),
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),

                                SizedBox(height: isDesktop ? 48 : 32),

                                // Controls
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_previous,
                                        size: isDesktop ? 48 : 40,
                                      ),
                                      onPressed: () => widget.audioService.previous(),
                                      tooltip: 'Previous',
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 16),

                                    IconButton(
                                      icon: Icon(
                                        Icons.stop,
                                        size: isDesktop ? 40 : 32,
                                      ),
                                      onPressed: () => widget.audioService.stop(),
                                      tooltip: 'Stop',
                                      color: theme.colorScheme.error,
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 16),

                                    Container(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: theme.colorScheme.primary,
                                        boxShadow: [
                                          BoxShadow(
                                            color: theme.colorScheme.primary.withOpacity(0.4),
                                            blurRadius: 16,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: IconButton(
                                        icon: Icon(
                                          isPlaying ? Icons.pause : Icons.play_arrow,
                                          size: isDesktop ? 56 : 48,
                                        ),
                                        onPressed: () => widget.audioService.playPause(),
                                        color: theme.colorScheme.onPrimary,
                                        tooltip: isPlaying ? 'Pause' : 'Play',
                                      ),
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 16),

                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_next,
                                        size: isDesktop ? 48 : 40,
                                      ),
                                      onPressed: () => widget.audioService.next(),
                                      tooltip: 'Next',
                                    ),
                                  ],
                                ),

                                SizedBox(height: isDesktop ? 32 : 24),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

  Widget _buildArtwork({
    required JellyfinTrack track,
    required bool isDesktop,
    required ThemeData theme,
  }) {
    final borderRadius = BorderRadius.circular(isDesktop ? 24 : 16);
    final maxWidth = isDesktop ? 800 : 500;
    final imageUrl = track.artworkUrl(maxWidth: maxWidth);
    final placeholder = Icon(
      Icons.album,
      size: isDesktop ? 120 : 80,
      color: theme.colorScheme.onPrimaryContainer,
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: theme.colorScheme.primaryContainer,
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withOpacity(0.3),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: AspectRatio(
          aspectRatio: 1,
          child: imageUrl != null
              ? Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder,
                )
              : placeholder,
        ),
      ),
    );
  }
