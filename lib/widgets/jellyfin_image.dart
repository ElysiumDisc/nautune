import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

class JellyfinImage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (imageTag == null || imageTag!.isEmpty) {
      return _buildError(context, 'No image tag provided');
    }

    final appState = Provider.of<NautuneAppState>(context, listen: false);

    // If artistId is provided, try to load downloaded artist image first
    if (artistId != null) {
      final isOfflineMarker = imageTag == 'offline';
      return FutureBuilder<File?>(
        future: appState.downloadService.getArtistImageFile(artistId!),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Offline artist image found - use it!
            return Image.file(
              snapshot.data!,
              width: width,
              height: height,
              fit: boxFit,
              errorBuilder: (context, error, stackTrace) {
                if (isOfflineMarker) {
                  if (errorBuilder != null) {
                    return errorBuilder!(context, '', error);
                  }
                  return _buildError(context, error);
                }
                return _buildNetworkImage(context, appState);
              },
            );
          }
          // No offline artist image - fall back to network image (unless offline marker)
          if (isOfflineMarker) {
            if (errorBuilder != null) {
              return errorBuilder!(context, '', 'No offline image available');
            }
            return _buildError(context, 'No offline image available');
          }
          return _buildNetworkImage(context, appState);
        },
      );
    }

    // If trackId is provided, try to load downloaded album artwork first
    if (trackId != null) {
      return FutureBuilder<File?>(
        future: appState.downloadService.getArtworkFile(trackId!),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            // Offline artwork found - use it!
            return Image.file(
              snapshot.data!,
              width: width,
              height: height,
              fit: boxFit,
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
    // Determine optimal dimensions for request
    final requestWidth = maxWidth ?? (width != null ? (width! * 2).toInt() : 400);
    final requestHeight = maxHeight ?? (height != null ? (height! * 2).toInt() : null);

    final imageUrl = appState.jellyfinService.buildImageUrl(
      itemId: itemId,
      tag: imageTag!,
      maxWidth: requestWidth,
      maxHeight: requestHeight,
    );

    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: appState.jellyfinService.imageHeaders(),
      width: width,
      height: height,
      fit: boxFit,
      placeholder: placeholderBuilder != null
          ? (context, url) => placeholderBuilder!(context, url)
          : (context, url) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                width: width,
                height: height,
              ),
      errorWidget: errorBuilder != null
          ? (context, url, error) => errorBuilder!(context, url, error)
          : (context, url, error) => _buildError(context, error),
      memCacheWidth: requestWidth,
      memCacheHeight: requestHeight,
      // Disk cache is handled automatically by cached_network_image
    );
  }

  Widget _buildError(BuildContext context, dynamic error) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      width: width,
      height: height,
      child: Center(
        child: Icon(
          Icons.image_not_supported,
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
