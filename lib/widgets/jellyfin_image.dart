import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Artwork from Jellyfin (or its downloaded copy), decoded at the size it's
/// shown at.
///
/// [maxWidth] / [maxHeight] are in logical points: the size the image is
/// drawn at. They're multiplied by the device pixel ratio and rounded up to a
/// few fixed pixel buckets ([pixelSizeFor]), so the same artwork shown at
/// similar sizes shares one server URL, disk-cache entry and decoded image.
class JellyfinImage extends StatefulWidget {
  const JellyfinImage({
    super.key,
    required this.itemId,
    required this.imageTag,
    this.width,
    this.height,
    this.maxWidth,
    this.maxHeight,
    this.boxFit = BoxFit.cover,
    this.errorBuilder,
    this.placeholderBuilder,
    this.trackId, // Optional: for offline album artwork lookup via track
    this.artistId, // Optional: for offline artist image lookup
    this.albumId, // Optional: for offline album artwork lookup by album ID
  });

  final String itemId;
  final String? imageTag;
  final double? width;
  final double? height;
  final int? maxWidth;
  final int? maxHeight;
  final BoxFit boxFit;
  final Widget Function(BuildContext context, String url, dynamic error)? errorBuilder;
  final Widget Function(BuildContext context, String url)? placeholderBuilder;
  final String? trackId; // If provided, will check for downloaded album artwork first
  final String? artistId; // If provided, will check for downloaded artist image first
  final String? albumId; // If provided, will check for downloaded album artwork by album ID

  /// Logical size of a list-row thumbnail.
  static const int listArtwork = 56;

  /// Logical size of a typical library grid cell (two columns on a phone).
  /// The image prewarmer requests this size so grid artwork hits its cache.
  static const int gridArtwork = 180;

  /// Size used when neither [maxWidth] nor [width] is given.
  static const int _defaultArtwork = 200;

  /// Decoded / requested pixel sizes. Coarse on purpose: nearby sizes share
  /// one cache entry.
  static const List<int> _pixelBuckets = [
    128, 256, 384, 512, 640, 768, 1024, 1280, 1600, 2048,
  ];

  /// Pixel size to request and decode for [logical] points at [dpr].
  static int pixelSizeFor(num logical, double dpr) {
    final wanted = (logical * dpr).ceil();
    for (final bucket in _pixelBuckets) {
      if (wanted <= bucket) return bucket;
    }
    return _pixelBuckets.last;
  }

  @override
  State<JellyfinImage> createState() => _JellyfinImageState();
}

class _JellyfinImageState extends State<JellyfinImage> {
  Future<File?>? _artistImageFuture;
  Future<File?>? _albumArtworkFuture;
  Future<File?>? _artworkFuture;

  @override
  void initState() {
    super.initState();
    _initFutures();
  }

  @override
  void didUpdateWidget(JellyfinImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only recreate futures if the relevant IDs change
    if (oldWidget.itemId != widget.itemId ||
        oldWidget.imageTag != widget.imageTag ||
        oldWidget.artistId != widget.artistId ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.trackId != widget.trackId) {
      _initFutures();
    }
  }

  void _initFutures() {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    if (widget.artistId != null) {
      _artistImageFuture = appState.downloadService.getArtistImageFile(widget.artistId!);
    }
    if (widget.albumId != null) {
      _albumArtworkFuture = appState.downloadService.getArtworkFileByAlbumId(widget.albumId!);
    }
    if (widget.trackId != null) {
      _artworkFuture = appState.downloadService.getArtworkFile(widget.trackId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageTag == null || widget.imageTag!.isEmpty) {
      return _buildError(context, 'No image tag provided');
    }

    final appState = Provider.of<NautuneAppState>(context, listen: false);

    // If artistId is provided, try to load downloaded artist image first
    if (widget.artistId != null) {
      final isOfflineMarker = widget.imageTag == 'offline';
      return FutureBuilder<File?>(
        future: _artistImageFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Offline artist image found - use it!
            return _buildFileImage(
              context,
              snapshot.data!,
              (context, error, stackTrace) {
                if (isOfflineMarker) {
                  if (widget.errorBuilder != null) {
                    return widget.errorBuilder!(context, '', error);
                  }
                  return _buildError(context, error);
                }
                return _buildNetworkImage(context, appState);
              },
            );
          }
          // No offline artist image - fall back to network image (unless offline marker)
          if (isOfflineMarker) {
            if (widget.errorBuilder != null) {
              return widget.errorBuilder!(context, '', 'No offline image available');
            }
            return _buildError(context, 'No offline image available');
          }
          return _buildNetworkImage(context, appState);
        },
      );
    }

