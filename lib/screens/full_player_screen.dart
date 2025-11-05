import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({
    super.key, 
    required this.audioService,
    required this.appState,
  });

  final AudioPlayerService audioService;
  final NautuneAppState appState;

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

  void _seekFromGesture(double dx, double maxWidth, Duration duration) {
    if (duration.inMilliseconds > 0 && maxWidth > 0) {
      final ratio = (dx / maxWidth).clamp(0.0, 1.0);
      final newPosition = Duration(
        milliseconds: (duration.inMilliseconds * ratio).toInt(),
      );
      widget.audioService.seek(newPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 600;

    return StreamBuilder<JellyfinTrack?>(
      stream: widget.audioService.currentTrackStream,
      initialData: widget.audioService.currentTrack,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data;

        return StreamBuilder<bool>(
          stream: widget.audioService.playingStream,
          initialData: widget.audioService.isPlaying,
          builder: (context, playingSnapshot) {
            final isPlaying = playingSnapshot.data ?? false;

            return StreamBuilder<Duration>(
              stream: widget.audioService.positionStream,
              initialData: widget.audioService.currentPosition,
              builder: (context, positionSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;

                return StreamBuilder<Duration?>(
                  stream: widget.audioService.durationStream,
                  initialData: track?.duration,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? track?.duration ?? Duration.zero;

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
                            // Header - Compact
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.expand_more),
                                    onPressed: () => Navigator.of(context).pop(),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'Now Playing',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const Spacer(),
                                  const SizedBox(width: 48),
                                ],
                              ),
                            ),

                            Expanded(
                              child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: isDesktop ? size.width * 0.2 : 24,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                // Artwork
                                SizedBox(
                                  width: isDesktop ? 350 : size.width * 0.7,
                                  child: artwork,
                                ),
                                
                                
                                // Track Info - Compact
                                Text(
                                  track.name,
                                  style: (isDesktop
                                          ? theme.textTheme.headlineSmall
                                          : theme.textTheme.titleLarge)
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                
                                const SizedBox(height: 8),
                                
                                Text(
                                  track.displayArtist,
                                  style: (isDesktop
                                          ? theme.textTheme.titleMedium
                                          : theme.textTheme.bodyLarge)
                                      ?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                
                                if (track.album != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    track.album!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],

                                // Progress
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    void scrub(double dx) => _seekFromGesture(
                                          dx,
                                          constraints.maxWidth,
                                          duration,
                                        );

                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onTapDown: (details) => scrub(details.localPosition.dx),
                                      onHorizontalDragUpdate: (details) => scrub(details.localPosition.dx),
                                      child: Column(
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
                                    );
                                  },
                                ),

                                // Volume - Compact
                                StreamBuilder<double>(
                                  stream: widget.audioService.volumeStream,
                                  initialData: widget.audioService.volume,
                                  builder: (context, volumeSnapshot) {
                                    final double volume =
                                        volumeSnapshot.data ?? widget.audioService.volume;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.volume_mute, size: 20),
                                          Expanded(
                                            child: SliderTheme(
                                              data: SliderTheme.of(context).copyWith(
                                                activeTrackColor: theme.colorScheme.tertiary,
                                                inactiveTrackColor: theme.colorScheme.tertiary.withValues(alpha: 0.2),
                                                thumbColor: theme.colorScheme.tertiary,
                                                overlayColor: theme.colorScheme.tertiary.withValues(alpha: 0.1),
                                              ),
                                              child: Slider(
                                                value: volume,
                                                min: 0,
                                                max: 1,
                                                onChanged: (value) {
                                                  widget.audioService.setVolume(value);
                                                },
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${(volume * 100).round()}%',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                          const SizedBox(width: 8),
                                          const Icon(Icons.volume_up, size: 20),
                                        ],
                                      ),
                                    );
                                  },
                                ),

                                // Controls - Compact spacing
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        track.isFavorite ? Icons.favorite : Icons.favorite_border,
                                        size: isDesktop ? 32 : 26,
                                      ),
                                      onPressed: () async {
                                        try {
                                          final currentFavoriteStatus = track.isFavorite;
                                          final newFavoriteStatus = !currentFavoriteStatus;
                                          
                                          debugPrint('🎯 Favorite button clicked: current=$currentFavoriteStatus, new=$newFavoriteStatus');
                                          
                                          // Update Jellyfin server
                                          await widget.appState.jellyfinService.markFavorite(track.id, newFavoriteStatus);
                                          
                                          // Update track object with new favorite status
                                          final updatedTrack = track.copyWith(isFavorite: newFavoriteStatus);
                                          debugPrint('🔄 Updating track: old isFavorite=${track.isFavorite}, new isFavorite=${updatedTrack.isFavorite}');
                                          widget.audioService.updateCurrentTrack(updatedTrack);
                                          
                                          // Force UI rebuild
                                          if (mounted) setState(() {});
                                          
                                          // Refresh favorites list in app state
                                          await widget.appState.refreshFavorites();
                                          
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text(newFavoriteStatus ? 'Added to favorites' : 'Removed from favorites'),
                                                duration: const Duration(seconds: 2),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          debugPrint('❌ Error toggling favorite: $e');
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('Failed to update favorite: $e'),
                                                backgroundColor: theme.colorScheme.error,
                                              ),
                                            );
                                          }
                                        }
                                  },
                                  color: track.isFavorite ? Colors.red : null,
                                ),

                                    SizedBox(width: isDesktop ? 16 : 4),
                                    
                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_previous,
                                        size: isDesktop ? 48 : 40,
                                      ),
                                      onPressed: () => widget.audioService.previous(),
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 8),

                                    IconButton(
                                      icon: Icon(
                                        Icons.stop,
                                        size: isDesktop ? 40 : 32,
                                      ),
                                      onPressed: () => widget.audioService.stop(),
                                      color: theme.colorScheme.error,
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 8),

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
                                      ),
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 24 : 8),

                                    IconButton(
                                      icon: Icon(
                                        Icons.skip_next,
                                        size: isDesktop ? 48 : 40,
                                      ),
                                      onPressed: () => widget.audioService.next(),
                                    ),
                                    
                                    SizedBox(width: isDesktop ? 16 : 4),
                                    
                                    // Repeat button
                                    StreamBuilder<RepeatMode>(
                                      stream: widget.audioService.repeatModeStream,
                                      initialData: widget.audioService.repeatMode,
                                      builder: (context, snapshot) {
                                        final repeatMode = snapshot.data ?? RepeatMode.off;
                                        IconData icon;
                                        Color? color;
                                        
                                        switch (repeatMode) {
                                          case RepeatMode.off:
                                            icon = Icons.repeat;
                                            color = null;
                                            break;
                                          case RepeatMode.all:
                                            icon = Icons.repeat;
                                            color = theme.colorScheme.primary;
                                            break;
                                          case RepeatMode.one:
                                            icon = Icons.repeat_one;
                                            color = theme.colorScheme.primary;
                                            break;
                                        }
                                        
                                        return IconButton(
                                          icon: Icon(
                                            icon,
                                            size: isDesktop ? 32 : 26,
                                            color: color,
                                          ),
                                          onPressed: () => widget.audioService.toggleRepeatMode(),
                                        );
                                      },
                                    ),
                                  ],
                                ),
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
    },
  );
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
}
