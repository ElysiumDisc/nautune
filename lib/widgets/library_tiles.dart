import 'package:flutter/material.dart';

import '../theme/nautune_spacing.dart';
import '../theme/nautune_theme.dart';

/// Text roles and fixed extents shared by library rows and tiles, scaled
/// with the user's text size so fixed-extent lists never clip text.
class LibraryTileMetrics {
  LibraryTileMetrics.of(BuildContext context)
      : _scaler = MediaQuery.textScalerOf(context);

  final TextScaler _scaler;

  static const double artSize = 56;
  static const double _titleSize = 15;
  static const double _subtitleSize = 13;
  static const double _lineHeight = 1.25;

  double get _titleLine => _scaler.scale(_titleSize) * _lineHeight;
  double get _subtitleLine => _scaler.scale(_subtitleSize) * _lineHeight;

  /// Row height for [LibraryListRow].
  double get listRowExtent => (_titleLine + _subtitleLine + 2 * NautuneSpacing.sm + 4)
      .clamp(artSize + 2 * NautuneSpacing.sm, double.infinity);

  /// Grid cell height for an [ArtworkGridTile] of [tileWidth], with or
  /// without a subtitle line.
  double gridExtent(double tileWidth, {bool subtitle = true}) =>
      tileWidth + 6 + _titleLine + (subtitle ? _subtitleLine : 0) + 4;
}

/// A library list row: artwork, a title and an optional subtitle, with an
/// inset hairline separator like an iOS table.
class LibraryListRow extends StatelessWidget {
  const LibraryListRow({
    super.key,
    required this.artwork,
    required this.title,
    this.subtitle,
    this.circular = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.semanticLabel,
  });

  final Widget artwork;
  final String title;
  final String? subtitle;

  /// Round artwork (artists).
  final bool circular;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = NautuneStyle.of(context);
    return Semantics(
      button: onTap != null,
      label: semanticLabel ??
          (subtitle == null ? title : '$title, $subtitle'),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(left: NautuneSpacing.lg),
          child: Row(
            children: [
              SizedBox.square(
                dimension: LibraryTileMetrics.artSize,
                child: ClipPath(
                  clipper: ShapeBorderClipper(
                    shape: circular
                        ? const CircleBorder()
                        : style.shape(NautuneRadius.sm),
                  ),
                  child: artwork,
                ),
              ),
              const SizedBox(width: NautuneSpacing.md),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: style.separator, width: 0.5),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(right: NautuneSpacing.lg),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.subhead.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (subtitle != null && subtitle!.isNotEmpty)
                                Text(
                                  subtitle!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.footnote,
                                ),
                            ],
                          ),
                        ),
                        ?trailing,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A grid cell: square artwork (rounded, or circular for artists) with a
/// one-line title and optional subtitle underneath, as in Apple Music.
class ArtworkGridTile extends StatelessWidget {
  const ArtworkGridTile({
    super.key,
    required this.artwork,
    required this.title,
    this.subtitle,
    this.circular = false,
    this.onTap,
    this.onLongPress,
  });

  final Widget artwork;
  final String title;
  final String? subtitle;
  final bool circular;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = NautuneStyle.of(context);
    final align =
        circular ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = circular ? TextAlign.center : TextAlign.start;
    return Semantics(
      button: onTap != null,
      label: subtitle == null ? title : '$title, $subtitle',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: align,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: circular
                      ? const CircleBorder()
                      : style.shape(NautuneRadius.md),
                  color: theme.colorScheme.surfaceContainerHigh,
                ),
                child: ClipPath(
                  clipper: ShapeBorderClipper(
                    shape: circular
                        ? const CircleBorder()
                        : style.shape(NautuneRadius.md),
                  ),
                  child: SizedBox.expand(child: artwork),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
              style: theme.textTheme.subhead.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: theme.textTheme.footnote.copyWith(height: 1.25),
              ),
          ],
        ),
      ),
    );
  }
}
