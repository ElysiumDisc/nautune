import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/widgets/ios/now_playing_route.dart';

void main() {
  Future<void> openPlayer(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(NowPlayingRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('player'))),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  }

  testWidgets('dragging the player down far enough closes it', (tester) async {
    await openPlayer(tester);
    await tester.drag(find.text('player'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsNothing);
  });

  testWidgets('a short drag springs back open', (tester) async {
    await openPlayer(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('player')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });

  // The sheet must continue from where the finger let go: switching from the
  // linear drag mapping to the eased one on release made it jump.
  Future<double> playerTop(WidgetTester tester) async =>
      tester.getTopLeft(find.byKey(const ValueKey('player-page'))).dy;

  Future<void> openKeyedPlayer(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(NowPlayingRoute<void>(
              builder: (_) => const Scaffold(
                key: ValueKey('player-page'),
                body: Center(child: Text('player')),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('releasing to close does not jump', (tester) async {
    await openKeyedPlayer(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('player')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump(const Duration(milliseconds: 500));
    final before = await playerTop(tester);
    await gesture.up();
    await tester.pump();
    final after = await playerTop(tester);
    expect((after - before).abs(), lessThan(10));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsNothing);
  });

  testWidgets('releasing to spring back does not jump', (tester) async {
    await openKeyedPlayer(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('player')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 500));
    final before = await playerTop(tester);
    await gesture.up();
    await tester.pump();
    final after = await playerTop(tester);
    expect((after - before).abs(), lessThan(10));
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('show returns to an open player instead of stacking one',
      (tester) async {
    late BuildContext pageContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => NowPlayingRoute.show(
              context,
              (playerContext) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(playerContext).push(
                    MaterialPageRoute<void>(
                      builder: (context) {
                        pageContext = context;
                        return const Scaffold(body: Text('album'));
                      },
                    ),
                  ),
                  child: const Text('player'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('player'));
    await tester.pumpAndSettle();
    expect(find.text('album'), findsOneWidget);

    NowPlayingRoute.show(pageContext, (_) => const Text('second player'));
    await tester.pumpAndSettle();
    expect(find.text('album'), findsNothing);
    expect(find.text('second player'), findsNothing);
    expect(find.text('player'), findsOneWidget);
  });
}
