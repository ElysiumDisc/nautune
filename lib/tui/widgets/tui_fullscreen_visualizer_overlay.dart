import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../jellyfin/jellyfin_track.dart';
import '../../services/audio_player_service.dart';
import '../../services/pulseaudio_fft_service.dart';
import '../tui_metrics.dart';
import '../tui_theme.dart';

/// Fullscreen Braille-dot spectroscope overlay, inspired by
/// `tsirysndr/tunein-cli`'s always-on spectroscope. Triggered by `F` in the
/// TUI shell; dismissed by Esc or `F` again.
///
/// The overlay's lifecycle is strictly scoped to visibility: the shell keeps
/// this widget mounted only while its `_showFullscreenVisualizer` flag is
/// true, so the FFT stream subscription, playing-state subscription, and
/// animation ticker are torn down the instant the user closes the overlay.
/// **Zero background cost when not visible.**
///
/// Rasterisation is intentionally duplicated (not shared) with the inline
/// [TuiBrailleVisualizer]; the inline visualizer is already shipping in
/// v8.2.0 and we don't want a cross-cutting refactor mid-release. A shared
/// Braille canvas helper is planned for a later release.
class TuiFullscreenVisualizerOverlay extends StatefulWidget {
  const TuiFullscreenVisualizerOverlay({
    super.key,
    required this.onDismiss,
  });

  final VoidCallback onDismiss;

  @override
  State<TuiFullscreenVisualizerOverlay> createState() =>
      _TuiFullscreenVisualizerOverlayState();
}

