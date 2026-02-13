import 'dart:async';

import 'package:flutter/material.dart';

import '../models/waveform_data.dart';
import '../services/waveform_service.dart';

/// Widget that displays a waveform visualization for a track.
/// Uses WaveformService to load pre-extracted waveform data.
class TrackWaveform extends StatefulWidget {
  const TrackWaveform({
    super.key,
    required this.trackId,
    required this.progress,
    required this.width,
    required this.height,
  });

  final String trackId;
  final double progress;
  final double width;
  final double height;

  /// Clear the widget-level waveform cache.
  /// Call when waveform files are deleted (e.g. settings → clear cache).
  static void clearCache() => _TrackWaveformState._cache.clear();

  @override
  State<TrackWaveform> createState() => _TrackWaveformState();
}

class _TrackWaveformState extends State<TrackWaveform> {
  WaveformData? _waveformData;
  bool _isLoading = false;
  static final Map<String, WaveformData> _cache = {};
  StreamSubscription<String>? _waveformSubscription;

  @override
  void initState() {
    super.initState();
    _loadWaveform();
    _listenForWaveformExtraction();
  }

  @override
  void dispose() {
    _waveformSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(TrackWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId != widget.trackId) {
      _loadWaveform();
    }
  }

  void _listenForWaveformExtraction() {
    _waveformSubscription = WaveformService.instance.onWaveformExtracted.listen((trackId) {
      // Reload if this is our track and we don't have data yet
      if (trackId == widget.trackId && _waveformData == null) {
        _isLoading = false; // Reset to allow retry (avoids race with in-progress load)
        _loadWaveform();
      }
    });
  }

  Future<void> _loadWaveform() async {
    // Check local cache first
    if (_cache.containsKey(widget.trackId)) {
      if (mounted) {
        setState(() {
          _waveformData = _cache[widget.trackId];
        });
      }
      return;
    }

    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      // Initialize service if needed
      await WaveformService.instance.initialize();

      // Load waveform from service
      final data = await WaveformService.instance.getWaveform(widget.trackId);

      if (data != null && data.amplitudes.isNotEmpty) {
        _cache[widget.trackId] = data;

        if (mounted) {
          setState(() {
            _waveformData = data;
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

    if (_waveformData == null || _waveformData!.amplitudes.isEmpty) {
      // No waveform available - show nothing
      // (bioluminescent visualizer overlays on top anyway)
      return const SizedBox.shrink();
    }

    return CustomPaint(
      painter: _WaveformDataPainter(
        data: _waveformData!,
        progress: widget.progress,
        playedColor: theme.colorScheme.primary,
        unplayedColor: theme.colorScheme.secondary.withValues(alpha: 0.3),
      ),
    );
  }
}

class _WaveformDataPainter extends CustomPainter {
  _WaveformDataPainter({
    required this.data,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });

  final WaveformData data;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || data.amplitudes.isEmpty) return;

    final barWidth = 2.0;
    final gap = 1.0;
    final barCount = (size.width / (barWidth + gap)).floor();

    if (barCount <= 0) return;

    final playedPaint = Paint()
      ..color = playedColor
      ..style = PaintingStyle.fill;

    final unplayedPaint = Paint()
      ..color = unplayedColor
      ..style = PaintingStyle.fill;

    for (int i = 0; i < barCount; i++) {
      final position = i / barCount;
      final amplitude = data.getAmplitudeAt(position);

      // Minimum bar height of 2px, scale up based on amplitude
      final minHeight = 2.0;
      final maxHeight = size.height * 0.9;
      final barHeight = minHeight + (amplitude * (maxHeight - minHeight));

      final x = i * (barWidth + gap);
      final y = (size.height - barHeight) / 2;

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, barHeight),
        const Radius.circular(1),
      );

      final isPlayed = position <= progress;
      canvas.drawRRect(rect, isPlayed ? playedPaint : unplayedPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformDataPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.data != data ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor;
  }
}

// Keep the old class name as an alias for backward compatibility
@Deprecated('Use TrackWaveform instead')
typedef JellyfinWaveform = TrackWaveform;
