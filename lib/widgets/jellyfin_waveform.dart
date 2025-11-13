import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../jellyfin/jellyfin_track.dart';

class JellyfinWaveform extends StatefulWidget {
  const JellyfinWaveform({
    super.key,
    required this.track,
    required this.progress,
    required this.width,
    required this.height,
  });

  final JellyfinTrack track;
  final double progress;
  final double width;
  final double height;

  @override
  State<JellyfinWaveform> createState() => _JellyfinWaveformState();
}

class _JellyfinWaveformState extends State<JellyfinWaveform> {
  ui.Image? _waveformImage;
  bool _isLoading = false;
  static final Map<String, ui.Image> _cache = {};

  @override
  void initState() {
    super.initState();
    _loadWaveform();
  }

  @override
  void didUpdateWidget(JellyfinWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      _loadWaveform();
    }
  }

  Future<void> _loadWaveform() async {
    // Check cache first
    if (_cache.containsKey(widget.track.id)) {
      if (mounted) {
        setState(() {
          _waveformImage = _cache[widget.track.id];
        });
      }
      return;
    }

    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final url = widget.track.waveformImageUrl(
        width: widget.width.toInt(),
        height: widget.height.toInt(),
      );

      if (url == null) {
        setState(() => _isLoading = false);
        return;
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        final codec = await ui.instantiateImageCodec(
          Uint8List.fromList(bytes),
        );
        final frame = await codec.getNextFrame();
        
        // Cache it
        _cache[widget.track.id] = frame.image;
        
        if (mounted) {
          setState(() {
            _waveformImage = frame.image;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    } catch (e) {
      debugPrint('Failed to load waveform: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_waveformImage == null) {
      // Fallback: simple synthetic waveform
      return CustomPaint(
        painter: _SimpleWaveformPainter(
          color: theme.colorScheme.secondary.withValues(alpha: 0.3),
          progress: widget.progress,
        ),
      );
    }

    return CustomPaint(
      painter: _WaveformImagePainter(
        image: _waveformImage!,
        progress: widget.progress,
        playedColor: theme.colorScheme.primary,
        unplayedColor: theme.colorScheme.secondary.withValues(alpha: 0.3),
      ),
    );
  }
}

class _WaveformImagePainter extends CustomPainter {
  _WaveformImagePainter({
    required this.image,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

  final ui.Image image;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final splitX = size.width * progress;

    // Draw unplayed part
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..colorFilter = ColorFilter.mode(unplayedColor, BlendMode.srcATop),
    );

    // Draw played part (clipped)
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, splitX, size.height));
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..colorFilter = ColorFilter.mode(playedColor, BlendMode.srcATop),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WaveformImagePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.image != image ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}

class _SimpleWaveformPainter extends CustomPainter {
  _SimpleWaveformPainter({
    required this.color,
    required this.progress,
  });

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final barCount = 60;
    final barWidth = size.width / barCount;

    for (int i = 0; i < barCount; i++) {
      final height = size.height * (0.3 + (i % 3) * 0.2);
      final x = i * barWidth;
      final rect = Rect.fromLTWH(
        x,
        (size.height - height) / 2,
        barWidth * 0.7,
        height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SimpleWaveformPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.progress != progress;
  }
}
