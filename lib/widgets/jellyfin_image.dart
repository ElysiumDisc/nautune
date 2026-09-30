import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// Disk cache for server artwork. The default cache of
/// `cached_network_image` keeps only 200 files; with a few pixel sizes per
/// album that is under 100 albums, so a larger library kept evicting and
/// re-downloading its artwork (and lost it offline). Pass it as
/// `cacheManager:` to any `CachedNetworkImage` / `CachedNetworkImageProvider`
/// that shows Jellyfin artwork.
class NautuneArtworkCacheManager extends CacheManager with ImageCacheManager {
  factory NautuneArtworkCacheManager() => _instance;

  NautuneArtworkCacheManager._()
      : super(Config(
          key,
          stalePeriod: const Duration(days: 60),
          maxNrOfCacheObjects: 4000,
        ));

  static const key = 'nautune_artwork';
  static final NautuneArtworkCacheManager _instance =
      NautuneArtworkCacheManager._();
}

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
  // Async lookups, used only while the download service's image index is
  // still being built (early startup); afterwards lookups are synchronous.
  Future<File?>? _localFuture;

  @override
  void initState() {
    super.initState();
    _initFuture();
  }

  @override
  void didUpdateWidget(JellyfinImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId ||
        oldWidget.imageTag != widget.imageTag ||
        oldWidget.artistId != widget.artistId ||
        oldWidget.albumId != widget.albumId ||
        oldWidget.trackId != widget.trackId) {
      _initFuture();
    }
  }

  bool get _hasLocalCandidate =>
      widget.artistId != null || widget.albumId != null || widget.trackId != null;

  void _initFuture() {
    _localFuture = null;
    if (!_hasLocalCandidate) return;
    final downloads =
        Provider.of<NautuneAppState>(context, listen: false).downloadService;
    if (downloads.imageIndexReady) return;
    if (widget.artistId != null) {
      _localFuture = downloads.getArtistImageFile(widget.artistId!);
    } else if (widget.albumId != null) {
      _localFuture = downloads.getArtworkFileByAlbumId(widget.albumId!);
    } else {
      _localFuture = downloads.getArtworkFile(widget.trackId!);
    }
  }

  /// Downloaded image for this widget, looked up synchronously in the
  /// download service's index (no file-system calls per widget). Evaluated
  /// on every build, so artwork downloaded meanwhile shows up on the next
  /// rebuild.
  File? _localFileSync(NautuneAppState appState) {
    final downloads = appState.downloadService;
    final String? path;
    if (widget.artistId != null) {
      path = downloads.localArtistImagePath(widget.artistId!);
    } else if (widget.albumId != null) {
      path = downloads.localArtworkPathForAlbum(widget.albumId!);
    } else if (widget.trackId != null) {
      path = downloads.localArtworkPathForTrack(widget.trackId!);
    } else {
      path = null;
    }
    return path == null ? null : File(path);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageTag == null || widget.imageTag!.isEmpty) {
      return _buildError(context, 'No image tag provided');
    }

    final appState = Provider.of<NautuneAppState>(context, listen: false);
    if (!_hasLocalCandidate) return _buildNetworkImage(context, appState);

    final pending = _localFuture;
    if (pending == null || appState.downloadService.imageIndexReady) {
      return _buildLocalOrNetwork(context, appState, _localFileSync(appState));
    }
    // Early startup (image index not built yet): wait for the lookup with a
    // placeholder instead of starting a network request that a downloaded
    // file would replace a moment later.
    return FutureBuilder<File?>(
      future: pending,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context);
        }
        return _buildLocalOrNetwork(context, appState, snapshot.data);
      },
    );
  }

  Widget _buildLocalOrNetwork(
    BuildContext context,
    NautuneAppState appState,
    File? local,
  ) {
    // An artist marked 'offline' has no server image to fall back to.
    final offlineOnly = widget.artistId != null && widget.imageTag == 'offline';
    Widget fallback(BuildContext context, Object? error) {
      if (!offlineOnly) return _buildNetworkImage(context, appState);
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, '', error ?? 'No offline image available');
      }
      return _buildError(context, error ?? 'No offline image available');
    }

    if (local == null) return fallback(context, null);
    return _buildFileImage(
      context,
      local,
      (context, error, stackTrace) => fallback(context, error),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    if (widget.placeholderBuilder != null) {
      return widget.placeholderBuilder!(context, '');
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      width: widget.width,
      height: widget.height,
    );
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
      cacheManager: NautuneArtworkCacheManager(),
      httpHeaders: appState.jellyfinService.imageHeaders(),
      width: widget.width,
      height: widget.height,
      fit: widget.boxFit,
      placeholder: (context, url) => _buildPlaceholder(context),
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
