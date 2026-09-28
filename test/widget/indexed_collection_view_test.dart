import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nautune/theme/nautune_theme.dart';
import 'package:nautune/widgets/indexed_collection_view.dart';

List<String> _names(String letters, int perLetter) => [
      for (final l in letters.split(''))
        for (var i = 0; i < perLetter; i++) '$l item $i',
    ];

Widget _host(Widget child) => MaterialApp(
      theme: NautunePalettes.purpleOcean.buildTheme(),
      home: Scaffold(body: SizedBox(width: 400, height: 800, child: child)),
    );

/// Taps the index strip at [letter] (strip spans the view's right edge,
/// top 32 to bottom 16, one equal slot per letter).
Future<void> _tapLetter(WidgetTester tester, String letter) async {
  const letters = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final view = tester.getRect(find.byType(CustomScrollView));
  final top = view.top + 32;
  final height = view.height - 32 - 16;
  final slot = height / letters.length;
  final y = top + slot * (letters.indexOf(letter) + 0.5);
  await tester.tapAt(Offset(view.right - 10, y));
  await tester.pumpAndSettle();
}

/// The sticky header for [letter] sits at the top of the scroll view.
void _expectHeaderAtTop(WidgetTester tester, String letter) {
  final view = tester.getRect(find.byType(CustomScrollView));
  final header = find.text(letter).first;
  expect(tester.getTopLeft(header).dy - view.top, lessThan(32),
      reason: 'header $letter should be pinned at the top');
  // The first item of the section is right below it.
  expect(find.text('$letter item 0'), findsOneWidget);
}

void main() {
  for (final listMode in [false, true]) {
    testWidgets('index jumps exactly to a letter (${listMode ? 'list' : 'grid'})',
        (tester) async {
      final controller = ScrollController();
      await tester.pumpWidget(_host(IndexedCollectionView<String>(
        items: _names('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 7),
        nameOf: (s) => s,
        controller: controller,
        listMode: listMode,
        columns: 3,
        listItemBuilder: (c, s) => Text(s),
        gridItemBuilder: (c, s) => Text(s),
      )));
      for (final letter in ['M', 'C', 'T', 'A']) {
        await _tapLetter(tester, letter);
        _expectHeaderAtTop(tester, letter);
      }
    });
  }

  testWidgets('a letter past the loaded pages loads the rest first',
      (tester) async {
    final controller = ScrollController();
    var items = _names('ABC', 30);
    var hasMore = true;
    late StateSetter setOuter;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      setOuter = setState;
      return IndexedCollectionView<String>(
        items: items,
        nameOf: (s) => s,
        controller: controller,
        columns: 2,
        hasMore: hasMore,
        onLoadAll: () async {
          setOuter(() {
            items = [...items, ..._names('DEFGHIJKLMNOPQRSTUVWXYZ', 30)];
            hasMore = false;
          });
        },
        listItemBuilder: (c, s) => Text(s),
        gridItemBuilder: (c, s) => Text(s),
      );
    })));
    await _tapLetter(tester, 'P');
    expect(hasMore, isFalse);
    _expectHeaderAtTop(tester, 'P');
  });
}
