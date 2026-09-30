import 'package:flutter/widgets.dart';

import '../services/audio_player_service.dart';

/// Rebuilds [builder] on every playback position tick.
///
/// Each instance asks the service for its own [AudioPlayerService.positionDataStream]
/// when it mounts, so it is safe to unmount and remount (tab switches, the
/// mini player hiding while nothing plays) whether or not that stream is a
/// single-subscription one. The first frame starts from the service's
/// current position instead of 0:00.
class PositionDataBuilder extends StatefulWidget {
  const PositionDataBuilder({
    super.key,
    required this.audioService,
    required this.builder,
  });

  final AudioPlayerService audioService;
  final Widget Function(BuildContext context, PositionData data) builder;

  @override
  State<PositionDataBuilder> createState() => _PositionDataBuilderState();
}

class _PositionDataBuilderState extends State<PositionDataBuilder> {
  late Stream<PositionData> _stream;

  @override
  void initState() {
    super.initState();
    _stream = widget.audioService.positionDataStream;
  }

  @override
  void didUpdateWidget(covariant PositionDataBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _stream = widget.audioService.positionDataStream;
    }
  }

  PositionData _current() {
    final service = widget.audioService;
    return PositionData(
      service.currentPosition,
      Duration.zero,
      service.currentTrack?.duration ?? Duration.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PositionData>(
      stream: _stream,
      initialData: _current(),
      builder: (context, snapshot) =>
          widget.builder(context, snapshot.data ?? _current()),
    );
  }
}
