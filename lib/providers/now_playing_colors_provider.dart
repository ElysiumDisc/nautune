import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui show Image;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_track.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/palette_cache_service.dart';

/// Top-level function for compute() - extracts vibrant colors from image
/// pixels in an isolate. Returns up to 4 distinct, saturated colours, most
/// vibrant first.
Future<List<int>> extractArtworkColorsInIsolate(Uint32List pixels) async {
  // Run the quantization to find the dominant color clusters
  final result = await QuantizerCelebi().quantize(pixels, 128);
  final colorToCount = result.colorToCount;

  // RAW VIBRANCY SCORING
  // Score = Population * (Chroma^2)
  final sortedEntries = colorToCount.entries.toList()
    ..sort((a, b) {
      final hctA = Hct.fromInt(a.key);
      final hctB = Hct.fromInt(b.key);
      final scoreA = a.value * (hctA.chroma * hctA.chroma);
      final scoreB = b.value * (hctB.chroma * hctB.chroma);
      return scoreB.compareTo(scoreA);
    });

  final selectedColors = <int>[];

  for (final entry in sortedEntries) {
    if (selectedColors.length >= 4) break;

    final colorInt = entry.key;
    final hct = Hct.fromInt(colorInt);

    // Skip absolute greys
    if (hct.chroma < 5) continue;

    // Distinctness check
    bool isDistinct = true;
    for (final existing in selectedColors) {
      final existingHct = Hct.fromInt(existing);
      final hueDiff = (hct.hue - existingHct.hue).abs();
      final normalizedHueDiff = hueDiff > 180 ? 360 - hueDiff : hueDiff;
      if (normalizedHueDiff < 15) {
        isDistinct = false;
        break;
      }
    }

    if (isDistinct) {
      // Add with full alpha
      selectedColors.add(colorInt | 0xFF000000);
    }
  }

  // Fallback if we found nothing (e.g. B&W image)
  if (selectedColors.isEmpty) {
    final populationSorted = colorToCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in populationSorted.take(4)) {
      selectedColors.add(entry.key | 0xFF000000);
    }
  }

  return selectedColors;
}

/// Colours extracted from the current track's artwork, shared by the full
/// player, mini player, queue and (optionally) the app accent.
///
/// Extraction runs once per artwork (cached in [PaletteCacheService]) in an
/// isolate, whatever screen is showing.
class NowPlayingColorsProvider extends ChangeNotifier {
  NowPlayingColorsProvider({
    required AudioPlayerService audioService,
    required JellyfinService jellyfinService,
    required DownloadService downloadService,
  })  : _jellyfinService = jellyfinService,
        _downloadService = downloadService {
    _trackSub = audioService.currentTrackStream.listen(_onTrack);
    final current = audioService.currentTrack;
    if (current != null) _onTrack(current);
  }

  final JellyfinService _jellyfinService;
  final DownloadService _downloadService;
  final PaletteCacheService _cache = PaletteCacheService.instance;
  StreamSubscription<JellyfinTrack?>? _trackSub;
  String? _artworkKey;
  bool _disposed = false;

  List<Color>? _colors;
  double? _avgLuminance;

  /// Up to 4 artwork colours, most vibrant first; null while unknown.
  List<Color>? get colors => _colors;

  /// Most vibrant artwork colour, for accents.
  Color? get accent => _colors?.first;

  /// Mean luminance of the first two colours (for picking text colours
  /// over artwork gradients).
  double? get avgLuminance => _avgLuminance;

  void _set(List<Color>? colors) {
    if (_disposed) return;
    _colors = (colors == null || colors.isEmpty) ? null : colors;
    _avgLuminance = _computeAvgLuminance(_colors);
    notifyListeners();
  }

  static double? _computeAvgLuminance(List<Color>? colors) {
    if (colors == null || colors.isEmpty) return null;
    final colorsToCheck = colors.take(2).toList();
    double total = 0;
    for (final c in colorsToCheck) {
      total += c.computeLuminance();
    }
    return total / colorsToCheck.length;
  }

  void _onTrack(JellyfinTrack? track) {
    if (track == null) {
      _artworkKey = null;
      _set(null);
      return;
    }
    unawaited(_extract(track));
  }

  Future<void> _extract(JellyfinTrack track) async {
    // Same fallback chain as the artwork widgets: track → album → parent.
    String? imageTag = track.primaryImageTag;
    String itemId = track.id;
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.albumPrimaryImageTag;
      itemId = track.albumId ?? track.id;
    }
    if (imageTag == null || imageTag.isEmpty) {
      imageTag = track.parentThumbImageTag;
      itemId = track.albumId ?? track.id;
    }

    final key = imageTag == null || imageTag.isEmpty
        ? 'track-${track.id}'
        : '$itemId-$imageTag';
    if (key == _artworkKey) return; // same artwork (e.g. next album track)
    _artworkKey = key;

    final cached = _cache.get(key);
    if (cached != null) {
      _set(cached);
      return;
    }
    // Clear old colors immediately to prevent showing a stale gradient
    _set(null);

    try {
      ImageProvider? imageProvider;
      // Downloaded artwork first (works offline)
      final artworkFile = await _downloadService.getArtworkFile(track.id);
      if (artworkFile != null && await artworkFile.exists()) {
        imageProvider = FileImage(artworkFile);
      } else if (imageTag != null && imageTag.isNotEmpty) {
        imageProvider = CachedNetworkImageProvider(
          _jellyfinService.buildImageUrl(
            itemId: itemId,
            tag: imageTag,
            maxWidth: 100,
          ),
          headers: _jellyfinService.imageHeaders(),
        );
      }
      if (imageProvider == null) return;

      final image = await _resolve(imageProvider);
      final byteData = await image.toByteData();
      if (byteData == null) return;
      final colorInts = await compute(
        extractArtworkColorsInIsolate,
        byteData.buffer.asUint32List(),
      );
      final colors = colorInts.map(Color.new).toList();
      if (colors.isNotEmpty) _cache.put(key, colors);
      // A newer track may have started while we were extracting.
      if (_artworkKey == key) _set(colors);
    } catch (e) {
      debugPrint('Failed to extract artwork colors: $e');
    }
  }

  static Future<ui.Image> _resolve(ImageProvider provider) async {
    final stream = provider.resolve(const ImageConfiguration());
    final completer = Completer<ui.Image>();
    final listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image);
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } finally {
      stream.removeListener(listener);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _trackSub?.cancel();
    super.dispose();
  }
}
