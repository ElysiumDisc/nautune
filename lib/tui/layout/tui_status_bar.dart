import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../jellyfin/jellyfin_track.dart';
import '../../models/loop_state.dart';
import '../../services/audio_player_service.dart';
import '../tui_theme.dart';
import '../widgets/tui_braille_visualizer.dart';
import '../widgets/tui_progress_bar.dart';
import '../widgets/tui_spectrum_visualizer.dart';

/// The bottom status bar showing now playing info and controls hint.
class TuiStatusBar extends StatelessWidget {
  const TuiStatusBar({super.key, this.showVisualizer = true});

  final bool showVisualizer;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<NautuneAppState>();
    final audioService = appState.audioPlayerService;

    return ListenableBuilder(
      listenable: TuiThemeManager.instance,
      builder: (context, _) {
        return Container(
          color: TuiColors.background,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Divider
              Text(
                TuiChars.horizontal * 200,
                style: TuiTextStyles.normal.copyWith(color: TuiColors.border),
                overflow: TextOverflow.clip,
                maxLines: 1,
              ),
              // Spectrum visualizer (between divider and now playing). The
              // active rendering style is picked from TuiThemeManager so
              // cycling styles at runtime rebuilds the right widget without
              // needing to touch shell state.
              if (showVisualizer) ...[
                const SizedBox(height: 2),
                switch (TuiThemeManager.instance.visualizerStyle) {
                  TuiVisualizerStyle.brailleSpectro => TuiBrailleVisualizer(
                      audioService: audioService,
                      width: 80,
                      height: 2,
                    ),
                  TuiVisualizerStyle.blocks => TuiSpectrumVisualizer(
                      audioService: audioService,
                      barCount: 32,
                      height: 2,
                    ),
                },
                const SizedBox(height: 2),
              ] else
                const SizedBox(height: 4),
              // Now playing row
              _NowPlayingRow(audioService: audioService),
              const SizedBox(height: 4),
              // Controls hint
              const _ControlsHint(),
            ],
          ),
        );
      },
    );
  }
}

class _NowPlayingRow extends StatelessWidget {
  const _NowPlayingRow({required this.audioService});

  final AudioPlayerService audioService;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<JellyfinTrack?>(
      stream: audioService.currentTrackStream,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data;

        if (track == null) {
          return Text(
            '${TuiChars.paused} No track playing',
            style: TuiTextStyles.dim,
          );
        }

        return StreamBuilder<bool>(
          stream: audioService.playingStream,
          builder: (context, playingSnapshot) {
            final isPlaying = playingSnapshot.data ?? false;

            return StreamBuilder<Duration>(
              stream: audioService.positionStream,
              builder: (context, posSnapshot) {
                final position = posSnapshot.data ?? Duration.zero;

                return StreamBuilder<Duration?>(
                  stream: audioService.durationStream,
                  builder: (context, durSnapshot) {
                    final duration = durSnapshot.data ?? track.duration ?? Duration.zero;

                    return StreamBuilder<LoopState>(
                      stream: audioService.loopStateStream,
                      builder: (context, loopSnapshot) {
                        final loopState = loopSnapshot.data;

                        return LayoutBuilder(
                          builder: (context, constraints) {
                            // Hide progress/volume on very narrow windows
                            final showExtras = constraints.maxWidth > 400;
                            return Row(
                              children: [
                                // Status icon
                                Text(
                                  '${isPlaying ? TuiChars.playing : TuiChars.paused} ',
                                  style: isPlaying ? TuiTextStyles.playing : TuiTextStyles.dim,
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        track.name,
                                        style: TuiTextStyles.normal,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                      Text(
                                        track.displayArtist,
                                        style: TuiTextStyles.dim,
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ],
                                  ),
                                ),
                                if (showExtras) ...[
                                  const SizedBox(width: 16),
                                  // Progress bar with loop state
                                  TuiProgressBar(
                                    position: position,
                                    duration: duration,
                                    width: 25,
                                    loopState: loopState,
                                  ),
                                  const SizedBox(width: 16),
                                  // Volume
                                  StreamBuilder<double>(
                                    stream: audioService.volumeStream,
                                    builder: (context, volSnapshot) {
                                      final volume = volSnapshot.data ?? 1.0;
                                      return TuiVolumeBar(volume: volume, width: 8);
                                    },
                                  ),
                                ],
                              ],
                            );
                          },
                        );
                      },
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
}

class _ControlsHint extends StatelessWidget {
  const _ControlsHint();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _hint('j/k', 'up/down'),
          const SizedBox(width: 12),
          _hint('h/l', 'back/enter'),
          const SizedBox(width: 12),
          _hint('Enter', 'play'),
          const SizedBox(width: 12),
          _hint('Space', 'pause'),
          const SizedBox(width: 12),
          _hint('n/p', 'next/prev'),
          const SizedBox(width: 12),
          _hint('+/-', 'vol'),
          const SizedBox(width: 12),
          _hint('v', 'viz'),
          const SizedBox(width: 12),
          _hint('V', 'style'),
          const SizedBox(width: 12),
          _hint('F', 'fullscreen'),
          const SizedBox(width: 12),
          _hint('Ctrl+K', 'commands'),
          const SizedBox(width: 12),
          _hint('?', 'help'),
          const SizedBox(width: 12),
          _hint('q', 'quit'),
        ],
      ),
    );
  }

  Widget _hint(String key, String action) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(key, style: TuiTextStyles.accent),
        Text(':$action', style: TuiTextStyles.dim),
      ],
    );
  }
}
