// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Placeholder smoke test', (tester) async {
    // Placeholder smoke test to ensure Flutter test harness works.
    await tester.pumpWidget(const Placeholder());
    expect(find.byType(Placeholder), findsOneWidget);
  });
}
