import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:ui' as ui;

import '../../jellyfin/jellyfin_service.dart';
import '../../models/rewind_data.dart';

/// Top-level function for compute() - extracts colors from image bytes in isolate
List<int> _extractColorsFromBytes(Uint8List pixels) {
  final colors = <int>[];

  // Sample colors from the image (RGBA format)
  for (int i = 0; i < pixels.length; i += 400) {
    if (i + 2 < pixels.length) {
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      colors.add(0xFF000000 | (r << 16) | (g << 8) | b);
    }
  }

  // Sort by luminance to get darker colors first
  colors.sort((a, b) {
    final rA = (a >> 16) & 0xFF;
    final gA = (a >> 8) & 0xFF;
    final bA = a & 0xFF;
    final rB = (b >> 16) & 0xFF;
    final gB = (b >> 8) & 0xFF;
    final bB = b & 0xFF;
    final lumA = 0.299 * rA + 0.587 * gA + 0.114 * bA;
    final lumB = 0.299 * rB + 0.587 * gB + 0.114 * bB;
    return lumA.compareTo(lumB);
  });

  return colors;
}

/// Shared cache for album palette colors in Rewind cards
final Map<String, List<Color>> _rewindPaletteCache = {};

/// Base card widget with enhanced gradient background and nautical styling
class _RewindBaseCard extends StatelessWidget {
  final Widget child;
  final List<Color>? gradientColors;
  final GlobalKey? repaintKey;

  const _RewindBaseCard({
    required this.child,
    this.gradientColors,
    this.repaintKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Enhanced gradient using theme colors with ocean-like depth
    final colors = gradientColors ?? [
      theme.colorScheme.primary.withValues(alpha: 0.5),
      theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      theme.colorScheme.surface.withValues(alpha: 0.95),
      theme.colorScheme.surface,
    ];

    final content = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: colors.length == 4
              ? const [0.0, 0.3, 0.7, 1.0]
              : null,
        ),
      ),
      child: Stack(
        children: [
          // Subtle wave decoration at the bottom
          Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: CustomPaint(
                size: const Size(double.infinity, 80),
                painter: _WavePainter(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                ),
              ),
            ),
          // Main content
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ],
      ),
    );

    if (repaintKey != null) {
      return RepaintBoundary(
        key: repaintKey,
        child: content,
      );
    }
    return content;
  }
}

/// Custom painter for subtle wave decoration
class _WavePainter extends CustomPainter {
  final Color color;

