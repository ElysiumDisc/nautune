import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

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
    this.trackId, // Optional: for offline album artwork lookup
    this.artistId, // Optional: for offline artist image lookup
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

  @override
  State<JellyfinImage> createState() => _JellyfinImageState();
}

class _JellyfinImageState extends State<JellyfinImage> {
  Future<File?>? _artistImageFuture;
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
    if (oldWidget.artistId != widget.artistId ||
        oldWidget.trackId != widget.trackId) {
      _initFutures();
    }
  }

  void _initFutures() {
    final appState = Provider.of<NautuneAppState>(context, listen: false);
    if (widget.artistId != null) {
      _artistImageFuture = appState.downloadService.getArtistImageFile(widget.artistId!);
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
            return Image.file(
              snapshot.data!,
              width: widget.width,
              height: widget.height,
              fit: widget.boxFit,
              errorBuilder: (context, error, stackTrace) {
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

    // If trackId is provided, try to load downloaded album artwork first
    if (widget.trackId != null) {
      return FutureBuilder<File?>(
        future: _artworkFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Offline artwork found - use it!
            return Image.file(
              snapshot.data!,
              width: widget.width,
              height: widget.height,
              fit: widget.boxFit,
              errorBuilder: (context, error, stackTrace) => _buildNetworkImage(context, appState),
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

  Widget _buildNetworkImage(BuildContext context, NautuneAppState appState) {
    // CachedNetworkImage serves from disk cache first (no network needed).
    // Only uncached images will attempt a network request, which fails
    // gracefully via errorWidget when offline.

    // Determine optimal dimensions for request, accounting for device pixel ratio
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final requestWidth = widget.maxWidth != null
        ? (widget.maxWidth! * dpr).toInt()
        : (widget.width != null ? (widget.width! * 2).toInt() : 400);
    final requestHeight = widget.maxHeight != null
        ? (widget.maxHeight! * dpr).toInt()
        : (widget.height != null ? (widget.height! * 2).toInt() : null);

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
