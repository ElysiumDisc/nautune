import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/nautune_spacing.dart';
import '../../theme/nautune_theme.dart';

/// iOS inset-grouped list section: an optional small header, rows on a
/// rounded cell background separated by hairlines, and an optional footer.
class GroupedSection extends StatelessWidget {
  const GroupedSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
    this.margin = const EdgeInsets.fromLTRB(
      NautuneSpacing.lg,
      NautuneSpacing.sm,
      NautuneSpacing.lg,
      NautuneSpacing.xl,
    ),
    this.dividerIndent = 60,
  });

  final String? header;
  final String? footer;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  /// Separator inset from the leading edge (past the row icon, as on iOS).
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = NautuneStyle.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Divider(indent: dividerIndent, height: 0.5, thickness: 0.5));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NautuneSpacing.lg, 0, NautuneSpacing.lg, 6),
              child: Semantics(
                header: true,
                child: Text(
                  header!.toUpperCase(),
                  style: theme.textTheme.footnote,
                ),
              ),
            ),
          Material(
            color: style.groupedCell,
            shape: style.shape(NautuneRadius.md),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NautuneSpacing.lg, 6, NautuneSpacing.lg, 0),
              child: Text(footer!, style: theme.textTheme.footnote),
            ),
        ],
      ),
    );
  }
}

/// A row in a [GroupedSection]: iOS Settings-style tinted icon tile, title,
/// optional subtitle and trailing widget, and a chevron when it navigates.
class GroupedTile extends StatelessWidget {
  const GroupedTile({
    super.key,
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.destructive = false,
  });

  final IconData? icon;

  /// Icon tile colour; defaults to the theme's primary.
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Defaults to true when [onTap] is set and there is no [trailing].
  final bool? showChevron;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tile = iconColor ?? scheme.primary;
    final chevron = showChevron ?? (onTap != null && trailing == null);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NautuneSpacing.lg,
            vertical: NautuneSpacing.sm,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 29,
                  height: 29,
                  decoration: ShapeDecoration(
                    color: tile,
                    shape: NautuneStyle.of(context).shape(7),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: ThemeData.estimateBrightnessForColor(tile) ==
                            Brightness.dark
                        ? Colors.white
                        : Colors.black,
                  ),
                ),
                const SizedBox(width: 15),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.body.copyWith(
                        color: destructive ? scheme.error : null,
                      ),
                    ),
                    if (subtitle != null)
                      Text(subtitle!, style: theme.textTheme.footnote),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: NautuneSpacing.sm),
                trailing!,
              ],
              if (chevron)
                Padding(
                  padding: const EdgeInsets.only(left: NautuneSpacing.sm),
                  child: Icon(
                    CupertinoIcons.chevron_forward,
                    size: 16,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
