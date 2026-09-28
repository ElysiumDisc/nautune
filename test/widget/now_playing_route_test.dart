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
}