  _WavePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height);

    // Create gentle wave curves
    path.lineTo(0, size.height * 0.6);
    path.quadraticBezierTo(
      size.width * 0.25, size.height * 0.4,
      size.width * 0.5, size.height * 0.6,
    );
    path.quadraticBezierTo(
      size.width * 0.75, size.height * 0.8,
      size.width, size.height * 0.5,
    );
    path.lineTo(size.width, size.height);
    path.close();

    canvas.drawPath(path, paint);

    // Second wave layer
    final paint2 = Paint()
      ..color = color.withValues(alpha: (color.a * 0.5))
      ..style = PaintingStyle.fill;

    final path2 = Path();
    path2.moveTo(0, size.height);
    path2.lineTo(0, size.height * 0.75);
    path2.quadraticBezierTo(
      size.width * 0.3, size.height * 0.5,
      size.width * 0.6, size.height * 0.7,
    );
    path2.quadraticBezierTo(
      size.width * 0.85, size.height * 0.85,
      size.width, size.height * 0.65,
    );
    path2.lineTo(size.width, size.height);
    path2.close();

    canvas.drawPath(path2, paint2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Card 0: Welcome card with nautical flair
class RewindWelcomeCard extends StatelessWidget {
  final RewindData data;
  final GlobalKey? repaintBoundaryKey;

  const RewindWelcomeCard({super.key, required this.data, this.repaintBoundaryKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.primary.withValues(alpha: 0.6),
        theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        theme.colorScheme.tertiary.withValues(alpha: 0.3),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          // Trident icon with glow effect
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.3),
                  theme.colorScheme.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
            child: Text(
              '🔱',
              style: TextStyle(
                fontSize: 80,
                shadows: [
                  Shadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    blurRadius: 30,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'Your ${data.yearDisplay}',
            style: GoogleFonts.raleway(
              fontSize: 24,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 8),
          ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.tertiary,
              ],
            ).createShader(bounds),
            child: Text(
              'REWIND',
              style: GoogleFonts.pacifico(
                fontSize: 52,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
              color: theme.colorScheme.surface.withValues(alpha: 0.5),
            ),
            child: Text(
              'Dive into your listening journey',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const Spacer(),
          // Swipe indicator with animation hint
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.swipe,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Swipe to explore',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  color: theme.colorScheme.primary,
                  size: 14,
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

/// Card 1: Total listening time with animated counter
class RewindTotalTimeCard extends StatefulWidget {
  final RewindData data;
  final GlobalKey? repaintBoundaryKey;

  const RewindTotalTimeCard({super.key, required this.data, this.repaintBoundaryKey});

  @override
  State<RewindTotalTimeCard> createState() => _RewindTotalTimeCardState();
}

class _RewindTotalTimeCardState extends State<RewindTotalTimeCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hours = widget.data.totalTime.inHours;
    final minutes = widget.data.totalTime.inMinutes % 60;

    return _RewindBaseCard(
      repaintKey: widget.repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.tertiary.withValues(alpha: 0.5),
        theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
        theme.colorScheme.surface.withValues(alpha: 0.95),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          // Icon badge
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
            ),
            child: Icon(
              Icons.headphones,
              size: 32,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'You listened for',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
          AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              final animatedHours = (hours * _animation.value).round();
              final animatedMinutes = (minutes * _animation.value).round();

              return Column(
                children: [
                  if (hours > 0) ...[
                    // Hours with gradient text
                    ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.tertiary,
                        ],
                      ).createShader(bounds),
                      child: Text(
                        '$animatedHours',
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontSize: 100,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Text(
                      hours == 1 ? 'HOUR' : 'HOURS',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        letterSpacing: 6,
                        fontWeight: FontWeight.w300,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Minutes
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '$animatedMinutes',
                          style: theme.textTheme.displayMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: hours > 0
                                ? theme.colorScheme.secondary
                                : theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          minutes == 1 ? 'min' : 'mins',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const Spacer(),
          Text(
            '${widget.data.totalPlays} tracks played',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

/// Card 2: Top Artist showcase
class RewindTopArtistCard extends StatelessWidget {
  final RewindData data;
  final JellyfinService jellyfinService;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopArtistCard({
    super.key,
    required this.data,
    required this.jellyfinService,
    this.repaintBoundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topArtist = data.topArtists.isNotEmpty ? data.topArtists.first : null;

    if (topArtist == null) {
      return _RewindBaseCard(
        repaintKey: repaintBoundaryKey,
        child: const Center(child: Text('No top artist data')),
      );
    }

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.tertiary.withValues(alpha: 0.4),
        theme.colorScheme.primary.withValues(alpha: 0.2),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            'Your #1 Artist',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primaryContainer,
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: topArtist.id != null && topArtist.imageTag != null
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: jellyfinService.buildImageUrl(
                        itemId: topArtist.id!,
                        tag: topArtist.imageTag!,
                        maxWidth: 400,
                      ),
                      httpHeaders: jellyfinService.imageHeaders(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Icon(
                        Icons.person,
                        size: 80,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      errorWidget: (context, url, error) => Icon(
                        Icons.person,
                        size: 80,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  )
                : Icon(
                    Icons.person,
                    size: 80,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
          ),
          const SizedBox(height: 32),
          Text(
            topArtist.name,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            '${topArtist.playCount} plays',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Card 3: Top 5 Artists list with images
class RewindTopArtistsListCard extends StatelessWidget {
  final RewindData data;
  final JellyfinService jellyfinService;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopArtistsListCard({
    super.key,
    required this.data,
    required this.jellyfinService,
    this.repaintBoundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artists = data.topArtists.take(5).toList();

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      child: Column(
        children: [
          const SizedBox(height: 40),
          Text(
            'Top Artists',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: artists.length,
              itemBuilder: (context, index) {
                final artist = artists[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      // Rank number
                      SizedBox(
                        width: 28,
                        child: Text(
                          '${index + 1}',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Artist image
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primaryContainer,
                        ),
                        child: artist.id != null && artist.imageTag != null
                            ? ClipOval(
                                child: CachedNetworkImage(
                                  imageUrl: jellyfinService.buildImageUrl(
                                    itemId: artist.id!,
                                    tag: artist.imageTag!,
                                    maxWidth: 100,
                                  ),
                                  httpHeaders: jellyfinService.imageHeaders(),
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Icon(
                                    Icons.person,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                  errorWidget: (context, url, error) => Icon(
                                    Icons.person,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                              )
                            : Icon(
                                Icons.person,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              artist.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${artist.playCount} plays',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Card 4: Top Album showcase
class RewindTopAlbumCard extends StatefulWidget {
  final RewindData data;
  final JellyfinService jellyfinService;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopAlbumCard({
    super.key,
    required this.data,
    required this.jellyfinService,
    this.repaintBoundaryKey,
  });

  @override
  State<RewindTopAlbumCard> createState() => _RewindTopAlbumCardState();
}

class _RewindTopAlbumCardState extends State<RewindTopAlbumCard> {
  List<Color>? _albumColors;

  @override
  void initState() {
    super.initState();
    _extractAlbumColors();
  }

  Future<void> _extractAlbumColors() async {
    final topAlbum = widget.data.topAlbums.isNotEmpty
        ? widget.data.topAlbums.first
        : null;

    if (topAlbum == null ||
        topAlbum.albumId == null ||
        topAlbum.imageTag == null) {
      return;
    }

    final cacheKey = '${topAlbum.albumId}_${topAlbum.imageTag}';

    // Check cache first
    if (_rewindPaletteCache.containsKey(cacheKey)) {
      if (mounted) {
        setState(() {
          _albumColors = _rewindPaletteCache[cacheKey];
        });
      }
      return;
    }

    try {
      final url = widget.jellyfinService.buildImageUrl(
        itemId: topAlbum.albumId!,
        tag: topAlbum.imageTag!,
        maxWidth: 100,
      );

      final response = await http.get(
        Uri.parse(url),
        headers: widget.jellyfinService.imageHeaders(),
      );

      if (response.statusCode == 200) {
        final codec = await ui.instantiateImageCodec(response.bodyBytes);
        final frame = await codec.getNextFrame();
        final image = frame.image;

        final byteData = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        if (byteData != null) {
          final pixels = byteData.buffer.asUint8List();
          final colorInts = await compute(_extractColorsFromBytes, pixels);

          if (colorInts.isNotEmpty) {
            final colors = colorInts.take(5).map((c) => Color(c)).toList();
            _rewindPaletteCache[cacheKey] = colors;

            if (mounted) {
              setState(() {
                _albumColors = colors;
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error extracting album colors: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topAlbum = widget.data.topAlbums.isNotEmpty
        ? widget.data.topAlbums.first
        : null;

    if (topAlbum == null) {
      return _RewindBaseCard(
        repaintKey: widget.repaintBoundaryKey,
        child: const Center(child: Text('No top album data')),
      );
    }

    // Use extracted album colors or fall back to theme
    final gradientColors = _albumColors != null && _albumColors!.length >= 3
        ? [
            _albumColors![0].withValues(alpha: 0.7),
            _albumColors![_albumColors!.length ~/ 2].withValues(alpha: 0.4),
            theme.colorScheme.surface.withValues(alpha: 0.95),
            theme.colorScheme.surface,
          ]
        : [
            theme.colorScheme.secondary.withValues(alpha: 0.5),
            theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
            theme.colorScheme.surface.withValues(alpha: 0.95),
            theme.colorScheme.surface,
          ];

    // Dynamic accent color from album
    final accentColor = _albumColors?.isNotEmpty == true
        ? _albumColors![(_albumColors!.length * 0.7).toInt().clamp(0, _albumColors!.length - 1)]
        : theme.colorScheme.secondary;

    return _RewindBaseCard(
      repaintKey: widget.repaintBoundaryKey,
      gradientColors: gradientColors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          // Title with badge styling
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: accentColor.withValues(alpha: 0.2),
              border: Border.all(
                color: accentColor.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.album,
                  size: 18,
                  color: accentColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Your #1 Album',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: accentColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          // Album artwork with enhanced shadow
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: theme.colorScheme.secondaryContainer,
              boxShadow: [
                BoxShadow(
                  color: (_albumColors?.isNotEmpty == true
                          ? _albumColors!.first
                          : theme.colorScheme.secondary)
                      .withValues(alpha: 0.5),
                  blurRadius: 40,
                  spreadRadius: 8,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: topAlbum.albumId != null && topAlbum.imageTag != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: CachedNetworkImage(
                      imageUrl: widget.jellyfinService.buildImageUrl(
                        itemId: topAlbum.albumId!,
                        tag: topAlbum.imageTag!,
                        maxWidth: 400,
                      ),
                      httpHeaders: widget.jellyfinService.imageHeaders(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Icon(
                        Icons.album,
                        size: 80,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      errorWidget: (context, url, error) => Icon(
                        Icons.album,
                        size: 80,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  )
                : Icon(
                    Icons.album,
                    size: 80,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
          ),
          const SizedBox(height: 32),
          // Album name with better styling
          Text(
            topAlbum.name,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            topAlbum.artistName,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          // Play count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: accentColor.withValues(alpha: 0.15),
            ),
            child: Text(
              '${topAlbum.playCount} plays',
              style: theme.textTheme.titleLarge?.copyWith(
                color: accentColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Card 5: Top Albums grid
class RewindTopAlbumsGridCard extends StatelessWidget {
  final RewindData data;
  final JellyfinService jellyfinService;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopAlbumsGridCard({
    super.key,
    required this.data,
    required this.jellyfinService,
    this.repaintBoundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final albums = data.topAlbums.take(6).toList();

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      child: Column(
        children: [
          const SizedBox(height: 40),
          Text(
            'Top Albums',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.75,
              ),
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final album = albums[index];
                return Column(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        child: album.albumId != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl: jellyfinService.buildImageUrl(
                                    itemId: album.albumId!,
                                    tag: album.imageTag,
                                    maxWidth: 200,
                                  ),
                                  httpHeaders: jellyfinService.imageHeaders(),
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => const Icon(Icons.album),
                                  errorWidget: (context, url, error) => const Icon(Icons.album),
                                ),
                              )
                            : const Icon(Icons.album),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      album.name,
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Card 6: Top Track
class RewindTopTrackCard extends StatelessWidget {
  final RewindData data;
  final JellyfinService jellyfinService;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopTrackCard({
    super.key,
    required this.data,
    required this.jellyfinService,
    this.repaintBoundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topTrack = data.topTracks.isNotEmpty ? data.topTracks.first : null;

    if (topTrack == null) {
      return _RewindBaseCard(
        repaintKey: repaintBoundaryKey,
        child: const Center(child: Text('No top track data')),
      );
    }

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.primary.withValues(alpha: 0.4),
        theme.colorScheme.secondary.withValues(alpha: 0.2),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            'Your #1 Song',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.primaryContainer,
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.4),
                  blurRadius: 30,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: topTrack.albumId != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: CachedNetworkImage(
                      imageUrl: jellyfinService.buildImageUrl(
                        itemId: topTrack.albumId!,
                        maxWidth: 400,
                      ),
                      httpHeaders: jellyfinService.imageHeaders(),
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Icon(
                        Icons.music_note,
                        size: 80,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      errorWidget: (context, url, error) => Icon(
                        Icons.music_note,
                        size: 80,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  )
                : Icon(
                    Icons.music_note,
                    size: 80,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
          ),
          const SizedBox(height: 32),
          Text(
            topTrack.name,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            topTrack.artistName,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${topTrack.playCount} plays',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Card 7: Top Genre with colorful breakdown
class RewindTopGenreCard extends StatelessWidget {
  final RewindData data;
  final GlobalKey? repaintBoundaryKey;

  const RewindTopGenreCard({super.key, required this.data, this.repaintBoundaryKey});

  IconData _getGenreIcon(String genre) {
    final lower = genre.toLowerCase();
    if (lower.contains('rock')) return Icons.electric_bolt;
    if (lower.contains('metal')) return Icons.whatshot;
    if (lower.contains('pop')) return Icons.star;
    if (lower.contains('jazz')) return Icons.piano;
    if (lower.contains('classical')) return Icons.music_note;
    if (lower.contains('hip') || lower.contains('rap')) return Icons.mic;
    if (lower.contains('electronic') || lower.contains('edm') || lower.contains('dance')) return Icons.waves;
    if (lower.contains('country')) return Icons.grass;
    if (lower.contains('folk') || lower.contains('acoustic')) return Icons.forest;
    if (lower.contains('r&b') || lower.contains('soul')) return Icons.favorite;
    if (lower.contains('indie')) return Icons.local_fire_department;
    if (lower.contains('blues')) return Icons.nightlight;
    if (lower.contains('reggae')) return Icons.beach_access;
    if (lower.contains('punk')) return Icons.bolt;
    if (lower.contains('ambient') || lower.contains('chill')) return Icons.spa;
    return Icons.library_music;
  }

  Color _getGenreColor(String genre, ThemeData theme, int index) {
    final colors = [
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
      theme.colorScheme.tertiary,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];
    return colors[index % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topGenre = data.topGenre;

    if (topGenre == null) {
      return _RewindBaseCard(
        repaintKey: repaintBoundaryKey,
        child: const Center(child: Text('No genre data')),
      );
    }

    // Get top 5 genres
    final sortedGenres = data.genres.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topGenres = sortedGenres.take(5).toList();
    final totalGenrePlays = sortedGenres.fold<int>(0, (sum, e) => sum + e.value);

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.tertiary.withValues(alpha: 0.4),
        theme.colorScheme.primary.withValues(alpha: 0.2),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            'Your Top Genre',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          // Top genre with icon
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _getGenreColor(topGenre, theme, 0).withValues(alpha: 0.2),
              border: Border.all(
                color: _getGenreColor(topGenre, theme, 0),
                width: 3,
              ),
            ),
            child: Icon(
              _getGenreIcon(topGenre),
              size: 48,
              color: _getGenreColor(topGenre, theme, 0),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            topGenre,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: _getGenreColor(topGenre, theme, 0),
            ),
          ),
          const SizedBox(height: 24),
          // Genre breakdown with colorful bars
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: topGenres.asMap().entries.map((entry) {
                final index = entry.key;
                final genre = entry.value.key;
                final count = entry.value.value;
                final percentage = totalGenrePlays > 0 ? count / totalGenrePlays : 0.0;
                final percentStr = (percentage * 100).toStringAsFixed(1);
                final color = _getGenreColor(genre, theme, index);

                return Padding(
                  padding: EdgeInsets.only(bottom: index < topGenres.length - 1 ? 12 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _getGenreIcon(genre),
                            size: 16,
                            color: color,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              genre,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Text(
                            '$percentStr%',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: percentage,
                          backgroundColor: color.withValues(alpha: 0.1),
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                          minHeight: 6,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Card 8: Personality archetype
class RewindPersonalityCard extends StatelessWidget {
  final RewindData data;
  final GlobalKey? repaintBoundaryKey;

  const RewindPersonalityCard({super.key, required this.data, this.repaintBoundaryKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final personality = data.personality;

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.primary.withValues(alpha: 0.5),
        theme.colorScheme.tertiary.withValues(alpha: 0.3),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            'You are a',
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            personality.emoji,
            style: const TextStyle(fontSize: 80),
          ),
          const SizedBox(height: 24),
          Text(
            personality.name,
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              personality.description,
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const Spacer(),
          // Fun fact based on personality
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _getPersonalityFact(personality),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _getPersonalityFact(ListeningPersonality personality) {
    switch (personality) {
      case ListeningPersonality.explorer:
        return 'Explorers discover 3x more new music than average listeners!';
      case ListeningPersonality.loyalist:
        return 'Loyalists know every lyric to their favorite songs!';
      case ListeningPersonality.nightOwl:
        return 'Night owls find music hits different after midnight!';
      case ListeningPersonality.earlyBird:
        return 'Early birds set the perfect tone for their day!';
      case ListeningPersonality.weekendWarrior:
        return 'Weekend warriors make every weekend a musical adventure!';
      case ListeningPersonality.marathoner:
        return 'Marathoners lose track of time when great music is playing!';
      case ListeningPersonality.eclectic:
        return 'Eclectic listeners appreciate music in all its forms!';
      case ListeningPersonality.specialist:
        return 'Specialists become true experts in their favorite genre!';
      case ListeningPersonality.balanced:
        return 'Balanced listeners enjoy the best of all musical worlds!';
    }
  }
}

/// Card 9: Summary stats
class RewindSummaryCard extends StatelessWidget {
  final RewindData data;
  final GlobalKey? repaintBoundaryKey;

  const RewindSummaryCard({super.key, required this.data, this.repaintBoundaryKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      child: Column(
        children: [
          const SizedBox(height: 40),
          Text(
            'By The Numbers',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: GridView.count(
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              childAspectRatio: 1.5,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              children: [
                _StatTile(
                  icon: Icons.music_note,
                  label: 'Tracks Played',
                  value: data.totalPlays.toString(),
                  color: theme.colorScheme.primary,
                ),
                _StatTile(
                  icon: Icons.people,
                  label: 'Artists',
                  value: data.uniqueArtists.toString(),
                  color: theme.colorScheme.secondary,
                ),
                _StatTile(
                  icon: Icons.album,
                  label: 'Albums',
                  value: data.uniqueAlbums.toString(),
                  color: theme.colorScheme.tertiary,
                ),
                _StatTile(
                  icon: Icons.library_music,
                  label: 'Unique Songs',
                  value: data.uniqueTracks.toString(),
                  color: theme.colorScheme.primary,
                ),
                if (data.peakMonth != null)
                  _StatTile(
                    icon: Icons.calendar_month,
                    label: 'Peak Month',
                    value: RewindData.monthName(data.peakMonth!).substring(0, 3),
                    color: theme.colorScheme.secondary,
                  ),
                if (data.longestStreak > 0)
                  _StatTile(
                    icon: Icons.local_fire_department,
                    label: 'Longest Streak',
                    value: '${data.longestStreak} days',
                    color: theme.colorScheme.tertiary,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Card 10: Share card
class RewindShareCard extends StatelessWidget {
  final RewindData data;
  final VoidCallback onShare;
  final GlobalKey? repaintBoundaryKey;

  const RewindShareCard({
    super.key,
    required this.data,
    required this.onShare,
    this.repaintBoundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return _RewindBaseCard(
      repaintKey: repaintBoundaryKey,
      gradientColors: [
        theme.colorScheme.primary.withValues(alpha: 0.4),
        theme.colorScheme.secondary.withValues(alpha: 0.3),
        theme.colorScheme.tertiary.withValues(alpha: 0.2),
        theme.colorScheme.surface,
      ],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Text(
            '🔱',
            style: TextStyle(fontSize: 56, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 24),
          Text(
            'That\'s your ${data.yearDisplay} Rewind!',
            style: GoogleFonts.pacifico(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'Share your music journey with friends',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 48),
          FilledButton.icon(
            onPressed: onShare,
            icon: const Icon(Icons.share),
            label: const Text('Share Rewind'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            label: const Text('Done'),
          ),
          const Spacer(),
          Text(
            'Made with Nautune',
            style: GoogleFonts.pacifico(
              fontSize: 14,
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