class _TuiFullscreenVisualizerOverlayState
    extends State<TuiFullscreenVisualizerOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  StreamSubscription? _fftSubscription;
  StreamSubscription? _playingSubscription;
  final FocusNode _focusNode = FocusNode();

  /// Smoothed spectrum, one sample per horizontal dot-column. Recreated when
  /// the terminal is resized — see [_ensureBuffers].
  List<double> _spectrum = const <double>[];
  List<double> _targetSpectrum = const <double>[];

  /// Reusable cell buffer (one byte per Braille glyph). Allocated once per
  /// size change; `fillRange(0, length, 0)` at the start of each rasterise
  /// keeps allocation pressure off the 30 Hz paint loop.
  List<int> _cells = const <int>[];

  /// Grid size in *character cells*. Updated on every `LayoutBuilder` call.
  int _cellCols = 0;
  int _cellRows = 0;

  bool _isPlaying = false;
  bool _haveRealFFT = false; // true on Linux with PulseAudio monitor
  DateTime _lastFrame = DateTime.now();

  // FFT-driven 3-band summary used for per-range gain shaping.
  double _bandBass = 0, _bandMid = 0, _bandTreble = 0;

  /// Braille dot-bit table. `_brailleBits[col][row]` → byte bit.
  /// col 0 = left dot column, col 1 = right. rows 0..3 top-to-bottom.
  /// Matches Unicode Braille pattern layout (U+2800 + byte).
  static const List<List<int>> _brailleBits = [
    [0x01, 0x02, 0x04, 0x40],
    [0x08, 0x10, 0x20, 0x80],
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _initFFTSource();

    // Cache initial playing state; the audio service's current value isn't
    // delivered as a stream event, only changes are.
    _isPlaying = true; // pessimistic — the stream will correct quickly.

    // Explicitly steal focus from the shell's KeyboardListener. `autofocus`
    // on Focus/KeyboardListener is not enough because the shell's focus node
    // is already the FocusScope's focused descendant — autofocus no-ops in
    // that case. An explicit requestFocus() on the next frame reliably takes
    // primary focus (matches TuiPianoOverlay's pattern, which is proven).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
    });
  }

  void _initFFTSource() {
    final audioService = _audioService;
    if (audioService == null) return;

    _isPlaying = audioService.isPlaying;

    _playingSubscription = audioService.playingStream.listen((playing) {
      if (!mounted) return;
      _isPlaying = playing;
      if (playing && !_ticker.isActive) {
        _ticker.start();
      }
    });

    if (Platform.isLinux && PulseAudioFFTService.instance.isAvailable) {
      _haveRealFFT = true;
      _fftSubscription = PulseAudioFFTService.instance.fftStream.listen((fft) {
        if (!mounted) return;
        _bandBass = fft.bass;
        _bandMid = fft.mid;
        _bandTreble = fft.treble;
        _updateTargetsFromFFT(fft);
      });
    } else {
      _haveRealFFT = false;
      _fftSubscription = audioService.frequencyBandsStream.listen((bands) {
        if (!mounted) return;
        _bandBass = bands.bass;
        _bandMid = bands.mid;
        _bandTreble = bands.treble;
        _updateTargetsFromBands(bands.bass, bands.mid, bands.treble);
      });
    }

    if (_isPlaying) {
      _ticker.start();
    }
  }

  /// Reallocate target/smoothed spectrum arrays and the cell buffer to match
  /// a new grid size. Called on every LayoutBuilder callback — the `if` guard
  /// makes resizes free when the terminal hasn't changed size.
  void _ensureBuffers(int cols, int rows) {
    if (cols == _cellCols && rows == _cellRows && _cells.isNotEmpty) return;
    _cellCols = cols;
    _cellRows = rows;
    final dotCols = cols * 2;
    _spectrum = List<double>.filled(dotCols, 0.0);
    _targetSpectrum = List<double>.filled(dotCols, 0.0);
    _cells = List<int>.filled(cols * rows, 0);
  }

  void _updateTargetsFromFFT(FFTData fft) {
    if (_targetSpectrum.isEmpty) return;
    final spectrum = fft.spectrum;
    if (spectrum.isEmpty) {
      _updateTargetsFromBands(fft.bass, fft.mid, fft.treble);
      return;
    }

    final dotCols = _targetSpectrum.length;
    // Use the lower 40% of bins — above Nyquist's edge is mostly noise at
    // typical monitor-capture sample rates.
    final usable = math.max(4, (spectrum.length * 0.4).round());
    final minLog = math.log(1);
    final maxLog = math.log(usable.toDouble());
    final logRange = maxLog - minLog;

    for (int x = 0; x < dotCols; x++) {
      final t = x / (dotCols - 1);
      final binF = math.exp(minLog + t * logRange);
      final i0 = binF.floor().clamp(0, spectrum.length - 1);
      final i1 = (i0 + 1).clamp(0, spectrum.length - 1);
      final frac = (binF - i0).clamp(0.0, 1.0);
      final v0 = spectrum[i0];
      final v1 = spectrum[i1];
      var value = v0 + (v1 - v0) * frac;

      final ratio = t;
      final boost = ratio < 0.25
          ? 2.0 + fft.bass * 1.2
          : ratio < 0.6
              ? 2.4 + fft.mid * 1.5
              : 2.8 + fft.treble * 1.8;

      _targetSpectrum[x] = (value * boost).clamp(0.0, 1.0);
    }
  }

  void _updateTargetsFromBands(double bass, double mid, double treble) {
    if (_targetSpectrum.isEmpty) return;
    final dotCols = _targetSpectrum.length;
    for (int x = 0; x < dotCols; x++) {
      final ratio = x / (dotCols - 1);
      double value;
      if (ratio < 0.25) {
        final hump = 1.0 - ((ratio - 0.12) / 0.15).abs();
        value = bass * hump.clamp(0.0, 1.0);
      } else if (ratio < 0.6) {
        final midRatio = (ratio - 0.25) / 0.35;
        final hump = 1.0 - ((midRatio - 0.5)).abs() * 2;
        value = mid * hump.clamp(0.0, 1.0);
      } else {
        final trebleRatio = (ratio - 0.6) / 0.4;
        value = treble * (1.0 - trebleRatio * 0.5);
      }
      _targetSpectrum[x] = value.clamp(0.0, 1.0);
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    if (now.difference(_lastFrame).inMilliseconds < 33) return; // ~30 fps
    _lastFrame = now;

    if (_spectrum.isEmpty) {
      if (mounted) setState(() {});
      return;
    }

    bool anyActive = false;
    for (int i = 0; i < _spectrum.length; i++) {
      final target = _isPlaying ? _targetSpectrum[i] : 0.0;
      if (target > _spectrum[i]) {
        _spectrum[i] += (target - _spectrum[i]) * 0.55;
      } else {
        _spectrum[i] += (target - _spectrum[i]) * 0.12;
      }
      if (_spectrum[i] > 0.01) anyActive = true;
    }

    if (mounted) setState(() {});

    // Stop ticking when music is paused AND everything has decayed. The
    // overlay itself is still mounted, but the ticker isn't burning CPU.
    if (!_isPlaying && !anyActive && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    // Dispose order matters: stop the ticker before cancelling subscriptions
    // so no in-flight tick callback tries to access stream data. `Ticker`'s
    // own dispose also handles `stop()`, but explicit is clearer.
    if (_ticker.isActive) {
      _ticker.stop();
    }
    _ticker.dispose();
    _fftSubscription?.cancel();
    _playingSubscription?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  /// Key handler for the overlay's KeyboardListener. Fires only when the
  /// overlay's `_focusNode` has primary focus (granted in `initState` via
  /// post-frame requestFocus).
  ///
  /// Esc is the only close keybind. F was intentionally removed — using the
  /// same key to open and close created a crash-prone path where pressing F
  /// while the overlay was dismissing raced with Flutter's subtree teardown.
  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
    }
  }

  AudioPlayerService? get _audioService {
    try {
      return context.read<NautuneAppState>().audioPlayerService;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TuiColors.background.withValues(alpha: 0.98),
      // KeyboardListener + an explicit requestFocus() from initState (see
      // above) — the proven TuiPianoOverlay pattern. Plain `Focus(autofocus:
      // true)` is not enough because the shell's `_focusNode` is already the
      // enclosing FocusScope's focused descendant on overlay mount, and
      // autofocus silently no-ops in that case.
      child: KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Reserve lines for: title row, frequency-axis label row, one
            // blank, footer hint. Everything else is the visualizer.
            const reservedRows = 5;
            final availCols = TuiMetrics.widthToChars(constraints.maxWidth);
            final availRows =
                TuiMetrics.heightToLines(constraints.maxHeight) - reservedRows;
            final cols = math.max(20, availCols);
            final rows = math.max(4, availRows);
            _ensureBuffers(cols, rows);

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context),
                  const SizedBox(height: 4),
                  _buildFrequencyAxis(cols),
                  const SizedBox(height: 4),
                  Expanded(child: _buildChart(cols, rows)),
                  _buildFooter(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final audioService = _audioService;
    final trackStream = audioService?.currentTrackStream;
    return Row(
      children: [
        Text('NAUTUNE  ',
            style: TuiTextStyles.accent.copyWith(fontWeight: FontWeight.bold)),
        Text('·  SPECTROSCOPE  ·  ', style: TuiTextStyles.dim),
        Expanded(
          child: trackStream == null
              ? Text('no audio service', style: TuiTextStyles.dim)
              : StreamBuilder<JellyfinTrack?>(
                  stream: trackStream,
                  builder: (context, snapshot) {
                    final track = snapshot.data;
                    final artist = (track == null || track.artists.isEmpty)
                        ? 'Unknown artist'
                        : track.artists.first;
                    final title = track == null
                        ? 'no track playing'
                        : '${track.name} — $artist';
                    return Text(
                      title,
                      style: TuiTextStyles.normal,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  },
                ),
        ),
        const SizedBox(width: 12),
        Text(
          _haveRealFFT ? 'FFT' : 'BANDS',
          style: TuiTextStyles.accent,
        ),
      ],
    );
  }

  /// Decade reference labels aligned to the log-frequency axis used in
  /// [_rasterize]. Matches tunein-cli's "20 / 100 / 1k / 10k" guideline
  /// labels for viewer orientation.
  Widget _buildFrequencyAxis(int cols) {
    final buf = List<String>.filled(cols, ' ');
    const labels = ['20', '100', '1k', '10k'];
    for (int i = 0; i < labels.length; i++) {
      final t = (i + 1) / (labels.length + 1);
      final x = (t * cols).round().clamp(0, cols - 1);
      final label = labels[i];
      for (int k = 0; k < label.length && (x + k) < cols; k++) {
        buf[x + k] = label[k];
      }
    }
    return Text(
      buf.join(),
      style: TuiTextStyles.dim,
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }

  Widget _buildChart(int cols, int rows) {
    _rasterize(cols, rows);
    final lines = <Widget>[];
    for (int r = 0; r < rows; r++) {
      final buf = StringBuffer();
      for (int c = 0; c < cols; c++) {
        buf.writeCharCode(0x2800 + _cells[r * cols + c]);
      }
      final rowRatio = rows == 1 ? 1.0 : (r / (rows - 1));
      final color =
          Color.lerp(TuiColors.accent, TuiColors.primary, rowRatio) ??
              TuiColors.primary;
      lines.add(Text(
        buf.toString(),
        style: TuiTextStyles.normal.copyWith(color: color, height: 1.0),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }

  Widget _buildFooter() {
    final bandsLine = _haveRealFFT
        ? 'bass ${(_bandBass * 100).round()}%   mid ${(_bandMid * 100).round()}%'
          '   treble ${(_bandTreble * 100).round()}%'
        : 'bands-only source — real-time FFT disabled on this platform';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(bandsLine, style: TuiTextStyles.dim),
          ),
          Text('Esc to close', style: TuiTextStyles.accent),
        ],
      ),
    );
  }

  /// Fill [_cells] with the current Braille bit patterns for a `cols × rows`
  /// grid. Reuses the buffer (zeroing via [List.fillRange]) — no per-frame
  /// allocation.
  void _rasterize(int cols, int rows) {
    if (_cells.length != cols * rows) {
      _cells = List<int>.filled(cols * rows, 0);
    } else {
      _cells.fillRange(0, _cells.length, 0);
    }

    final dotW = cols * 2;
    final dotH = rows * 4;

    // Decade gridlines at 20/100/1k/10k positions (log axis, 4 decades).
    const decades = 4;
    for (int d = 1; d < decades; d++) {
      final x = ((d / decades) * (dotW - 1)).round();
      for (int y = 0; y < dotH; y += 2) {
        _setDot(cols, rows, x, y);
      }
    }

    // Dot baseline so the viewer has a visual floor when quiet.
    final botY = dotH - 1;
    for (int x = 0; x < dotW; x += 4) {
      _setDot(cols, rows, x, botY);
    }

    // Foreground spectrum curve — connect consecutive data points so the
    // line never breaks into dashed segments even with fast attack.
    int? prevY;
    final spectrum = _spectrum;
    for (int x = 0; x < dotW && x < spectrum.length; x++) {
      final v = spectrum[x].clamp(0.0, 1.0);
      final y = ((1.0 - v) * botY).round();
      _setDot(cols, rows, x, y);
      if (prevY != null) {
        final lo = math.min(prevY, y);
        final hi = math.max(prevY, y);
        for (int yy = lo; yy <= hi; yy++) {
          _setDot(cols, rows, x, yy);
        }
      }
      prevY = y;
    }
  }

  void _setDot(int cols, int rows, int x, int y) {
    if (x < 0 || y < 0) return;
    if (x >= cols * 2 || y >= rows * 4) return;
    final cellCol = x >> 1;
    final cellRow = y >> 2;
    final dotCol = x & 1;
    final dotRow = y & 3;
    _cells[cellRow * cols + cellCol] |= _brailleBits[dotCol][dotRow];
  }
}
