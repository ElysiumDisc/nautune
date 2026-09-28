import 'package:flutter/material.dart';

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/haptic_service.dart';
import 'add_to_playlist_dialog.dart';
import '../theme/nautune_theme.dart';
import 'ios/frosted_bar.dart';

/// Which tracks of a list are selected (multi-select mode).
class TrackSelection extends ChangeNotifier {
  bool _active = false;
  final Set<String> _ids = {};

  bool get active => _active;
  int get count => _ids.length;
  bool isSelected(JellyfinTrack track) => _ids.contains(track.id);

  void start() {
    if (_active) return;
    HapticService.mediumTap();
    _active = true;
    notifyListeners();
  }

  void end() {
    if (!_active) return;
    _active = false;
    _ids.clear();
    notifyListeners();
  }

  void toggle(JellyfinTrack track) {
    HapticService.selectionClick();
    if (!_ids.remove(track.id)) _ids.add(track.id);
    notifyListeners();
  }

  void selectAll(Iterable<JellyfinTrack> tracks) {
    _ids.addAll(tracks.map((t) => t.id));
    notifyListeners();
  }

  /// Selected tracks, in [ordered]'s order.
  List<JellyfinTrack> selectedIn(List<JellyfinTrack> ordered) =>
      [for (final t in ordered) if (_ids.contains(t.id)) t];
}

/// Leading check mark for a row in selection mode.
class SelectionCheck extends StatelessWidget {
  const SelectionCheck({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
        key: ValueKey(selected),
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
        semanticLabel: selected ? 'Selected' : 'Not selected',
      ),
    );
  }
}

/// Bottom action bar while tracks are selected: play, play next, queue,
/// add to playlist and download the selection.
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    super.key,
    required this.selection,
    required this.tracks,
    required this.appState,
  });

  final TrackSelection selection;

  /// All tracks of the list, in display order.
  final List<JellyfinTrack> tracks;
  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        final selected = selection.selectedIn(tracks);
        final enabled = selected.isNotEmpty;
        final player = appState.audioPlayerService;
        void done(String message) {
          selection.end();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
          );
        }

        Widget action(IconData icon, String label, VoidCallback onPressed) =>
            Expanded(
              child: TextButton(
                onPressed: enabled ? onPressed : null,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 6)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon),
                    const SizedBox(height: 2),
                    Text(label, style: theme.textTheme.labelSmall, maxLines: 1),
                  ],
                ),
              ),
            );

        return FrostedBar(
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          enabled ? '${selected.length} selected' : 'Select tracks',
                          style: theme.textTheme.headline,
                        ),
                      ),
                      TextButton(
                        onPressed: () => selection.selectAll(tracks),
                        child: const Text('Select All'),
                      ),
                      TextButton(
                        onPressed: selection.end,
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    action(Icons.play_arrow_rounded, 'Play', () {
                      player.playTrack(selected.first, queueContext: selected);
                      selection.end();
                    }),
                    action(Icons.playlist_play_rounded, 'Play Next', () {
                      player.playNext(selected);
                      done('${selected.length} tracks play next');
                    }),
                    action(Icons.queue_music_rounded, 'Queue', () {
                      player.addToQueue(selected);
                      done('${selected.length} tracks added to queue');
                    }),
                    action(Icons.playlist_add_rounded, 'Playlist', () async {
                      await showAddToPlaylistDialog(
                        context: context,
                        appState: appState,
                        tracks: selected,
                      );
                      selection.end();
                    }),
                    if (!appState.isOfflineMode)
                      action(Icons.download_rounded, 'Download', () {
                        appState.downloadService.downloadTracks(selected);
                        done('Downloading ${selected.length} tracks');
                      }),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
