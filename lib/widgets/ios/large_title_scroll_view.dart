import 'package:flutter/cupertino.dart';

import '../../theme/nautune_theme.dart';

/// A scroll view with an iOS collapsing large title: the title sits large
/// above the content and shrinks into a frosted navigation bar as you
/// scroll. Supports iOS-style pull-to-refresh.
///
/// Several of these can live under one route (library tabs), so the nav
/// bar's between-route hero transition is off.
class LargeTitleScrollView extends StatelessWidget {
  const LargeTitleScrollView({
    super.key,
    required this.title,
    required this.slivers,
    this.leading,
    this.trailing,
    this.onRefresh,
    this.controller,
    this.showBackButton = true,
  });

  final String title;
  final List<Widget> slivers;
  final Widget? leading;
  final Widget? trailing;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;

  /// Show the automatic back button when the route can pop.
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final style = NautuneStyle.of(context);
    final blur = style.frostedBlur && !MediaQuery.highContrastOf(context);
    return CustomScrollView(
      controller: controller,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        CupertinoSliverNavigationBar(
          largeTitle: Text(title),
          leading: leading,
          trailing: trailing,
          automaticallyImplyLeading: showBackButton,
          transitionBetweenRoutes: false,
          backgroundColor: blur
              ? style.barColor
              : Color.alphaBlend(style.barColor, style.groupedBackground)
                  .withValues(alpha: 1),
          enableBackgroundFilterBlur: blur,
          border: Border(
            bottom: BorderSide(color: style.separator, width: 0.5),
          ),
        ),
        if (onRefresh != null) CupertinoSliverRefreshControl(onRefresh: onRefresh),
        ...slivers,
      ],
    );
  }
}
