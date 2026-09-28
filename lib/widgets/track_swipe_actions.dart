import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../app_state.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/haptic_service.dart';

/// iOS-style swipe actions on a track row: swipe right to play it next,
/// swipe left to add it to the end of the queue. The row springs back.
class TrackSwipeActions extends StatelessWidget {
  const TrackSwipeActions({
    super.key,
    required this.track,
    required this.appState,
    required this.child,
    this.discriminator,
  });

  final JellyfinTrack track;
  final NautuneAppState appState;
  final Widget child;

  /// Makes the swipe key unique when a list shows a track more than once.
  final Object? discriminator;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget background(IconData icon, String label, Color color, Alignment align) =>
        Container(
          color: color,
          alignment: align,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 2),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
              ),
            ],
          ),
        );

    return Semantics(
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Play next'): () => _playNext(context),
        const CustomSemanticsAction(label: 'Add to queue'): () => _addToQueue(context),
      },
      child: Dismissible(
        key: ValueKey('swipe-${track.id}-${discriminator ?? ''}'),
        dismissThresholds: const {
          DismissDirection.startToEnd: 0.25,
          DismissDirection.endToStart: 0.25,
        },
        background: background(
          Icons.playlist_play_rounded,
          'Play Next',
          theme.colorScheme.primary,
          Alignment.centerLeft,
        ),
        secondaryBackground: background(
          Icons.playlist_add_rounded,
          'Add to Queue',
          Colors.orange.shade700,
          Alignment.centerRight,
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            _playNext(context);
          } else {
            _addToQueue(context);
          }
          return false; // actions, not deletions: spring back
        },
        child: child,
      ),
    );
  }

  void _playNext(BuildContext context) {
    HapticService.mediumTap();
    appState.audioPlayerService.playNext([track]);
    _toast(context, 'Playing next: ${track.name}');
  }

  void _addToQueue(BuildContext context) {
    HapticService.mediumTap();
    appState.audioPlayerService.addToQueue([track]);
    _toast(context, 'Added to queue: ${track.name}');
  }

  void _toast(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(milliseconds: 1500)),
    );
  }
}
