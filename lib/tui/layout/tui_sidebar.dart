import 'package:flutter/material.dart';

import '../tui_metrics.dart';
import '../tui_theme.dart';
import '../widgets/tui_box.dart';

/// Sidebar navigation items.
enum TuiSidebarItem {
  albums,
  artists,
  queue,
  search,
}

extension TuiSidebarItemExtension on TuiSidebarItem {
  String get label {
    switch (this) {
      case TuiSidebarItem.albums:
        return 'Albums';
      case TuiSidebarItem.artists:
        return 'Artists';
      case TuiSidebarItem.queue:
        return 'Queue';
      case TuiSidebarItem.search:
        return 'Search';
    }
  }

  String get icon {
    switch (this) {
      case TuiSidebarItem.albums:
        return '♫';
      case TuiSidebarItem.artists:
        return '♪';
      case TuiSidebarItem.queue:
        return '≡';
      case TuiSidebarItem.search:
        return '/';
    }
  }
}

/// The left navigation sidebar with section selection.
class TuiSidebar extends StatelessWidget {
  const TuiSidebar({
    super.key,
    required this.selectedItem,
    required this.onItemSelected,
    required this.focused,
  });

  final TuiSidebarItem selectedItem;
  final ValueChanged<TuiSidebarItem> onItemSelected;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: TuiMetrics.sidebarWidth,
      child: TuiBox(
        title: 'Nautune',
        focused: focused,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in TuiSidebarItem.values) _buildItem(item),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(TuiSidebarItem item) {
    final isSelected = item == selectedItem;
    final style = isSelected ? TuiTextStyles.selection : TuiTextStyles.normal;

    return GestureDetector(
      onTap: () => onItemSelected(item),
      child: Container(
        color: isSelected ? TuiColors.selection : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text(
              isSelected ? TuiChars.cursor : ' ',
              style: style,
            ),
            Text(' ${item.icon} ', style: style),
            Expanded(
              child: Text(
                item.label,
                style: style,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
