import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/widgets/skeleton_loader.dart';

void main() {
  Widget host({bool tickers = true, bool reduceMotion = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: TickerMode(
            enabled: tickers,
            child: const Row(children: [
              SkeletonLoader(width: 40, height: 40),
              SkeletonLoader(width: 40, height: 40),
            ]),
          ),
        ),
      );

  testWidgets('loaders on screen animate', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);
    // Removing them stops the shared clock.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('offstage loaders do not tick', (tester) async {
    await tester.pumpWidget(host(tickers: false));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('Reduce Motion stops the shimmer', (tester) async {
    await tester.pumpWidget(host(reduceMotion: true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