    // If albumId is provided, try to load downloaded album artwork by album ID
    if (widget.albumId != null) {
      return FutureBuilder<File?>(
        future: _albumArtworkFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return _buildFileImage(
              context,
              snapshot.data!,
              (context, error, stackTrace) =>
                  _buildNetworkImage(context, appState),
            );
          }
          // No offline album artwork - fall back to network image
          return _buildNetworkImage(context, appState);
        },
      );
    }

    // If trackId is provided, try to load downloaded album artwork first
    if (widget.trackId != null) {
      return FutureBuilder<File?>(
        future: _artworkFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Offline artwork found - use it!
            return _buildFileImage(
              context,
              snapshot.data!,
              (context, error, stackTrace) =>
                  _buildNetworkImage(context, appState),
            );
          }
          // No offline artwork - fall back to network image
          return _buildNetworkImage(context, appState);
        },
      );
    }

    // No trackId or artistId provided - use network image directly
    return _buildNetworkImage(context, appState);
  }

  /// Pixel size to request/decode: width always, height only when a caller
  /// asks for one (the server keeps the aspect ratio, and the URL then
  /// matches the prewarm/cache entries).
  (int, int?) _requestSize(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logicalWidth =
        widget.maxWidth ?? widget.width ?? JellyfinImage._defaultArtwork;
    final width = JellyfinImage.pixelSizeFor(logicalWidth, dpr);
    final height = widget.maxHeight != null
        ? JellyfinImage.pixelSizeFor(widget.maxHeight!, dpr)
        : null;
    return (width, height);
  }

  /// Downloaded artwork, decoded at the display size (not the file's).
  Widget _buildFileImage(
    BuildContext context,
    File file,
    ImageErrorWidgetBuilder errorBuilder,
  ) {
    final (cacheWidth, _) = _requestSize(context);
    return Image.file(
      file,
      width: widget.width,
      height: widget.height,
      fit: widget.boxFit,
      cacheWidth: cacheWidth,
      errorBuilder: errorBuilder,
    );
  }

  Widget _buildNetworkImage(BuildContext context, NautuneAppState appState) {
    // CachedNetworkImage serves from disk cache first (no network needed).
    // Only uncached images will attempt a network request, which fails
    // gracefully via errorWidget when offline.

    final (requestWidth, requestHeight) = _requestSize(context);

    final imageUrl = appState.jellyfinService.buildImageUrl(
      itemId: widget.itemId,
      tag: widget.imageTag!,
      maxWidth: requestWidth,
      maxHeight: requestHeight,
    );

    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: appState.jellyfinService.imageHeaders(),
      width: widget.width,
      height: widget.height,
      fit: widget.boxFit,
      placeholder: widget.placeholderBuilder != null
          ? (context, url) => widget.placeholderBuilder!(context, url)
          : (context, url) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                width: widget.width,
                height: widget.height,
              ),
      errorWidget: widget.errorBuilder != null
          ? (context, url, error) => widget.errorBuilder!(context, url, error)
          : (context, url, error) => _buildError(context, error),
      memCacheWidth: requestWidth,
      memCacheHeight: requestHeight,
      // Disk cache is handled automatically by cached_network_image
    );
  }

  Widget _buildError(BuildContext context, dynamic error) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      width: widget.width,
      height: widget.height,
      child: Center(
        child: Icon(
          Icons.image_not_supported,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
