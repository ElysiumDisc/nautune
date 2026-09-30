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

  // Once open the route is opaque, so the page below isn't laid out, painted
  // or rasterized under the player; a drag still reveals it.
  testWidgets('the page below is offstage while open and shown while dragging',
      (tester) async {
    await openPlayer(tester);
    expect(find.text('open'), findsNothing);

    final gesture = await tester.startGesture(tester.getCenter(find.text('player')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(find.text('open'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(find.text('open'), findsNothing);
  });

  testWidgets('the artwork flies back to the opener\'s mini player on a drag',
      (tester) async {
    Widget art(Object tag) => Hero(
          tag: tag,
          transitionOnUserGestures: true,
          child: const SizedBox.square(dimension: 40, child: ColoredBox(color: Colors.red)),
        );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            art(nowPlayingArtworkHeroTag(ModalRoute.of(context))),
            TextButton(
              onPressed: () => NowPlayingRoute.show(
                context,
                (playerContext) {
                  final route = ModalRoute.of(playerContext)! as NowPlayingRoute;
                  return Scaffold(
                    body: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        art(route.artworkHeroTag),
                        const Text('player'),
                      ]),
                    ),
                  );
                },
              ),
              child: const Text('open'),
            ),
          ]),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(find.text('player')));
    await gesture.moveBy(const Offset(0, 20));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    // In flight: both heroes hold placeholders, and the artwork is drawn
    // once, in the navigator's overlay.
    final redBox = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == Colors.red);
    expect(find.byType(Hero), findsNWidgets(2));
    expect(find.descendant(of: find.byType(Hero), matching: redBox), findsNothing);
    expect(redBox, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('player'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  test('the artwork hero tag is scoped to the opening page', () {
    final a = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final b = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    expect(nowPlayingArtworkHeroTag(a), nowPlayingArtworkHeroTag(a));
    expect(nowPlayingArtworkHeroTag(a), isNot(nowPlayingArtworkHeroTag(b)));
    expect(
      NowPlayingRoute<void>(builder: (_) => const SizedBox(), opener: a).artworkHeroTag,
      nowPlayingArtworkHeroTag(a),
    );
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
