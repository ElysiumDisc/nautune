import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/jellyfin/jellyfin_track.dart';
import 'package:nautune/services/audio_player_service.dart';
import 'package:nautune/widgets/position_data_builder.dart';

/// Hands out a fresh single-subscription stream per call, like
/// `Rx.combineLatest3` does, and counts listeners.
class _FakeAudioService implements AudioPlayerService {
  final controllers = <StreamController<PositionData>>[];

  @override
  Stream<PositionData> get positionDataStream {
    final controller = StreamController<PositionData>();
    controllers.add(controller);
    return controller.stream;
  }

  @override
  Duration get currentPosition => const Duration(seconds: 42);

  @override
  JellyfinTrack? get currentTrack => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('survives being unmounted and mounted again (tab switch)',
      (tester) async {
    final service = _FakeAudioService();
    final tabs = TabController(length: 2, vsync: const TestVSync());
    addTearDown(tabs.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TabBarView(
          controller: tabs,
          children: [
            PositionDataBuilder(
              audioService: service,
              builder: (context, data) =>
                  Text('at ${data.position.inSeconds}'),
            ),
            const Text('lyrics'),
          ],
        ),
      ),
    ));
    // Starts from the current position, not 0:00.
    expect(find.text('at 42'), findsOneWidget);

    tabs.animateTo(1);
    await tester.pumpAndSettle();
    tabs.animateTo(0);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(service.controllers.length, 2);
    service.controllers.last.add(const PositionData(
      Duration(seconds: 7),
      Duration.zero,
      Duration(minutes: 3),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('at 7'), findsOneWidget);
  });
}
